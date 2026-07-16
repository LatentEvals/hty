//! The hty server: a single-threaded event loop over `poll(2)`.
//!
//! One thread, one poll set: the listen socket, every client connection
//! (RPC, attach, watch, pre-creation pending watch), and every live
//! session's PTY master fd. No worker threads, no reader threads, no
//! mutexes, no atomics in server state — with a single thread there is
//! no lock order and no publication protocol.
//!
//! Connections are loop-owned `Conn` state machines driven by
//! `src/loop.zig`. Immediate ops dispatch synchronously and queue their
//! response into a bounded per-connection outbound buffer flushed on
//! `POLLOUT`. Wait ops park the connection in a waiter table; PTY output
//! re-evaluates waiters on the same iteration it arrives, so a
//! `wait_for_text` resolves the moment its needle is fed — no tick
//! quantization. Attach input frames land in the owning session's
//! bounded pending-input buffer, flushed to the master fd on its
//! `POLLOUT` — a child that stops reading its tty drops input instead of
//! stalling the loop.
//!
//! PTY readability drives everything session-side: `POLLIN` on a master
//! fd pumps 8 KiB chunks synchronously through VT feed, session log,
//! attach broadcast, and waiter wake-up; EOF/EIO reaps the child with
//! `waitpid(WNOHANG)` and runs the exit transition. Session deletion is
//! deferred-free: `delete` (and the `--remove` sweep, which runs on the
//! iteration that observes the exit) unpublishes the session
//! immediately, and the loop frees doomed sessions in its
//! end-of-iteration phase — a pointer obtained during dispatch is valid
//! structurally, not by grace timing or refcounts.

const std = @import("std");

const Allocator = std.mem.Allocator;

const paths = @import("paths.zig");
const resolveLogDir = paths.resolveLogDir;
const ensureOwnedDir = paths.ensureOwnedDir;

const json = @import("json.zig");
const readOptionalId = json.readOptionalId;
const readOptionalString = json.readOptionalString;
const readRequiredString = json.readRequiredString;

const protocol = @import("protocol.zig");
const Response = protocol.Response;
const encodeResponse = protocol.encodeResponse;
const requestErrorMessage = protocol.requestErrorMessage;

const SessionRegistry = @import("registry.zig").SessionRegistry;
const session_mod = @import("session.zig");
const Session = session_mod.Session;
const AttachClient = session_mod.AttachClient;
const setStreamNonBlocking = session_mod.setStreamNonBlocking;

const log_mod = @import("log.zig");

const ops = @import("ops.zig");

const loop_mod = @import("loop.zig");
const Loop = loop_mod.Loop;
const DeadlineTable = loop_mod.DeadlineTable;

const server_attach = @import("server_attach.zig");
const detectAttachOp = server_attach.detectAttachOp;
const handleAttachConnection = server_attach.handleAttachConnection;

const empty_grace_ms: i64 = 10_000;

/// Maximum size of one request line. Real requests are well under 4 KiB;
/// 1 MiB leaves generous headroom for large `send_text` payloads while
/// preventing a client that never sends a newline from growing the read
/// buffer until the server OOMs. Oversized requests get a structured
/// `request too large` error and the connection is closed.
pub const max_request_line_bytes: usize = 1024 * 1024;

/// Upper bound on unflushed bytes queued for one connection. Applies to
/// *accumulation*: a single response larger than the bound is still
/// delivered when the buffer is empty (RPC connections carry exactly one
/// response before draining, and large snapshot payloads must keep
/// working), but unread bytes can never pile up behind a stalled reader
/// past this limit — the connection is dropped instead.
pub const max_outbound_bytes: usize = 1024 * 1024;

/// How soon to retry `waitpid(WNOHANG)` for a child whose fd reported
/// EOF (or was closed by kill) before the child became reapable. SIGKILL
/// and pty-EOF children die promptly; this is a short backstop, not a
/// tick.
const reap_retry_ms: i64 = 5;

/// How long to keep accepts paused after EMFILE/ENFILE before retrying.
const listen_resume_ms: i64 = 100;

/// Poll cadence for the test-only external stop signal. Only armed when
/// `RunOpts.stop_signal` is provided — production runs have no recurring
/// deadline at all.
const stop_poll_ms: i64 = 25;

// Deadline-table ids. Waiter ids are allocated upward from
// `first_waiter_deadline_id`; the fixed ids below never collide.
const empty_shutdown_deadline_id: u64 = 1;
const listen_resume_deadline_id: u64 = 2;
const reap_retry_deadline_id: u64 = 3;
const stop_poll_deadline_id: u64 = 4;
const first_waiter_deadline_id: u64 = 5;

/// Optional configuration for the server loop. Production uses the
/// defaults; tests pass a short `empty_grace_ms` and/or a `stop_signal`
/// they can flip externally so the loop exits promptly.
pub const RunOpts = struct {
    empty_grace_ms: i64 = empty_grace_ms,
    /// If non-null, the loop returns as soon as it observes this flag set
    /// to true (checked at least once per `stop_poll_ms`). Test-only
    /// escape hatch: the flag is flipped from the test harness thread,
    /// which is the one cross-thread edge the loop still has — hence the
    /// atomic. Production passes null and pays nothing.
    stop_signal: ?*std.atomic.Value(bool) = null,
    /// Test hook: use this session-log directory (borrowed; must outlive
    /// the server) instead of resolving the XDG state path, so socket-level
    /// tests can assert on log contents hermetically.
    log_dir: ?[]const u8 = null,
};

pub fn runServer(alloc: Allocator, socket_path: []const u8) !void {
    return runServerWithOpts(alloc, socket_path, .{});
}

pub fn runServerWithOpts(alloc: Allocator, socket_path: []const u8, opts: RunOpts) !void {
    // Unlink stale socket file if present.
    std.posix.unlink(socket_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };

    const address = try std.net.Address.initUnix(socket_path);
    var server = try address.listen(.{ .reuse_address = true });
    defer server.deinit();
    defer std.posix.unlink(socket_path) catch {};

    // The loop accepts until WouldBlock on every listen-readiness, so the
    // listen socket must be non-blocking (it also dodges the classic
    // "client resets between poll and accept" stall).
    try setStreamNonBlocking(server.stream.handle);

    var registry = SessionRegistry.init(alloc);
    defer registry.deinit();

    // Resolve the session log directory best-effort (or take the test
    // override). If it can't be set up, the server still runs — log hooks
    // skip when registry.log_dir is null.
    const log_dir_resolved: ?[]u8 = if (opts.log_dir != null) null else resolveLogDir(alloc) catch |err| blk: {
        std.debug.print("warning: session log dir unavailable ({s}) — logging disabled\n", .{@errorName(err)});
        break :blk null;
    };
    defer if (log_dir_resolved) |d| alloc.free(d);
    if (opts.log_dir orelse log_dir_resolved) |d| {
        const by_name = std.fmt.allocPrint(alloc, "{s}/by-name", .{d}) catch null;
        if (by_name) |bn| {
            defer alloc.free(bn);
            ensureOwnedDir(alloc, bn) catch |err| {
                std.debug.print("warning: by-name dir setup failed: {s}\n", .{@errorName(err)});
            };
        }
        registry.log_dir = d;
        // One-time reconciliation: logs written by older hty versions may
        // predate the by-name symlink that `nameInUse` now treats as
        // authoritative; create any missing links before serving requests.
        log_mod.reconcileByNameLinks(alloc, d);
    }

    var srv = LoopServer{
        .alloc = alloc,
        .registry = &registry,
        .listen_fd = server.stream.handle,
        .empty_grace_ms = opts.empty_grace_ms,
        .loop = Loop.init(alloc),
        .deadlines = DeadlineTable.init(alloc),
    };
    // Runs before `registry.deinit()`: waiters and attach conns hold
    // session pointers that must be dropped while the registry is alive.
    defer srv.deinit();

    try srv.loop.registerFd(srv.listen_fd, .{});

    // Auto-shutdown: the server starts empty, so arm the shutdown deadline
    // right away (the old code's `empty_since_ms = now` initialization). A
    // new session or connection cancels it at the next iteration's sync.
    if (srv.deadlines.insert(empty_shutdown_deadline_id, std.time.milliTimestamp() + opts.empty_grace_ms)) {
        srv.empty_armed = true;
    } else |_| {}

    // Test harnesses stop the loop by flipping a flag from another
    // thread; poll it on a recurring deadline so a fully-quiet server
    // still notices. Production (null) keeps a deadline-free steady
    // state: poll blocks until real work arrives.
    if (opts.stop_signal != null) {
        srv.deadlines.insert(stop_poll_deadline_id, std.time.milliTimestamp() + stop_poll_ms) catch {};
    }

    while (true) {
        const timeout = srv.deadlines.nextTimeoutMs(std.time.milliTimestamp());
        var ready = srv.loop.waitReady(timeout) catch |err| {
            std.debug.print("poll failed: {s}\n", .{@errorName(err)});
            continue;
        };
        // Fixed service order per iteration: listen accepts land first
        // (the listen fd is registered first), then connection I/O and
        // PTY reads in poll-set order.
        while (ready.next()) |r| {
            if (r.fd == srv.listen_fd) {
                srv.acceptReady();
            } else if (srv.conns.contains(r.fd)) {
                srv.connReady(r.fd, r.revents);
            } else {
                srv.ptyReady(r.fd);
            }
        }

        // PTY output fed and ops dispatched above may have changed what
        // parked waiters are watching (output, exit, kill, delete):
        // re-evaluate now so a wait resolves in the same iteration the
        // event that satisfies it arrived.
        srv.evaluateWaiters();

        var now = std.time.milliTimestamp();
        while (srv.deadlines.popExpired(now)) |expired| {
            switch (expired.id) {
                empty_shutdown_deadline_id => {
                    srv.empty_armed = false;
                    if (srv.serverIsEmpty()) return;
                },
                listen_resume_deadline_id => srv.retryListen(now),
                reap_retry_deadline_id => {
                    srv.reap_armed = false;
                    if (srv.registry.retryReaps()) srv.armReapRetry(now);
                },
                stop_poll_deadline_id => {
                    srv.deadlines.insert(stop_poll_deadline_id, now + stop_poll_ms) catch {};
                },
                else => srv.waiterDeadlineExpired(expired.id, now),
            }
            now = std.time.milliTimestamp();
        }

        // Deadline expiries can also resolve waiter-visible state (a reap
        // retry observing the exit); evaluate once more so those complete
        // this iteration too.
        srv.evaluateWaiters();

        // End-of-iteration sync: promote pending watchers whose session
        // appeared, reap attach conns marked closed (buffer overflow,
        // exit broadcast, detach), keep POLLOUT armed for subscribers
        // with buffered frames; run the `--remove` sweep on the iteration
        // that observed the exit; reconcile PTY fd registrations and
        // queued-input write interest; keep the empty-shutdown deadline
        // in sync — all before the deferred-free phase and the next poll.
        srv.syncSubscribers();
        srv.registry.autoRemoveSweep();
        srv.evaluateWaiters();
        srv.syncSessionPtys(now);
        srv.checkEmptyTimer(now);

        // Deferred frees, last: every waiter parked on a doomed session
        // was resolved above, so nothing observable can touch the storage
        // after this point.
        srv.freeDoomedSessions();

        // External stop signal (test harness) wins over the empty timer.
        if (opts.stop_signal) |flag| {
            if (flag.load(.acquire)) return;
        }
    }
}

/// One client connection owned by the event loop: RPC, attach/watch, or
/// pre-creation pending watch.
const Conn = struct {
    stream: std.net.Stream,
    state: State = .reading_request,
    /// Inbound bytes. While `reading_request`: the request line being
    /// accumulated (cleared once dispatched; RPC conns discard anything
    /// after their request line — one request, one response, close).
    /// While `attached`: the JSONL frame stream from the client.
    inbuf: std.ArrayListUnmanaged(u8) = .{},
    /// Outbound bytes not yet accepted by the socket, flushed on POLLOUT.
    /// Bounded by `max_outbound_bytes` (see its doc for the exact rule).
    /// Attached conns use their subscriber's buffer instead
    /// (`AttachClient.pending`, same bound and overflow policy).
    outbuf: std.ArrayListUnmanaged(u8) = .{},
    /// Bytes of `outbuf` already written to the socket.
    out_pos: usize = 0,
    /// Set when this connection is parked in the waiter table.
    waiter: ?*Waiter = null,
    /// True once EOF was seen and read interest dropped (half-close while
    /// waiting or draining) so the loop stops polling a finished stream.
    read_disabled: bool = false,
    /// The broadcast subscriber for an `attached` conn (`owned_by_conn` is
    /// set: this conn frees it when reaping).
    attach_client: ?*AttachClient = null,
    /// The exact session name a `pending_watch` conn is waiting for.
    /// Owned by the conn.
    pending_watch_name: ?[]u8 = null,

    const State = enum {
        /// Accumulating bytes until the request line's newline.
        reading_request,
        /// Parked in the waiter table; the response comes later.
        waiting,
        /// Response queued; flush the outbound buffer, then close.
        draining,
        /// Subscribed to a session (attach or watch): inbound bytes are
        /// JSONL frames, outbound carries broadcast frames.
        attached,
        /// Watch-by-name before the session exists; promoted to
        /// `attached` when a session with that name is created.
        pending_watch,
    };
};

/// One parked wait: everything needed to re-evaluate the condition and,
/// on completion, format the response the blocking handler would have
/// produced. Holds the session pointer (kept valid by the deferred-free
/// rule: a doomed session is not freed while a waiter references it) and
/// owns the arena the parsed request lives in (the condition's needle
/// points into it).
const Waiter = struct {
    deadline_id: u64,
    conn: *Conn,
    sess: *Session,
    arena_state: *std.heap.ArenaAllocator,
    condition: ops.WaitCondition,
    state: ops.WaitState,
    /// Absolute timeout deadline in ms; `maxInt(i64)` when the wait has
    /// no timeout. The deadline-table entry under `deadline_id` is this
    /// value for text/exit waits, the completion time for `duration`
    /// waits, and the next re-check time (clamped to the timeout) for
    /// idle waits — idle needs scheduled re-evaluation since nothing
    /// event-driven fires when a session simply stays quiet.
    timeout_deadline_ms: i64,
    id: ?i64,
    format: ops.WaitFormat,
};

/// What became of a dispatched request line.
const DispatchOutcome = union(enum) {
    /// An encoded response line (caller-owned) to queue and drain.
    response: []u8,
    /// The connection was parked in the waiter table.
    parked,
    /// Attach/watch: the conn changed role (`attached` / `pending_watch`)
    /// or was torn down on failure; all bookkeeping (including inbuf
    /// compaction) already happened inside `beginAttach`.
    transitioned,
};

/// Loop-owned server state: the poll set, the deadline table, the live
/// connections, and the parked waiters.
const LoopServer = struct {
    alloc: Allocator,
    registry: *SessionRegistry,
    listen_fd: std.posix.socket_t,
    empty_grace_ms: i64,
    loop: Loop,
    deadlines: DeadlineTable,
    conns: std.AutoHashMapUnmanaged(std.posix.socket_t, *Conn) = .{},
    waiters: std.ArrayListUnmanaged(*Waiter) = .{},
    /// PTY master fds currently in the poll set, mapped to their session.
    /// Read interest is constant while registered; write interest tracks
    /// whether the session has queued input. Reconciled against the
    /// registry every iteration by `syncSessionPtys`.
    session_fds: std.AutoHashMapUnmanaged(std.posix.fd_t, *Session) = .{},
    next_waiter_deadline_id: u64 = first_waiter_deadline_id,
    /// True while accepts are suspended after EMFILE/ENFILE; the
    /// listen-resume deadline re-registers the listen fd.
    listen_paused: bool = false,
    /// True while the empty-shutdown deadline entry is in the table.
    empty_armed: bool = false,
    /// True while the reap-retry deadline entry is in the table.
    reap_armed: bool = false,

    fn deinit(self: *LoopServer) void {
        // Waiters first — they reference sessions that must still be
        // alive (the registry outlives this deinit). Their conns are torn
        // down by the sweep below.
        for (self.waiters.items) |waiter| {
            waiter.conn.waiter = null;
            self.destroyWaiter(waiter);
        }
        self.waiters.deinit(self.alloc);

        var it = self.conns.valueIterator();
        while (it.next()) |conn_ptr| {
            const conn = conn_ptr.*;
            // Attach conns: detach the subscriber from its session (the
            // registry outlives this deinit) and emit the disconnect the
            // reap path would have logged.
            if (conn.attach_client) |client| self.detachSubscriber(client);
            if (conn.pending_watch_name) |n| self.alloc.free(n);
            conn.stream.close();
            conn.inbuf.deinit(self.alloc);
            conn.outbuf.deinit(self.alloc);
            self.alloc.destroy(conn);
        }
        self.conns.deinit(self.alloc);
        self.session_fds.deinit(self.alloc);

        self.loop.deinit();
        self.deadlines.deinit();
    }

    /// Keep the empty-shutdown deadline in sync with whether the server
    /// has anything left to do. Runs once per iteration (the explicit
    /// successor of the old housekeeping tick's arm/cancel logic).
    fn checkEmptyTimer(self: *LoopServer, now: i64) void {
        const empty = self.serverIsEmpty();
        if (empty and !self.empty_armed) {
            if (self.deadlines.insert(empty_shutdown_deadline_id, now + self.empty_grace_ms)) {
                self.empty_armed = true;
            } else |_| {}
        } else if (!empty and self.empty_armed) {
            _ = self.deadlines.cancel(empty_shutdown_deadline_id);
            self.empty_armed = false;
        }
    }

    /// Retry a paused listen fd after EMFILE/ENFILE; re-arm the resume
    /// deadline while the registration keeps failing.
    fn retryListen(self: *LoopServer, now: i64) void {
        if (!self.listen_paused) return;
        if (self.loop.registerFd(self.listen_fd, .{})) {
            self.listen_paused = false;
        } else |_| {
            self.deadlines.insert(listen_resume_deadline_id, now + listen_resume_ms) catch {};
        }
    }

    /// Arm the short waitpid-retry deadline (idempotent).
    fn armReapRetry(self: *LoopServer, now: i64) void {
        if (self.reap_armed) return;
        if (self.deadlines.insert(reap_retry_deadline_id, now + reap_retry_ms)) {
            self.reap_armed = true;
        } else |_| {}
    }

    /// Empty means: no running sessions (zombies don't count — see
    /// `activeCount`) and no live RPC connections (a parked wait or an
    /// in-flight request must block shutdown, exactly like an in-flight
    /// worker used to).
    fn serverIsEmpty(self: *LoopServer) bool {
        return self.registry.activeCount() == 0 and self.conns.count() == 0;
    }

    fn acceptReady(self: *LoopServer) void {
        while (true) {
            const fd = std.posix.accept(
                self.listen_fd,
                null,
                null,
                std.posix.SOCK.CLOEXEC | std.posix.SOCK.NONBLOCK,
            ) catch |err| switch (err) {
                error.WouldBlock => return,
                error.ProcessFdQuotaExceeded, error.SystemFdQuotaExceeded => {
                    // EMFILE/ENFILE: accept produced no fd, so there is no
                    // socket to answer on. Pause accepts and retry on the
                    // resume deadline instead of spinning on a listen fd
                    // that will stay readable; existing connections keep
                    // being served.
                    std.debug.print("accept failed: {s} — pausing accepts\n", .{@errorName(err)});
                    _ = self.loop.deregisterFd(self.listen_fd);
                    self.listen_paused = true;
                    self.deadlines.insert(
                        listen_resume_deadline_id,
                        std.time.milliTimestamp() + listen_resume_ms,
                    ) catch {};
                    return;
                },
                error.ConnectionAborted => continue,
                else => {
                    std.debug.print("accept failed: {s}\n", .{@errorName(err)});
                    return;
                },
            };
            self.adoptConn(fd) catch {
                // A connection slot couldn't be made: reject with the
                // structured error and keep serving (PRD §6).
                _ = std.posix.write(fd, "{\"ok\":false,\"error\":\"too many open connections\"}\n") catch {};
                std.posix.close(fd);
            };
        }
    }

    fn adoptConn(self: *LoopServer, fd: std.posix.socket_t) !void {
        // A session killed/deleted earlier in this iteration closed its
        // master fd, and this accept may have recycled the same fd number
        // while the stale registration is still pending its
        // `syncSessionPtys` reconciliation. Clear it so registerFd below
        // doesn't see a duplicate.
        if (self.session_fds.remove(fd)) _ = self.loop.deregisterFd(fd);

        const conn = try self.alloc.create(Conn);
        errdefer self.alloc.destroy(conn);
        conn.* = .{ .stream = .{ .handle = fd } };
        try self.conns.put(self.alloc, fd, conn);
        errdefer _ = self.conns.remove(fd);
        try self.loop.registerFd(fd, .{});
    }

    /// Readiness on a session's PTY master fd. Which bits fired doesn't
    /// matter: POLLOUT means queued input can flush, POLLIN/POLLHUP mean
    /// output (or EOF) is readable — service both unconditionally, they
    /// are cheap no-ops when not applicable.
    fn ptyReady(self: *LoopServer, fd: std.posix.fd_t) void {
        const sess = self.session_fds.get(fd) orelse return;
        sess.flushPendingInput();
        switch (self.registry.servicePty(sess)) {
            .open, .reaped, .broken => {},
            // EOF observed but the child isn't reapable yet — retry on a
            // short deadline instead of polling a drained fd.
            .reap_pending => self.armReapRetry(std.time.milliTimestamp()),
        }
    }

    fn connReady(self: *LoopServer, fd: std.posix.socket_t, revents: i16) void {
        if ((revents & (std.posix.POLL.ERR | std.posix.POLL.NVAL)) != 0) {
            if (self.conns.get(fd)) |conn| self.dropConn(conn);
            return;
        }
        if ((revents & std.posix.POLL.OUT) != 0) {
            if (self.conns.get(fd)) |conn| {
                switch (conn.state) {
                    .attached => self.flushAttachConn(conn),
                    else => self.flushConn(conn),
                }
            }
        }
        // Re-lookup after the flush: it may have completed the drain (or
        // hit a write error) and destroyed the conn.
        if ((revents & (std.posix.POLL.IN | std.posix.POLL.HUP)) != 0) {
            if (self.conns.get(fd)) |conn| {
                self.readConn(conn, (revents & std.posix.POLL.HUP) != 0);
            }
        }
    }

    /// Generic "this connection is dead" teardown that routes attached
    /// conns through the reap path (so the disconnect gets logged and the
    /// subscriber leaves the session's broadcast list).
    fn dropConn(self: *LoopServer, conn: *Conn) void {
        if (conn.state == .attached) {
            conn.attach_client.?.closed = true;
            return self.reapAttachConn(conn);
        }
        self.teardownConn(conn);
    }

    /// Drain readable bytes. `hup` reports whether poll flagged POLLHUP —
    /// on EOF it distinguishes a fully-gone peer (tear down; nobody can
    /// read a response) from a half-close (stop reading, keep flushing).
    fn readConn(self: *LoopServer, conn: *Conn, hup: bool) void {
        var chunk: [4096]u8 = undefined;
        while (true) {
            const n = std.posix.read(conn.stream.handle, &chunk) catch |err| switch (err) {
                error.WouldBlock => return,
                else => return self.dropConn(conn),
            };
            if (n == 0) return self.connEof(conn, hup);
            switch (conn.state) {
                .reading_request => {
                    conn.inbuf.appendSlice(self.alloc, chunk[0..n]) catch return self.teardownConn(conn);
                    if (std.mem.indexOfScalar(u8, conn.inbuf.items, '\n')) |newline| {
                        const line = conn.inbuf.items[0..newline];
                        // The in-loop check below bounds growth chunk by
                        // chunk; this catches a line that crossed the cap
                        // in the same chunk that carried its newline.
                        if (line.len > max_request_line_bytes) return self.respondTooLarge(conn);
                        return self.dispatchConnLine(conn, line);
                    }
                    if (conn.inbuf.items.len > max_request_line_bytes) return self.respondTooLarge(conn);
                },
                .attached => {
                    conn.inbuf.appendSlice(self.alloc, chunk[0..n]) catch return self.dropConn(conn);
                    if (!self.consumeAttachFrames(conn)) return;
                },
                // A parked watcher isn't supposed to send anything;
                // discard bytes, exactly like the old pending-watcher
                // reader thread.
                .pending_watch => conn.inbuf.clearRetainingCapacity(),
                // One request per connection: bytes past the request line
                // are discarded, exactly like the old reader that never
                // looked past the first newline.
                .waiting, .draining => {},
            }
        }
    }

    /// Dispatch every complete JSONL frame buffered on an attached conn.
    /// Returns false when the conn was torn down (detach frame, malformed
    /// frame, or a runaway line without a newline — any error ended the
    /// old reader loop; same policy here).
    fn consumeAttachFrames(self: *LoopServer, conn: *Conn) bool {
        const client = conn.attach_client.?;
        while (std.mem.indexOfScalar(u8, conn.inbuf.items, '\n')) |nl| {
            const line = conn.inbuf.items[0..nl];
            server_attach.dispatchAttachFrame(client, line) catch {
                client.closed = true;
                self.reapAttachConn(conn);
                return false;
            };
            const rest_len = conn.inbuf.items.len - nl - 1;
            std.mem.copyForwards(u8, conn.inbuf.items[0..rest_len], conn.inbuf.items[nl + 1 ..]);
            conn.inbuf.shrinkRetainingCapacity(rest_len);
        }
        if (conn.inbuf.items.len > max_request_line_bytes) {
            client.closed = true;
            self.reapAttachConn(conn);
            return false;
        }
        return true;
    }

    fn connEof(self: *LoopServer, conn: *Conn, hup: bool) void {
        switch (conn.state) {
            .reading_request => {
                // A request may legitimately arrive without a trailing
                // newline when the client half-closes after writing; the
                // old reader treated EOF as end-of-line. Preserve that.
                if (conn.inbuf.items.len == 0) return self.teardownConn(conn);
                if (conn.inbuf.items.len > max_request_line_bytes) return self.respondTooLarge(conn);
                self.dispatchConnLine(conn, conn.inbuf.items);
            },
            // EOF ends an attachment (the old reader loop broke on
            // read() == 0) and drops a parked watcher.
            .attached, .pending_watch => self.dropConn(conn),
            .waiting, .draining => {
                if (hup) return self.teardownConn(conn);
                // Half-close: the client is still reading. Drop read
                // interest so a level-triggered EOF doesn't spin the loop
                // while the response (or wait outcome) is on its way.
                self.disableRead(conn);
            },
        }
    }

    fn disableRead(self: *LoopServer, conn: *Conn) void {
        if (conn.read_disabled) return;
        const fd = conn.stream.handle;
        const write_armed = conn.out_pos < conn.outbuf.items.len;
        _ = self.loop.deregisterFd(fd);
        self.loop.registerFd(fd, .{ .read = false, .write = write_armed }) catch {
            return self.teardownConn(conn);
        };
        conn.read_disabled = true;
    }

    /// Reply with the structured over-cap error and drain-close, keeping
    /// the wire shape of the old `respondTooLarge`.
    fn respondTooLarge(self: *LoopServer, conn: *Conn) void {
        conn.inbuf.clearAndFree(self.alloc);
        const bytes = encodeResponse(self.alloc, .{ .ok = false, .@"error" = "request too large" }) catch
            return self.teardownConn(conn);
        defer self.alloc.free(bytes);
        self.queueResponse(conn, bytes);
    }

    /// Dispatch a complete request line and route the outcome back onto
    /// the connection. After this returns the conn may be draining,
    /// parked, or already destroyed (attach handoff / write failure).
    fn dispatchConnLine(self: *LoopServer, conn: *Conn, line: []const u8) void {
        const outcome = self.dispatchOnLoop(conn, line) catch |err| {
            std.debug.print("request failed: {s}\n", .{@errorName(err)});
            return self.teardownConn(conn);
        };
        switch (outcome) {
            .response => |bytes| {
                defer self.alloc.free(bytes);
                conn.inbuf.clearAndFree(self.alloc);
                self.queueResponse(conn, bytes);
            },
            .parked => conn.inbuf.clearAndFree(self.alloc),
            .transitioned => {},
        }
    }

    /// The loop-side twin of `processRequestLine`: same parse and
    /// dispatch semantics, plus the two paths that need the connection
    /// itself — attach/watch handoff and wait parking.
    fn dispatchOnLoop(self: *LoopServer, conn: *Conn, line: []const u8) !DispatchOutcome {
        if (std.mem.trim(u8, line, " \t\r").len == 0) {
            return .{ .response = try encodeResponse(self.alloc, .{ .ok = false, .@"error" = "empty request" }) };
        }

        // Peek at the op before normal dispatch; attach and watch flip the
        // connection into a streaming role instead of request/response.
        switch (detectAttachOp(self.alloc, line)) {
            .attach => return self.beginAttach(conn, line, false),
            .watch => return self.beginAttach(conn, line, true),
            .none => {},
        }

        // Heap-allocate the request arena so its ownership can transfer to
        // a parked waiter (the parsed needle etc. must outlive this call).
        const arena_state = try self.alloc.create(std.heap.ArenaAllocator);
        arena_state.* = std.heap.ArenaAllocator.init(self.alloc);
        var arena_transferred = false;
        defer if (!arena_transferred) {
            arena_state.deinit();
            self.alloc.destroy(arena_state);
        };
        const arena = arena_state.allocator();

        switch (try parseRequestLine(self.alloc, arena, line)) {
            .invalid => |response| return .{ .response = response },
            .valid => |req| {
                if (ops.waitOpKind(req.op)) |kind| {
                    if (try self.dispatchWait(conn, arena_state, req.object, kind, req.id)) |outcome| {
                        if (outcome == .parked) arena_transferred = true;
                        return outcome;
                    }
                    // Fused `wait_kind: "none"` — no wait; fall through to
                    // the immediate dispatch below.
                }
                const response: Response = dispatchRequest(arena, self.registry, req.object, req.op, req.id) catch |err| .{
                    .id = req.id,
                    .ok = false,
                    .@"error" = requestErrorMessage(err),
                };
                return .{ .response = try encodeResponse(self.alloc, response) };
            },
        }
    }

    /// Handle a wait op: answer immediately when the condition is already
    /// satisfied (or errors), otherwise park the connection in the waiter
    /// table. Returns null only for the fused op's `wait_kind: "none"`.
    /// On `.parked`, ownership of `arena_state` moves to the waiter.
    fn dispatchWait(
        self: *LoopServer,
        conn: *Conn,
        arena_state: *std.heap.ArenaAllocator,
        object: std.json.ObjectMap,
        kind: ops.WaitOpKind,
        id: ?i64,
    ) !?DispatchOutcome {
        const arena = arena_state.allocator();
        const start_ms = std.time.milliTimestamp();
        const plan = ops.planWait(arena, kind, object, start_ms) catch |err| {
            return .{ .response = try encodeErrorLine(self.alloc, id, err) };
        };
        const condition = plan.condition orelse return null;
        var regex_owned = true;
        defer if (regex_owned) ops.freeWaitConditionRegex(condition);

        const session_ref = readOptionalString(object, "session") catch |err| {
            return .{ .response = try encodeErrorLine(self.alloc, id, err) };
        };
        const sess = self.registry.resolveOrSole(session_ref) catch |err| {
            return .{ .response = try encodeErrorLine(self.alloc, id, err) };
        };

        // First evaluation mirrors `runWait`'s first iteration — service
        // the PTY, evaluate, then the doomed check — so an already-
        // satisfied wait answers without parking, and a satisfied-and-
        // doomed session (wait_for_exit on a `--remove` session) still
        // reports success.
        _ = self.registry.servicePty(sess);
        var state = ops.WaitState.init(sess, start_ms);
        const first = ops.evaluateWaitCondition(arena, condition, sess, &state) catch |err| {
            return .{ .response = try encodeErrorLine(self.alloc, id, err) };
        };
        if (first) |result| {
            const encoded = ops.encodeWaitOutcome(self.alloc, id, sess, plan.format, result) catch |err|
                try encodeErrorLine(self.alloc, id, err);
            return .{ .response = encoded };
        }
        if (condition != .duration and sess.isDoomed()) {
            return .{ .response = try encodeErrorLine(self.alloc, id, error.SessionNotFound) };
        }

        // Park. `duration` waits never time out — their deadline entry is
        // the completion time. Idle waits arm their next re-check time
        // (idleness elapses without any event to wake the loop), clamped
        // to the timeout. Text/exit waits arm the timeout alone (none at
        // all when the timeout is disabled) — PTY output and exits wake
        // them event-side.
        const entry_ms: ?i64 = switch (condition) {
            .duration => |duration_ms| start_ms + @as(i64, @intCast(duration_ms)),
            .idle => |cfg| @min(idleWakeMs(sess, cfg, start_ms), plan.deadline),
            else => if (plan.deadline == std.math.maxInt(i64)) null else plan.deadline,
        };
        const waiter = try self.alloc.create(Waiter);
        errdefer self.alloc.destroy(waiter);
        waiter.* = .{
            .deadline_id = self.next_waiter_deadline_id,
            .conn = conn,
            .sess = sess,
            .arena_state = arena_state,
            .condition = condition,
            .state = state,
            .timeout_deadline_ms = plan.deadline,
            .id = id,
            .format = plan.format,
        };
        try self.waiters.append(self.alloc, waiter);
        errdefer _ = self.waiters.pop();
        if (entry_ms) |deadline_ms| try self.deadlines.insert(waiter.deadline_id, deadline_ms);
        self.next_waiter_deadline_id += 1;

        conn.waiter = waiter;
        conn.state = .waiting;
        regex_owned = false; // the waiter owns the compiled regex now
        return .parked;
    }

    /// Re-evaluate every parked waiter against current session state.
    /// Called after each iteration's PTY reads and dispatches (and again
    /// after deadline expiries), so output, exits, kills, and deletes
    /// resolve waits in the same iteration that produced them.
    fn evaluateWaiters(self: *LoopServer) void {
        var i: usize = 0;
        while (i < self.waiters.items.len) {
            const waiter = self.waiters.items[i];
            // The waiter arena only grows on a match (the duped needle),
            // exactly once per wait — steady-state re-evaluation is
            // allocation-free.
            const maybe_result = ops.evaluateWaitCondition(
                waiter.arena_state.allocator(),
                waiter.condition,
                waiter.sess,
                &waiter.state,
            ) catch |err| {
                _ = self.waiters.swapRemove(i);
                self.finishWaiterError(waiter, err);
                continue;
            };
            if (maybe_result) |result| {
                _ = self.waiters.swapRemove(i);
                self.finishWaiter(waiter, result);
                continue;
            }
            // Session deleted while parked: resolve immediately with the
            // structured error a fresh resolve would produce. Checked
            // after the condition so a wait satisfied by the same drain
            // that doomed the session still reports its success.
            if (waiter.condition != .duration and waiter.sess.isDoomed()) {
                _ = self.waiters.swapRemove(i);
                self.finishWaiterError(waiter, error.SessionNotFound);
                continue;
            }
            i += 1;
        }
    }

    /// A waiter's deadline fired: completion for `duration` waits, the
    /// scheduled re-check (and possibly the timeout) for idle waits, and
    /// the timeout for text/exit waits (whose satisfaction is event-
    /// driven and was re-evaluated on the iteration it happened).
    fn waiterDeadlineExpired(self: *LoopServer, deadline_id: u64, now: i64) void {
        for (self.waiters.items, 0..) |waiter, i| {
            if (waiter.deadline_id != deadline_id) continue;
            switch (waiter.condition) {
                .duration, .idle => {
                    const maybe_result = ops.evaluateWaitCondition(
                        waiter.arena_state.allocator(),
                        waiter.condition,
                        waiter.sess,
                        &waiter.state,
                    ) catch |err| {
                        _ = self.waiters.swapRemove(i);
                        self.finishWaiterError(waiter, err);
                        return;
                    };
                    if (maybe_result) |result| {
                        _ = self.waiters.swapRemove(i);
                        self.finishWaiter(waiter, result);
                        return;
                    }
                    if (waiter.condition == .idle and now >= waiter.timeout_deadline_ms) {
                        _ = self.waiters.swapRemove(i);
                        self.finishWaiter(waiter, .{
                            .timed_out = true,
                            .elapsed_ms = now - waiter.state.start_ms,
                        });
                        return;
                    }
                    // Not satisfied yet: re-arm. For `duration`, clock
                    // jitter left the sleep a hair short (+1ms). For
                    // `idle`, fresh output moved the reference — arm the
                    // next possible satisfaction time, clamped to the
                    // timeout.
                    const next: i64 = switch (waiter.condition) {
                        .duration => now + 1,
                        .idle => |cfg| @min(idleWakeMs(waiter.sess, cfg, now), waiter.timeout_deadline_ms),
                        else => unreachable,
                    };
                    self.deadlines.insert(deadline_id, next) catch {
                        // Can't re-arm (OOM): fail the wait rather than
                        // park it forever with no wake-up scheduled.
                        _ = self.waiters.swapRemove(i);
                        self.finishWaiterError(waiter, error.OutOfMemory);
                    };
                },
                else => {
                    _ = self.waiters.swapRemove(i);
                    self.finishWaiter(waiter, .{
                        .timed_out = true,
                        .elapsed_ms = now - waiter.state.start_ms,
                    });
                },
            }
            return;
        }
    }

    /// Deliver a completed wait's response. The waiter must already be
    /// removed from the waiter list.
    fn finishWaiter(self: *LoopServer, waiter: *Waiter, result: ops.WaitResult) void {
        const encoded: ?[]u8 = ops.encodeWaitOutcome(
            self.alloc,
            waiter.id,
            waiter.sess,
            waiter.format,
            result,
        ) catch |err| encodeErrorLine(self.alloc, waiter.id, err) catch null;
        self.completeWaiter(waiter, encoded);
    }

    /// Deliver a structured error for a parked wait (doomed session,
    /// evaluation failure). The waiter must already be removed from the
    /// waiter list.
    fn finishWaiterError(self: *LoopServer, waiter: *Waiter, err: anyerror) void {
        const encoded: ?[]u8 = encodeErrorLine(self.alloc, waiter.id, err) catch null;
        self.completeWaiter(waiter, encoded);
    }

    fn completeWaiter(self: *LoopServer, waiter: *Waiter, encoded: ?[]u8) void {
        const conn = waiter.conn;
        conn.waiter = null;
        self.destroyWaiter(waiter);
        if (encoded) |bytes| {
            defer self.alloc.free(bytes);
            self.queueResponse(conn, bytes);
        } else {
            // Couldn't even build an error line (OOM); drop the conn.
            self.teardownConn(conn);
        }
    }

    /// Release everything a waiter owns: its deadline entry, its
    /// compiled regex, and its request arena. (The session outlives the
    /// waiter structurally — doomed sessions are only freed once no
    /// waiter references them.)
    fn destroyWaiter(self: *LoopServer, waiter: *Waiter) void {
        _ = self.deadlines.cancel(waiter.deadline_id);
        ops.freeWaitConditionRegex(waiter.condition);
        waiter.arena_state.deinit();
        self.alloc.destroy(waiter.arena_state);
        self.alloc.destroy(waiter);
    }

    /// Queue an encoded response and start draining. `bytes` is copied.
    fn queueResponse(self: *LoopServer, conn: *Conn, bytes: []const u8) void {
        const pending = conn.outbuf.items.len - conn.out_pos;
        if (pending > 0 and pending + bytes.len > max_outbound_bytes) {
            return self.teardownConn(conn);
        }
        conn.outbuf.appendSlice(self.alloc, bytes) catch return self.teardownConn(conn);
        conn.state = .draining;
        self.flushConn(conn);
    }

    /// Write out as much of the outbound buffer as the socket accepts.
    /// Arms POLLOUT when the socket blocks; closes the connection once a
    /// draining conn is fully flushed.
    fn flushConn(self: *LoopServer, conn: *Conn) void {
        const fd = conn.stream.handle;
        while (conn.out_pos < conn.outbuf.items.len) {
            const n = std.posix.write(fd, conn.outbuf.items[conn.out_pos..]) catch |err| switch (err) {
                error.WouldBlock => {
                    self.loop.armWrite(fd);
                    return;
                },
                else => return self.teardownConn(conn),
            };
            conn.out_pos += n;
        }
        if (conn.state == .draining) return self.teardownConn(conn);
        self.loop.disarmWrite(fd);
    }

    /// Close and free a connection, dropping any waiter parked on it.
    /// Attached conns must go through `reapAttachConn` (or `dropConn`)
    /// first so the subscriber leaves the session's broadcast list.
    fn teardownConn(self: *LoopServer, conn: *Conn) void {
        std.debug.assert(conn.attach_client == null);
        if (conn.waiter) |waiter| {
            conn.waiter = null;
            for (self.waiters.items, 0..) |w, i| {
                if (w == waiter) {
                    _ = self.waiters.swapRemove(i);
                    break;
                }
            }
            self.destroyWaiter(waiter);
        }
        if (conn.pending_watch_name) |n| {
            self.alloc.free(n);
            conn.pending_watch_name = null;
        }
        _ = self.loop.deregisterFd(conn.stream.handle);
        _ = self.conns.remove(conn.stream.handle);
        conn.stream.close();
        conn.inbuf.deinit(self.alloc);
        conn.outbuf.deinit(self.alloc);
        self.alloc.destroy(conn);
    }

    /// Flip a connection whose request line was `attach`/`watch` into its
    /// streaming role. The conn keeps its fd and its place in the loop;
    /// only its state changes. On setup failure the conn is torn down
    /// (the error line was already written by the setup path).
    fn beginAttach(self: *LoopServer, conn: *Conn, line: []const u8, read_only: bool) DispatchOutcome {
        const setup = handleAttachConnection(self.alloc, self.registry, conn.stream, line, read_only) catch |err| {
            std.debug.print("attach failed: {s}\n", .{@errorName(err)});
            self.teardownConn(conn);
            return .transitioned;
        };

        // `line` aliases the front of inbuf; drop the request line (and
        // its newline, when present) but keep anything after it — for a
        // successful attach those bytes are the client's first frames.
        const consumed = @min(line.len + 1, conn.inbuf.items.len);
        const rest_len = conn.inbuf.items.len - consumed;
        std.mem.copyForwards(u8, conn.inbuf.items[0..rest_len], conn.inbuf.items[consumed..]);
        conn.inbuf.shrinkRetainingCapacity(rest_len);

        switch (setup) {
            .done => self.teardownConn(conn),
            .attached => |client| {
                client.owned_by_conn = true;
                conn.attach_client = client;
                conn.state = .attached;
                if (client.pending.items.len > 0) self.loop.armWrite(conn.stream.handle);
                // Frames may have arrived glued to the request line.
                _ = self.consumeAttachFrames(conn);
            },
            .pending => |name_owned| {
                conn.inbuf.clearRetainingCapacity();
                conn.pending_watch_name = name_owned;
                conn.state = .pending_watch;
            },
        }
        return .transitioned;
    }

    /// Flush an attached conn's broadcast buffer on POLLOUT; reap it if a
    /// write error closed it, disarm write interest once drained.
    fn flushAttachConn(self: *LoopServer, conn: *Conn) void {
        const client = conn.attach_client.?;
        client.flushPending();
        if (client.isClosed()) return self.reapAttachConn(conn);
        if (client.pending.items.len == 0) self.loop.disarmWrite(conn.stream.handle);
    }

    /// Unhook an attached conn's subscriber from its session (logging the
    /// `attach_disconnect` — the single choke-point for graceful detach,
    /// EOF, buffer overflow, and exit broadcasts alike) and tear the conn
    /// down. The client must already be marked closed.
    fn reapAttachConn(self: *LoopServer, conn: *Conn) void {
        const client = conn.attach_client.?;
        conn.attach_client = null;
        self.detachSubscriber(client);
        self.teardownConn(conn);
    }

    /// Remove a conn-owned subscriber from its session's broadcast list
    /// (when the session is still alive), emit the disconnect event, and
    /// free the client's storage. The conn keeps ownership of the fd.
    fn detachSubscriber(self: *LoopServer, client: *AttachClient) void {
        if (!client.session_gone) {
            const sess = client.session;
            for (sess.attach_clients.items, 0..) |c, i| {
                if (c == client) {
                    _ = sess.attach_clients.swapRemove(i);
                    break;
                }
            }
            if (!client.disconnect_logged) {
                client.disconnect_logged = true;
                var arena_state = std.heap.ArenaAllocator.init(self.alloc);
                defer arena_state.deinit();
                log_mod.logAttachDisconnectEvent(arena_state.allocator(), sess, client.client_id);
            }
        }
        client.deinitDetached();
    }

    /// Once-per-iteration subscriber sync: reap attached conns whose
    /// client got marked closed (broadcast overflow, exit broadcast,
    /// write error), keep POLLOUT armed exactly for subscribers with
    /// buffered frames, and promote pending watchers whose session now
    /// exists (spawn turned into a state flip — formerly a dedicated
    /// watcher thread woken through a self-pipe).
    fn syncSubscribers(self: *LoopServer) void {
        var to_reap: std.ArrayListUnmanaged(*Conn) = .{};
        defer to_reap.deinit(self.alloc);
        var to_promote: std.ArrayListUnmanaged(*Conn) = .{};
        defer to_promote.deinit(self.alloc);

        var it = self.conns.valueIterator();
        while (it.next()) |conn_ptr| {
            const conn = conn_ptr.*;
            switch (conn.state) {
                .attached => {
                    const client = conn.attach_client.?;
                    if (client.isClosed()) {
                        to_reap.append(self.alloc, conn) catch {};
                        continue;
                    }
                    if (client.pending.items.len > 0) {
                        self.loop.armWrite(conn.stream.handle);
                    } else {
                        self.loop.disarmWrite(conn.stream.handle);
                    }
                },
                .pending_watch => to_promote.append(self.alloc, conn) catch {},
                else => {},
            }
        }
        for (to_reap.items) |conn| self.reapAttachConn(conn);
        for (to_promote.items) |conn| self.tryPromotePendingWatch(conn);
    }

    /// Promote a parked watch conn if a session with its exact name has
    /// appeared. Sends the `started` frame and the initial snapshot, then
    /// flips the conn to `attached` — same wire sequence the pre-loop
    /// watcher-promotion path produced.
    fn tryPromotePendingWatch(self: *LoopServer, conn: *Conn) void {
        const name = conn.pending_watch_name orelse return;
        const sess = self.registry.findByName(name) orelse return;

        const client = server_attach.promoteWatchSubscriber(self.alloc, sess, conn.stream) catch {
            return self.teardownConn(conn);
        };
        client.owned_by_conn = true;
        self.alloc.free(name);
        conn.pending_watch_name = null;
        conn.attach_client = client;
        conn.state = .attached;
        if (client.pending.items.len > 0) self.loop.armWrite(conn.stream.handle);
    }

    /// Once-per-iteration PTY sync: reconcile the poll set with the
    /// registry — every live session's master fd polls for POLLIN, with
    /// POLLOUT armed exactly while its pending-input buffer is non-empty
    /// (so a wedged child's fd wakes the loop the moment it drains its
    /// tty input queue). Sessions that died, were killed, or were doomed
    /// this iteration drop out of the desired set and get deregistered
    /// here — before the deferred-free phase, so `session_fds` never
    /// holds a pointer across a free. Also keeps the waitpid-retry
    /// deadline armed while any dead child remains unreaped.
    fn syncSessionPtys(self: *LoopServer, now: i64) void {
        var desired: std.ArrayListUnmanaged(SessionRegistry.PtyInterest) = .{};
        defer desired.deinit(self.alloc);
        self.registry.collectPtyInterest(self.alloc, &desired);

        // Deregister fds no longer wanted.
        var stale: std.ArrayListUnmanaged(std.posix.fd_t) = .{};
        defer stale.deinit(self.alloc);
        var it = self.session_fds.keyIterator();
        while (it.next()) |fd_ptr| {
            const fd = fd_ptr.*;
            const still_wanted = for (desired.items) |d| {
                if (d.fd == fd) break true;
            } else false;
            if (!still_wanted) stale.append(self.alloc, fd) catch {};
        }
        for (stale.items) |fd| {
            _ = self.loop.deregisterFd(fd);
            _ = self.session_fds.remove(fd);
        }

        for (desired.items) |d| {
            if (self.session_fds.getPtr(d.fd)) |slot| {
                slot.* = d.sess;
                if (d.write) self.loop.armWrite(d.fd) else self.loop.disarmWrite(d.fd);
            } else {
                self.loop.registerFd(d.fd, .{ .read = true, .write = d.write }) catch continue;
                self.session_fds.put(self.alloc, d.fd, d.sess) catch {
                    _ = self.loop.deregisterFd(d.fd);
                };
            }
        }

        // Kill paths close the master fd without going through
        // `ptyReady`, so the reap retry has to be (re)armed here too.
        if (!self.reap_armed and self.registry.anyReapPending()) {
            self.armReapRetry(now);
        }
    }

    /// Deferred-free phase: free doomed sessions, except those still
    /// referenced by a parked waiter. Non-duration waiters on doomed
    /// sessions were already resolved by `evaluateWaiters` this
    /// iteration; `duration` waiters deliberately survive dooming (a
    /// duration wait completes even if the session is deleted mid-sleep)
    /// and their session's storage must survive with them — it is freed
    /// on the iteration the duration completes.
    fn freeDoomedSessions(self: *LoopServer) void {
        const doomed = &self.registry.doomed;
        var i: usize = 0;
        outer: while (i < doomed.items.len) {
            const sess = doomed.items[i];
            for (self.waiters.items) |waiter| {
                if (waiter.sess == sess) {
                    i += 1;
                    continue :outer;
                }
            }
            _ = doomed.swapRemove(i);
            sess.deinit();
            self.registry.alloc.destroy(sess);
        }
    }
};

/// The earliest instant an idle wait could possibly be satisfied, given
/// the current screen-change reference — the loop arms this as the
/// waiter's re-check deadline. Always at least `now + 1` so a re-arm can
/// never busy-loop on an already-passed instant.
fn idleWakeMs(sess: *Session, cfg: anytype, now: i64) i64 {
    const reference = if (cfg.floor_ms) |floor|
        @max(sess.getLastScreenChange(), floor)
    else
        sess.getLastScreenChange();
    return @max(reference + cfg.idle_ms, now + 1);
}

fn encodeErrorLine(alloc: Allocator, id: ?i64, err: anyerror) ![]u8 {
    return encodeResponse(alloc, .{ .id = id, .ok = false, .@"error" = requestErrorMessage(err) });
}

/// Result of parsing a request line up to (but not including) dispatch.
const ParsedRequest = union(enum) {
    /// The parse failed; carries the encoded error response line
    /// (caller-owned) to send back.
    invalid: []u8,
    valid: struct {
        object: std.json.ObjectMap,
        op: []const u8,
        id: ?i64,
    },
};

/// Parse a request line into `arena`. Strings are always copied into the
/// arena (`alloc_always`) so the caller may discard `line` immediately —
/// a parked waiter's condition outlives the connection's read buffer.
fn parseRequestLine(alloc: Allocator, arena: Allocator, line: []const u8) !ParsedRequest {
    const value = std.json.parseFromSliceLeaky(std.json.Value, arena, line, .{
        .allocate = .alloc_always,
    }) catch |err| {
        return .{ .invalid = try encodeResponse(alloc, .{
            .ok = false,
            .@"error" = @errorName(err),
        }) };
    };

    const object = switch (value) {
        .object => |object| object,
        else => {
            return .{ .invalid = try encodeResponse(alloc, .{
                .ok = false,
                .@"error" = "request must be a JSON object",
            }) };
        },
    };

    const id = readOptionalId(object);
    const op = readRequiredString(object, "op") catch |err| {
        return .{ .invalid = try encodeResponse(alloc, .{
            .id = id,
            .ok = false,
            .@"error" = @errorName(err),
        }) };
    };

    return .{ .valid = .{ .object = object, .op = op, .id = id } };
}

/// Single-threaded, in-process request dispatch: one request line in, one
/// encoded response line out. This is the entry point the test suite's
/// in-process harness drives directly; the socket server dispatches
/// through the event loop instead (`LoopServer.dispatchOnLoop`), which
/// shares `parseRequestLine` and `dispatchRequest` with this path.
pub fn processRequestLine(alloc: Allocator, registry: *SessionRegistry, line: []const u8) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    switch (try parseRequestLine(alloc, arena, line)) {
        .invalid => |response| return response,
        .valid => |req| {
            const response: Response = dispatchRequest(arena, registry, req.object, req.op, req.id) catch |err| .{
                .id = req.id,
                .ok = false,
                .@"error" = requestErrorMessage(err),
            };
            return encodeResponse(alloc, response);
        },
    }
}

/// How to invoke an op handler. The variants mirror the handful of handler
/// signatures in `ops.zig`; the top-level split is whether the op needs a
/// resolved session (`session: false` ops run before any registry lookup,
/// so unknown ops surface as UnknownOperation rather than SessionNotFound).
const OpHandler = union(enum) {
    // Registry-level ops — no session resolution.
    registry: *const fn (Allocator, *SessionRegistry, ?i64) anyerror!Response,
    registry_obj: *const fn (Allocator, *SessionRegistry, std.json.ObjectMap, ?i64) anyerror!Response,
    // Session ops — dispatch resolves + borrows the session first.
    session: *const fn (Allocator, *Session, ?i64) anyerror!Response,
    session_obj: *const fn (Allocator, *Session, std.json.ObjectMap, ?i64) anyerror!Response,
    registry_session: *const fn (Allocator, *SessionRegistry, *Session, ?i64) anyerror!Response,
    registry_session_obj: *const fn (Allocator, *SessionRegistry, *Session, std.json.ObjectMap, ?i64) anyerror!Response,
};

const OpEntry = struct {
    name: []const u8,
    handler: OpHandler,
};

/// The single source of truth for the RPC surface: op name → handler.
/// Adding an op means adding exactly one row here. (`attach`/`watch` are
/// deliberately absent — they hijack the connection and are branched off
/// before normal dispatch.) The wait ops appear here for the in-process
/// path; the event loop intercepts them (`ops.waitOpKind`) and parks the
/// connection instead of blocking in the handler.
const op_table = [_]OpEntry{
    .{ .name = "spawn", .handler = .{ .registry_obj = ops.handleSpawn } },
    .{ .name = "list", .handler = .{ .registry = ops.handleList } },
    .{ .name = "info", .handler = .{ .registry = ops.handleInfo } },
    .{ .name = "snapshot", .handler = .{ .session = ops.handleSnapshot } },
    .{ .name = "send_text", .handler = .{ .session_obj = ops.handleSendText } },
    .{ .name = "send_key", .handler = .{ .session_obj = ops.handleSendKey } },
    .{ .name = "send_bytes_hex", .handler = .{ .session_obj = ops.handleSendBytesHex } },
    .{ .name = "send_mouse", .handler = .{ .session_obj = ops.handleSendMouse } },
    .{ .name = "resize", .handler = .{ .session_obj = ops.handleResize } },
    .{ .name = "wait_for_text", .handler = .{ .registry_session_obj = ops.handleWaitForText } },
    .{ .name = "wait_for_idle", .handler = .{ .registry_session_obj = ops.handleWaitForIdle } },
    .{ .name = "wait_for_exit", .handler = .{ .registry_session_obj = ops.handleWaitForExit } },
    .{ .name = "kill", .handler = .{ .registry_session = ops.handleKill } },
    .{ .name = "delete", .handler = .{ .registry_session = ops.handleDelete } },
    .{ .name = "wait_and_snapshot", .handler = .{ .registry_session_obj = ops.handleWaitAndSnapshot } },
};

pub fn dispatchRequest(
    arena: Allocator,
    registry: *SessionRegistry,
    object: std.json.ObjectMap,
    op: []const u8,
    id: ?i64,
) !Response {
    // Validate the op before touching the session registry so unknown ops
    // surface as UnknownOperation rather than SessionNotFound.
    const entry = blk: {
        for (&op_table) |*candidate| {
            if (std.mem.eql(u8, op, candidate.name)) break :blk candidate;
        }
        return error.UnknownOperation;
    };

    switch (entry.handler) {
        .registry => |handler| return handler(arena, registry, id),
        .registry_obj => |handler| return handler(arena, registry, object, id),
        else => {},
    }

    const session_ref = try readOptionalString(object, "session");
    // The resolved pointer is valid for the duration of this dispatch,
    // guaranteed structurally: nothing else runs on this thread, and a
    // handler that deletes the session (`delete`, or state the `--remove`
    // sweep will act on later) only unpublishes it — the storage is freed
    // in the loop's deferred-free phase, never mid-dispatch.
    const sess = try registry.resolveOrSole(session_ref);

    return switch (entry.handler) {
        .registry, .registry_obj => unreachable, // dispatched above
        .session => |handler| handler(arena, sess, id),
        .session_obj => |handler| handler(arena, sess, object, id),
        .registry_session => |handler| handler(arena, registry, sess, id),
        .registry_session_obj => |handler| handler(arena, registry, sess, object, id),
    };
}
