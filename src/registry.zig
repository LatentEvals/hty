//! SessionRegistry — the server's top-level container for all active and
//! zombie sessions. Owns a `by_id` map (UUID -> Session) and a `name_index`
//! for the human-friendly alias lookup, plus the PTY servicing pipeline:
//! the event loop (or the in-process `pump`) reads each session's master
//! fd and dispatches output synchronously — VT feed, session log, attach
//! broadcast, lifecycle transitions.
//!
//! Single-threaded by design: every function here runs on the server's
//! one event-loop thread (or the single test thread). There are no locks,
//! no atomics, and no refcounts — session lifetime is structural. Deleting
//! a session (`remove`) unpublishes it from the maps immediately and parks
//! it on the `doomed` list; the storage is freed in a deferred phase
//! (`freeDoomed`, run by the loop at end of iteration and by `deinit`),
//! never in the middle of a dispatch that may still hold the pointer.
//!
//! The registry does not own the log directory path — it's borrowed from
//! the caller (usually `runServer`) and may be null in unit tests, which
//! makes session spawn/servicing hooks silently skip log-file operations.

const std = @import("std");
const sys = @import("hty").sys;
const hty = @import("hty");
const session_mod = @import("session.zig");
const uuid_mod = @import("uuid.zig");
const log_mod = @import("log.zig");
const attach = @import("attach.zig");

const Allocator = std.mem.Allocator;
const Session = session_mod.Session;

pub const SessionRegistry = struct {
    alloc: Allocator,
    /// Io instance for session terminal construction (ghostty's
    /// Terminal.init requires one as of Zig 0.16). Set once at init;
    /// the registry itself does its file work at the syscall level.
    io: std.Io,
    by_id: std.StringHashMapUnmanaged(*Session) = .{},
    name_index: std.StringHashMapUnmanaged(*Session) = .{},
    /// Absolute path to the session log directory. Borrowed from the caller
    /// (runServer owns the allocation). If null, session spawn/servicing
    /// hooks skip log-file operations — used by unit tests.
    log_dir: ?[]const u8 = null,
    /// Sessions unpublished from the maps but not yet freed. `remove`
    /// appends here; `freeDoomed` (the loop's end-of-iteration deferred-
    /// free phase, or `deinit`) tears them down. Deferral guarantees a
    /// `*Session` obtained by resolve stays valid for the remainder of
    /// the current dispatch/iteration even if that dispatch deletes it.
    doomed: std.ArrayListUnmanaged(*Session) = .empty,
    /// Unix-epoch milliseconds at which this registry was created. Used by
    /// `hty info --json` to report the server's uptime.
    started_at_ms: i64 = 0,

    pub fn init(alloc: Allocator, io: std.Io) SessionRegistry {
        return .{
            .alloc = alloc,
            .io = io,
            .started_at_ms = sys.milliTimestamp(),
        };
    }

    pub fn deinit(self: *SessionRegistry) void {
        self.freeDoomed();
        self.doomed.deinit(self.alloc);
        var it = self.by_id.valueIterator();
        while (it.next()) |sess_ptr| {
            sess_ptr.*.deinit();
            self.alloc.destroy(sess_ptr.*);
        }
        self.by_id.deinit(self.alloc);
        self.name_index.deinit(self.alloc);
    }

    /// Create a new session. Takes ownership of `program_owned`, `args_joined_owned`,
    /// and `name_owned` (all freed when the session is destroyed).
    pub fn create(
        self: *SessionRegistry,
        terminal: *hty.InteractiveTerminal,
        program_owned: []u8,
        args_joined_owned: []u8,
        name_owned: ?[]u8,
    ) !*Session {
        if (name_owned) |n| {
            if (self.name_index.contains(n)) return error.NameAlreadyExists;
            // `nameInUse` is a single O(1) access on the authoritative
            // by-name symlink (a one-time startup reconciliation covers
            // logs from older hty versions).
            if (log_mod.nameInUse(self.alloc, self.log_dir, n)) return error.NameAlreadyExists;
        }

        const sess = try self.alloc.create(Session);
        errdefer self.alloc.destroy(sess);

        const now = sys.milliTimestamp();
        sess.* = .{
            .alloc = self.alloc,
            .id = undefined,
            .name = name_owned,
            .terminal = terminal,
            .program = program_owned,
            .args_joined = args_joined_owned,
            .created_at_ms = now,
            .last_screen_change_at_ms = now,
        };
        uuid_mod.generateUuidV7(&sess.id);

        // Server sessions are serviced by the event loop (or the pump):
        // the master fd must be non-blocking so reads stop at WouldBlock
        // and queued input writes can never stall the loop.
        session_mod.setStreamNonBlocking(terminal.master_fd) catch {};

        try self.by_id.put(self.alloc, &sess.id, sess);
        if (name_owned) |n| try self.name_index.put(self.alloc, n, sess);
        return sess;
    }

    /// Exact-name lookup used by the event loop to promote parked
    /// `pending_watch` connections when their target session appears.
    /// Prefix/id resolution is deliberately not applied — promotion keys
    /// on the exact name the watcher asked for. The returned pointer is
    /// valid for the current iteration (structural guarantee: frees are
    /// deferred to the end-of-iteration phase).
    pub fn findByName(self: *SessionRegistry, name: []const u8) ?*Session {
        return self.name_index.get(name);
    }

    /// Resolve a session reference (full UUID, unique prefix, or name).
    /// Returns null if no match. Returns error.AmbiguousPrefix if prefix
    /// matches 2+. The returned pointer is valid for the duration of the
    /// current dispatch/iteration.
    pub fn resolve(self: *SessionRegistry, reference: []const u8) !?*Session {
        if (self.by_id.get(reference)) |sess| return sess;
        if (self.name_index.get(reference)) |sess| return sess;
        var match_count: usize = 0;
        var match: ?*Session = null;
        var it = self.by_id.iterator();
        while (it.next()) |entry| {
            if (std.mem.startsWith(u8, entry.key_ptr.*, reference)) {
                match_count += 1;
                match = entry.value_ptr.*;
                if (match_count > 1) return error.AmbiguousPrefix;
            }
        }
        return match;
    }

    /// Resolve or pick the sole session when reference is null. The
    /// returned pointer is valid for the duration of the current dispatch
    /// — nothing else runs on this thread, and deletion defers the free
    /// to the loop's end-of-iteration phase.
    pub fn resolveOrSole(self: *SessionRegistry, reference: ?[]const u8) !*Session {
        if (reference) |r| {
            return (try self.resolve(r)) orelse error.SessionNotFound;
        }
        if (self.by_id.count() == 0) return error.SessionNotFound;
        if (self.by_id.count() > 1) return error.AmbiguousPrefix;
        var it = self.by_id.valueIterator();
        return it.next().?.*;
    }

    /// Unpublish a session: no resolve can find it afterwards, and it is
    /// marked doomed so parked waiters resolve with the structured
    /// session-not-found result. The storage is NOT freed here — it lands
    /// on the doomed list and is torn down by `freeDoomed`.
    pub fn remove(self: *SessionRegistry, sess: *Session) void {
        _ = self.by_id.remove(&sess.id);
        if (sess.name) |n| _ = self.name_index.remove(n);
        sess.doomed = true;
        self.doomed.append(self.alloc, sess) catch {
            // Can't park it for deferred free (OOM): freeing immediately
            // would risk a mid-dispatch UAF, leaking one session under
            // memory exhaustion is the lesser evil.
        };
    }

    /// Deferred-free phase: tear down every doomed session. The event
    /// loop calls this at the end of each iteration (after waiters on
    /// doomed sessions have been resolved); `deinit` calls it as a
    /// backstop for the in-process path.
    pub fn freeDoomed(self: *SessionRegistry) void {
        for (self.doomed.items) |sess| {
            sess.deinit();
            self.alloc.destroy(sess);
        }
        self.doomed.clearRetainingCapacity();
    }

    /// Outcome of one `servicePty` pass, from the loop's point of view.
    pub const PtyService = enum {
        /// PTY still open; keep polling it.
        open,
        /// Child gone and reaped — exit fully processed (now or earlier).
        reaped,
        /// EOF observed (or the fd was closed by kill) but the child
        /// wasn't reapable yet — retry shortly.
        reap_pending,
        /// PTY read failed; the session was marked failed and its fd is
        /// no longer polled.
        broken,
    };

    /// Service one session's PTY: read whatever the master fd has ready
    /// (8 KiB chunks, until WouldBlock) and dispatch it synchronously; on
    /// EOF/EIO, reap the child with waitpid(WNOHANG) and run the exit
    /// transition. Also the reap-retry entry point for sessions whose fd
    /// was closed by `kill`.
    pub fn servicePty(self: *SessionRegistry, sess: *Session) PtyService {
        const term = sess.terminal;
        if (term.reaped) return .reaped;
        if (!term.closed and sess.pty_state == .open) {
            switch (self.pumpSession(sess)) {
                .open => return .open,
                .eof => {},
                .broken => return .broken,
            }
        }
        if (sess.pty_state == .broken) return .broken;
        return if (self.reapSession(sess)) .reaped else .reap_pending;
    }

    const PumpResult = enum { open, eof, broken };

    /// Drain readable PTY output into the dispatch pipeline. Bounded per
    /// call: a child that produces output faster than we ingest it (a
    /// `yes`-style firehose) must not pin the loop in this read loop —
    /// after the cap the fd is still readable, so the next poll iteration
    /// resumes right away with the other fds serviced in between.
    fn pumpSession(self: *SessionRegistry, sess: *Session) PumpResult {
        var buffer: [8192]u8 = undefined;
        var chunks: usize = 0;
        while (chunks < 32) : (chunks += 1) {
            const n = std.posix.read(sess.terminal.master_fd, &buffer) catch |err| switch (err) {
                error.WouldBlock => return .open,
                error.InputOutput, error.NotOpenForReading => {
                    sess.pty_state = .eof;
                    return .eof;
                },
                else => {
                    sess.pty_state = .broken;
                    self.applyFailure(sess, err);
                    return .broken;
                },
            };
            if (n == 0) {
                sess.pty_state = .eof;
                return .eof;
            }
            self.dispatchOutput(sess, buffer[0..n]);
        }
        return .open;
    }

    /// Synchronous per-chunk output dispatch: mouse-mode sniffing, log
    /// append, attach broadcast, VT feed (with title-change and bell
    /// logging), and the screen-change stamp that wakes idle/text waiters.
    fn dispatchOutput(self: *SessionRegistry, sess: *Session, bytes: []const u8) void {
        const now = sys.milliTimestamp();
        // Sniff DEC private-mode toggles (CSI ? Pm h/l) out of the output
        // stream so `hty send --click` knows which apps have opted into
        // mouse input and which encoding they prefer. See issue #24.
        session_mod.applyMouseModeTogglesFromOutput(&sess.mouse_state, bytes);
        log_mod.logOutputEvent(sess, now, bytes);
        attach.broadcastRawBytesToAttach(sess, bytes);
        for (bytes) |byte| {
            if (byte == 0x07) log_mod.logBellEvent(sess, now);
        }
        if (sess.terminal.feedOutput(bytes)) |title| {
            defer self.alloc.free(title);
            log_mod.logTitleEvent(sess, now, title);
        }
        if (sess.terminal.config.emit_screen_updates) {
            sess.touchLastScreenChange(now);
        }
    }

    /// Try to reap the session's child without blocking. Returns true
    /// once the child has been reaped (by this call or earlier); false
    /// when it hasn't exited yet (caller retries). On a successful reap
    /// the exit transition runs immediately: status flip, exit log
    /// record, attach broadcast, log close.
    pub fn reapSession(self: *SessionRegistry, sess: *Session) bool {
        const term = sess.terminal;
        if (term.reaped) return true;
        const result = sys.waitpid(term.child_pid, std.posix.W.NOHANG);
        if (result.pid == 0) return false;
        const status = result.status;
        const code: ?i32 = if (std.posix.W.IFEXITED(status))
            @as(i32, @intCast(std.posix.W.EXITSTATUS(status)))
        else if (std.posix.W.IFSIGNALED(status))
            -@as(i32, @intCast(@intFromEnum(std.posix.W.TERMSIG(status))))
        else
            null;
        term.noteChildExit(code);
        self.applyExit(sess, code);
        return true;
    }

    /// Exit transition. Only fires from `.running` — if the session was
    /// already marked `.killed` by handleKill, the child's death from the
    /// SIGKILL must not overwrite that status (and killed sessions never
    /// broadcast an exit frame, preserving the historical behavior).
    fn applyExit(self: *SessionRegistry, sess: *Session, code: ?i32) void {
        _ = self;
        if (sess.getStatus() != .running) return;
        const now = sys.milliTimestamp();
        sess.setExitCode(code);
        sess.setStatus(.exited);
        sess.markTerminal(now);
        log_mod.logExitedEvent(sess, now, code);
        attach.broadcastExitedToAttach(sess, code);
        log_mod.closeLogFile(sess);
        // Name stays reserved until `hty delete` so `hty replay NAME`
        // still finds the session.
    }

    /// Failure transition for an unexpected master-fd read error.
    fn applyFailure(self: *SessionRegistry, sess: *Session, err: anyerror) void {
        _ = self;
        if (sess.getStatus() != .running) return;
        const now = sys.milliTimestamp();
        sess.setStatus(.failed);
        sess.markTerminal(now);
        var msg_buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&msg_buf, "pty read failed: {s}", .{@errorName(err)}) catch "pty read failed";
        log_mod.logFailureEvent(sess, now, msg);
        log_mod.closeLogFile(sess);
    }

    /// True while any session's dead (or killed) child still needs a
    /// waitpid retry. The loop keeps a short retry deadline armed while
    /// this holds.
    pub fn anyReapPending(self: *SessionRegistry) bool {
        var it = self.by_id.valueIterator();
        while (it.next()) |sess_ptr| {
            const sess = sess_ptr.*;
            const term = sess.terminal;
            if (!term.reaped and (term.closed or sess.pty_state == .eof)) return true;
        }
        return false;
    }

    /// Retry every pending reap once. Returns true when at least one
    /// child still isn't reapable (retry again later).
    pub fn retryReaps(self: *SessionRegistry) bool {
        var pending = false;
        var it = self.by_id.valueIterator();
        while (it.next()) |sess_ptr| {
            const sess = sess_ptr.*;
            const term = sess.terminal;
            if (term.reaped or !(term.closed or sess.pty_state == .eof)) continue;
            if (!self.reapSession(sess)) pending = true;
        }
        return pending;
    }

    /// One entry the event loop should poll for a session PTY.
    pub const PtyInterest = struct {
        fd: std.posix.fd_t,
        sess: *Session,
        /// Arm POLLOUT: the session has queued input waiting for the
        /// master fd to become writable.
        write: bool,
    };

    /// Collect the master fds the loop should poll this iteration: every
    /// live session's fd, with write interest exactly when input is
    /// queued. Flushes pending input opportunistically along the way (the
    /// backstop the old drain tick provided).
    pub fn collectPtyInterest(
        self: *SessionRegistry,
        alloc: Allocator,
        out: *std.ArrayListUnmanaged(PtyInterest),
    ) void {
        var it = self.by_id.valueIterator();
        while (it.next()) |sess_ptr| {
            const sess = sess_ptr.*;
            const term = sess.terminal;
            if (term.closed or term.reaped or sess.pty_state != .open) continue;
            sess.flushPendingInput();
            out.append(alloc, .{
                .fd = term.master_fd,
                .sess = sess,
                .write = sess.hasPendingInput(),
            }) catch {};
        }
    }

    /// Auto-remove sweep for `--remove` sessions that have left the
    /// running state. Removal is immediate at the map level (no resolve
    /// can find the session afterwards) and mirrors `handleDelete`'s
    /// filesystem cleanup; the storage free is deferred like any other
    /// removal. Runs on the iteration that observes the exit (the loop's
    /// end-of-iteration phase) and on every in-process pump.
    pub fn autoRemoveSweep(self: *SessionRegistry) void {
        var to_remove: std.ArrayListUnmanaged(*Session) = .empty;
        defer to_remove.deinit(self.alloc);
        var sweep_it = self.by_id.valueIterator();
        while (sweep_it.next()) |sess_ptr| {
            const sess = sess_ptr.*;
            if (!sess.remove_on_exit) continue;
            if (sess.getTerminalAt() == 0) continue;
            to_remove.append(self.alloc, sess) catch break;
        }
        for (to_remove.items) |sess| {
            // Best-effort log cleanup — mirrors `handleDelete`. A failure
            // here (missing file, permissions) is logged-and-ignored: the
            // registry removal below is the primary contract and must
            // still proceed so `hty list` no longer shows the session.
            if (self.log_dir) |log_dir| {
                var path_buf: [std.fs.max_path_bytes]u8 = undefined;
                if (std.fmt.bufPrint(
                    &path_buf,
                    "{s}/{s}.jsonl",
                    .{ log_dir, &sess.id },
                )) |p| {
                    sys.unlink(p) catch {};
                } else |_| {}
                if (sess.name) |name| {
                    if (std.fmt.bufPrint(
                        &path_buf,
                        "{s}/by-name/{s}.jsonl",
                        .{ log_dir, name },
                    )) |p| {
                        sys.unlink(p) catch {};
                    } else |_| {}
                }
            }
            self.remove(sess);
        }
    }

    /// In-process servicing shell: the loop-less equivalent of one event-
    /// loop iteration's PTY phase, used by `processRequestLine`-driven
    /// waits and tests. Services every session's PTY, gives attach
    /// buffers a flush/reap pass, and runs the auto-remove sweep. Does
    /// NOT free doomed sessions — in-process callers may still hold
    /// pointers; `deinit` frees them.
    pub fn pump(self: *SessionRegistry) void {
        var it = self.by_id.valueIterator();
        while (it.next()) |sess_ptr| {
            const sess = sess_ptr.*;
            _ = self.servicePty(sess);
            attach.flushPendingToAttach(sess);
            attach.reapClosedAttachClients(sess);
            sess.flushPendingInput();
        }
        self.autoRemoveSweep();
    }

    /// Number of sessions still running. Exited/failed sessions are held in
    /// the registry as zombies until either `hty kill` reaps them explicitly
    /// or the server auto-shuts-down. Used by the auto-shutdown timer — we
    /// don't want zombies to block an otherwise-idle server from exiting.
    pub fn activeCount(self: *SessionRegistry) usize {
        var count: usize = 0;
        var it = self.by_id.valueIterator();
        while (it.next()) |sess_ptr| {
            if (sess_ptr.*.getStatus() == .running) count += 1;
        }
        return count;
    }
};
