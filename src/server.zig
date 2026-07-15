//! The hty server: a single-threaded event loop over `poll(2)`.
//!
//! Phase 1 of the event-loop migration: RPC connections are loop-owned
//! `Conn` state machines driven by `src/loop.zig` — no worker threads.
//! Immediate ops dispatch synchronously on the loop thread and queue
//! their response into a bounded per-connection outbound buffer flushed
//! on `POLLOUT`. Wait ops park the connection in a waiter table and are
//! re-evaluated after each housekeeping drain and on deadline expiry, so
//! a long `wait_for_*` costs a table entry instead of a thread.
//!
//! Still thread-based for now (later phases): attach/watch connections
//! keep their existing reader-thread handoff, and each session keeps its
//! PTY reader thread pumping the terminal event queue that the recurring
//! housekeeping deadline drains via `registry.drainAll()` every 25ms.
//! `registry.mutex` therefore remains — it fences the loop thread against
//! those surviving threads.

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
const setStreamNonBlocking = session_mod.setStreamNonBlocking;

const ops = @import("ops.zig");

const loop_mod = @import("loop.zig");
const Loop = loop_mod.Loop;
const DeadlineTable = loop_mod.DeadlineTable;

const server_attach = @import("server_attach.zig");
const ConnectionResult = server_attach.ConnectionResult;
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

/// Interval of the recurring housekeeping deadline. This is the explicit
/// successor of the old unconditional 25ms accept-loop tick: it drains
/// the terminals' event queues into the log / attach broadcast pipeline
/// and re-evaluates parked waiters. It disappears in phase 3, when PTY
/// fds join the poll set and there is nothing left to drain.
const housekeeping_interval_ms: i64 = 25;

// Deadline-table ids. Waiter ids are allocated upward from
// `first_waiter_deadline_id`; the two fixed ids below never collide.
const housekeeping_deadline_id: u64 = 1;
const empty_shutdown_deadline_id: u64 = 2;
const first_waiter_deadline_id: u64 = 3;

/// Optional configuration for the server loop. Production uses the
/// defaults; tests pass a short `empty_grace_ms` and/or a `stop_signal`
/// they can flip externally so the loop exits promptly.
pub const RunOpts = struct {
    empty_grace_ms: i64 = empty_grace_ms,
    /// If non-null, the loop returns as soon as it observes this flag set
    /// to true (checked at least once per housekeeping interval).
    stop_signal: ?*std.atomic.Value(bool) = null,
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

    // Resolve the session log directory best-effort. If it can't be set up,
    // the server still runs — log hooks skip when registry.log_dir is null.
    const log_dir_opt: ?[]u8 = resolveLogDir(alloc) catch |err| blk: {
        std.debug.print("warning: session log dir unavailable ({s}) — logging disabled\n", .{@errorName(err)});
        break :blk null;
    };
    defer if (log_dir_opt) |d| alloc.free(d);
    if (log_dir_opt) |d| {
        const by_name = std.fmt.allocPrint(alloc, "{s}/by-name", .{d}) catch null;
        if (by_name) |bn| {
            defer alloc.free(bn);
            ensureOwnedDir(alloc, bn) catch |err| {
                std.debug.print("warning: by-name dir setup failed: {s}\n", .{@errorName(err)});
            };
        }
        registry.log_dir = d;
    }

    var srv = LoopServer{
        .alloc = alloc,
        .registry = &registry,
        .listen_fd = server.stream.handle,
        .empty_grace_ms = opts.empty_grace_ms,
        .loop = Loop.init(alloc),
        .deadlines = DeadlineTable.init(alloc),
    };
    // Runs before `registry.deinit()`: waiters hold session borrows that
    // must be released while the registry is still alive.
    defer srv.deinit();

    try srv.loop.registerFd(srv.listen_fd, .{});
    try srv.deadlines.insert(housekeeping_deadline_id, std.time.milliTimestamp() + housekeeping_interval_ms);

    // Auto-shutdown: the server starts empty, so arm the shutdown deadline
    // right away (the old code's `empty_since_ms = now` initialization). A
    // new session or connection cancels it on the next housekeeping tick.
    if (srv.deadlines.insert(empty_shutdown_deadline_id, std.time.milliTimestamp() + opts.empty_grace_ms)) {
        srv.empty_armed = true;
    } else |_| {}

    while (true) {
        const timeout = srv.deadlines.nextTimeoutMs(std.time.milliTimestamp());
        var ready = srv.loop.waitReady(timeout) catch |err| {
            std.debug.print("poll failed: {s}\n", .{@errorName(err)});
            continue;
        };
        while (ready.next()) |r| {
            if (r.fd == srv.listen_fd) {
                srv.acceptReady();
            } else {
                srv.connReady(r.fd, r.revents);
            }
        }

        // Ops dispatched above may have changed what parked waiters are
        // watching (kill/delete/send_*): re-evaluate now so, e.g., a
        // `delete` resolves that session's waiters in the same iteration.
        srv.evaluateWaiters();

        var now = std.time.milliTimestamp();
        while (srv.deadlines.popExpired(now)) |expired| {
            switch (expired.id) {
                housekeeping_deadline_id => {
                    srv.housekeeping(now);
                    // Re-arm the recurring tick. The table just popped an
                    // entry, so this insert reuses retained capacity and
                    // cannot fail in practice; a failure would stall
                    // housekeeping, so surface it loudly.
                    srv.deadlines.insert(housekeeping_deadline_id, now + housekeeping_interval_ms) catch |err| {
                        std.debug.print("housekeeping re-arm failed: {s}\n", .{@errorName(err)});
                    };
                },
                empty_shutdown_deadline_id => {
                    srv.empty_armed = false;
                    if (srv.serverIsEmpty()) return;
                },
                else => srv.waiterDeadlineExpired(expired.id, now),
            }
            now = std.time.milliTimestamp();
        }

        // External stop signal (test harness) wins over the empty timer.
        if (opts.stop_signal) |flag| {
            if (flag.load(.acquire)) return;
        }
    }
}

/// One RPC connection owned by the event loop.
const Conn = struct {
    stream: std.net.Stream,
    state: State = .reading_request,
    /// Request bytes accumulated while hunting for the newline. Cleared
    /// once a line has been dispatched; anything a client sends after its
    /// request line is discarded (the protocol is one request, one
    /// response, close — same as the old per-connection reader).
    inbuf: std.ArrayListUnmanaged(u8) = .{},
    /// Outbound bytes not yet accepted by the socket, flushed on POLLOUT.
    /// Bounded by `max_outbound_bytes` (see its doc for the exact rule).
    outbuf: std.ArrayListUnmanaged(u8) = .{},
    /// Bytes of `outbuf` already written to the socket.
    out_pos: usize = 0,
    /// Set when this connection is parked in the waiter table.
    waiter: ?*Waiter = null,
    /// True once EOF was seen and read interest dropped (half-close while
    /// waiting or draining) so the loop stops polling a finished stream.
    read_disabled: bool = false,

    const State = enum {
        /// Accumulating bytes until the request line's newline.
        reading_request,
        /// Parked in the waiter table; the response comes later.
        waiting,
        /// Response queued; flush the outbound buffer, then close.
        draining,
    };
};

/// One parked wait: everything needed to re-evaluate the condition and,
/// on completion, format the response the blocking handler would have
/// produced. Holds a session borrow (released on resolution) and owns the
/// arena the parsed request lives in (the condition's needle points into
/// it).
const Waiter = struct {
    deadline_id: u64,
    conn: *Conn,
    sess: *Session,
    arena_state: *std.heap.ArenaAllocator,
    condition: ops.WaitCondition,
    state: ops.WaitState,
    /// Absolute timeout deadline; `maxInt(i64)` (never inserted in the
    /// deadline table) when the wait has no timeout. `duration` waits use
    /// their completion time as the deadline entry instead.
    id: ?i64,
    format: ops.WaitFormat,
};

/// What became of a dispatched request line.
const DispatchOutcome = union(enum) {
    /// An encoded response line (caller-owned) to queue and drain.
    response: []u8,
    /// The connection was parked in the waiter table.
    parked,
    /// Attach/watch: the stream was handed to the attach machinery (or
    /// closed on failure) and the `Conn` was destroyed.
    handed_off,
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
    next_waiter_deadline_id: u64 = first_waiter_deadline_id,
    /// True while accepts are suspended after EMFILE/ENFILE; the next
    /// housekeeping tick re-registers the listen fd.
    listen_paused: bool = false,
    /// True while the empty-shutdown deadline entry is in the table.
    empty_armed: bool = false,

    fn deinit(self: *LoopServer) void {
        // Waiters first — they hold session borrows that must be released
        // while the registry is still alive. Their conns are torn down by
        // the sweep below.
        for (self.waiters.items) |waiter| {
            waiter.conn.waiter = null;
            self.destroyWaiter(waiter);
        }
        self.waiters.deinit(self.alloc);

        var it = self.conns.valueIterator();
        while (it.next()) |conn_ptr| {
            const conn = conn_ptr.*;
            conn.stream.close();
            conn.inbuf.deinit(self.alloc);
            conn.outbuf.deinit(self.alloc);
            self.alloc.destroy(conn);
        }
        self.conns.deinit(self.alloc);

        self.loop.deinit();
        self.deadlines.deinit();
    }

    /// The recurring 25ms tick: drain terminal event queues (log writes,
    /// attach broadcasts, lifecycle transitions, auto-remove sweep),
    /// re-evaluate parked waiters against the fresh state, resume accepts
    /// after an EMFILE pause, and keep the empty-shutdown deadline in sync
    /// with whether the server has anything left to do.
    fn housekeeping(self: *LoopServer, now: i64) void {
        self.registry.drainAll();
        self.evaluateWaiters();

        if (self.listen_paused) {
            if (self.loop.registerFd(self.listen_fd, .{})) {
                self.listen_paused = false;
            } else |_| {} // retry next tick
        }

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
                    // socket to answer on. Pause accepts until the next
                    // housekeeping tick instead of spinning on a listen fd
                    // that will stay readable; existing connections keep
                    // being served (PRD §6).
                    std.debug.print("accept failed: {s} — pausing accepts\n", .{@errorName(err)});
                    _ = self.loop.deregisterFd(self.listen_fd);
                    self.listen_paused = true;
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
        const conn = try self.alloc.create(Conn);
        errdefer self.alloc.destroy(conn);
        conn.* = .{ .stream = .{ .handle = fd } };
        try self.conns.put(self.alloc, fd, conn);
        errdefer _ = self.conns.remove(fd);
        try self.loop.registerFd(fd, .{});
    }

    fn connReady(self: *LoopServer, fd: std.posix.socket_t, revents: i16) void {
        if ((revents & (std.posix.POLL.ERR | std.posix.POLL.NVAL)) != 0) {
            if (self.conns.get(fd)) |conn| self.teardownConn(conn);
            return;
        }
        if ((revents & std.posix.POLL.OUT) != 0) {
            if (self.conns.get(fd)) |conn| self.flushConn(conn);
        }
        // Re-lookup after the flush: it may have completed the drain (or
        // hit a write error) and destroyed the conn.
        if ((revents & (std.posix.POLL.IN | std.posix.POLL.HUP)) != 0) {
            if (self.conns.get(fd)) |conn| {
                self.readConn(conn, (revents & std.posix.POLL.HUP) != 0);
            }
        }
    }

    /// Drain readable bytes. `hup` reports whether poll flagged POLLHUP —
    /// on EOF it distinguishes a fully-gone peer (tear down; nobody can
    /// read a response) from a half-close (stop reading, keep flushing).
    fn readConn(self: *LoopServer, conn: *Conn, hup: bool) void {
        var chunk: [4096]u8 = undefined;
        while (true) {
            const n = std.posix.read(conn.stream.handle, &chunk) catch |err| switch (err) {
                error.WouldBlock => return,
                else => return self.teardownConn(conn),
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
                // One request per connection: bytes past the request line
                // are discarded, exactly like the old reader that never
                // looked past the first newline.
                .waiting, .draining => {},
            }
        }
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
            .handed_off => {},
        }
    }

    /// The loop-side twin of `processRequestLine`: same parse and
    /// dispatch semantics, plus the two paths that need the connection
    /// itself — attach/watch handoff and wait parking.
    fn dispatchOnLoop(self: *LoopServer, conn: *Conn, line: []const u8) !DispatchOutcome {
        if (std.mem.trim(u8, line, " \t\r").len == 0) {
            return .{ .response = try encodeResponse(self.alloc, .{ .ok = false, .@"error" = "empty request" }) };
        }

        // Peek at the op before normal dispatch; attach and watch need a
        // different lifecycle (hand the socket to the attach machinery).
        switch (detectAttachOp(self.alloc, line)) {
            .attach => return self.handoffAttach(conn, line, false),
            .watch => return self.handoffAttach(conn, line, true),
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
        var borrow_held = true;
        defer if (borrow_held) self.registry.release(sess);

        // First evaluation mirrors `runWait`'s first iteration — drain,
        // evaluate, then the doomed check — so an already-satisfied wait
        // answers without parking, and a satisfied-and-doomed session
        // (wait_for_exit on a `--remove` session) still reports success.
        self.registry.drainAll();
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
        // the completion time; other kinds get their timeout deadline
        // (none at all when the timeout is disabled).
        const entry_ms: ?i64 = switch (condition) {
            .duration => |duration_ms| start_ms + @as(i64, @intCast(duration_ms)),
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
            .id = id,
            .format = plan.format,
        };
        try self.waiters.append(self.alloc, waiter);
        errdefer _ = self.waiters.pop();
        if (entry_ms) |deadline_ms| try self.deadlines.insert(waiter.deadline_id, deadline_ms);
        self.next_waiter_deadline_id += 1;

        conn.waiter = waiter;
        conn.state = .waiting;
        borrow_held = false; // the waiter owns the session borrow now
        regex_owned = false; // and the compiled regex
        return .parked;
    }

    /// Re-evaluate every parked waiter against current session state.
    /// Called after each housekeeping drain and after each iteration's
    /// dispatches, so PTY output, kills, and deletes resolve waits on the
    /// iteration that produced them (within the drain's 25ms cadence).
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
    /// timeout for everything else (matching `runWait`, which reported
    /// timeout without a final re-evaluation — the last one was at most a
    /// housekeeping interval ago).
    fn waiterDeadlineExpired(self: *LoopServer, deadline_id: u64, now: i64) void {
        for (self.waiters.items, 0..) |waiter, i| {
            if (waiter.deadline_id != deadline_id) continue;
            if (waiter.condition == .duration) {
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
                } else {
                    // Clock jitter left the duration a hair short; re-arm.
                    self.deadlines.insert(deadline_id, now + 1) catch {};
                }
            } else {
                _ = self.waiters.swapRemove(i);
                self.finishWaiter(waiter, .{
                    .timed_out = true,
                    .elapsed_ms = now - waiter.state.start_ms,
                });
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

    /// Release everything a waiter owns: its deadline entry, its session
    /// borrow, its compiled regex, and its request arena.
    fn destroyWaiter(self: *LoopServer, waiter: *Waiter) void {
        _ = self.deadlines.cancel(waiter.deadline_id);
        self.registry.release(waiter.sess);
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
    fn teardownConn(self: *LoopServer, conn: *Conn) void {
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
        _ = self.loop.deregisterFd(conn.stream.handle);
        _ = self.conns.remove(conn.stream.handle);
        conn.stream.close();
        conn.inbuf.deinit(self.alloc);
        conn.outbuf.deinit(self.alloc);
        self.alloc.destroy(conn);
    }

    /// Hand an attach/watch connection to the existing thread-based attach
    /// machinery (absorbed into the loop in phase 2). The `Conn` leaves
    /// the loop's bookkeeping either way; the stream is owned by the
    /// attach client (or pending watcher) on success and closed on
    /// failure.
    fn handoffAttach(self: *LoopServer, conn: *Conn, line: []const u8, read_only: bool) DispatchOutcome {
        const fd = conn.stream.handle;
        _ = self.loop.deregisterFd(fd);
        _ = self.conns.remove(fd);

        // The attach bring-up writes its ack and initial snapshot with
        // blocking semantics and flips the socket non-blocking itself
        // once the client is on the broadcast list — restore blocking
        // mode so that path behaves exactly as it did under the old
        // thread handoff.
        setStreamBlocking(fd) catch {};

        const result = handleAttachConnection(self.alloc, self.registry, conn.stream, line, read_only) catch |err| blk: {
            std.debug.print("attach failed: {s}\n", .{@errorName(err)});
            break :blk ConnectionResult.done;
        };
        switch (result) {
            .done => conn.stream.close(),
            .attached => {}, // The attach machinery owns the stream now.
        }
        conn.inbuf.deinit(self.alloc);
        conn.outbuf.deinit(self.alloc);
        self.alloc.destroy(conn);
        return .handed_off;
    }
};

/// Undo `setStreamNonBlocking` (see `handoffAttach`).
fn setStreamBlocking(fd: std.posix.socket_t) !void {
    const flags = try std.posix.fcntl(fd, std.posix.F.GETFL, 0);
    const nonblock: usize = @as(u32, @bitCast(std.posix.O{ .NONBLOCK = true }));
    _ = try std.posix.fcntl(fd, std.posix.F.SETFL, flags & ~nonblock);
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
    const sess = try registry.resolveOrSole(session_ref);
    // `resolveOrSole` handed us a borrow (refcount incremented under the
    // registry lock). Release it on every exit path — normal return AND
    // error return from any handler below — so a concurrent `delete` or
    // `--remove` sweep can unpublish the session immediately while the
    // storage stays alive until this borrow (the last one) is dropped.
    defer registry.release(sess);

    return switch (entry.handler) {
        .registry, .registry_obj => unreachable, // dispatched above
        .session => |handler| handler(arena, sess, id),
        .session_obj => |handler| handler(arena, sess, object, id),
        .registry_session => |handler| handler(arena, registry, sess, id),
        .registry_session_obj => |handler| handler(arena, registry, sess, object, id),
    };
}
