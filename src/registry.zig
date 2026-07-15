//! SessionRegistry — the server's top-level container for all active and
//! zombie sessions. Owns a `by_id` map (UUID -> Session) and a `name_index`
//! for the human-friendly alias lookup, plus a `drainAll` that pumps queued
//! PTY events out to the log file, to attach broadcasters, and into session
//! lifecycle bookkeeping.
//!
//! The registry does not own the log directory path — it's borrowed from
//! the caller (usually `runServer`) and may be null in unit tests, which
//! makes session spawn/drain hooks silently skip log-file operations.

const std = @import("std");
const hty = @import("hty");
const session_mod = @import("session.zig");
const uuid_mod = @import("uuid.zig");
const log_mod = @import("log.zig");
// (hex/attach-client bring-up moved to server_attach.zig with the rest of
// the subscriber machinery.)
const attach = @import("attach.zig");

const Allocator = std.mem.Allocator;
const Session = session_mod.Session;

pub const SessionRegistry = struct {
    alloc: Allocator,
    by_id: std.StringHashMapUnmanaged(*Session) = .{},
    name_index: std.StringHashMapUnmanaged(*Session) = .{},
    /// Absolute path to the session log directory. Borrowed from the caller
    /// (runServer owns the allocation). If null, session spawn/drain hooks
    /// skip log-file operations — used by unit tests.
    log_dir: ?[]const u8 = null,
    /// Protects the two maps above against concurrent access from worker
    /// threads running RPC handlers and the accept thread running drainAll.
    /// Lock order: registry_mutex → (any session-local mutex). Never
    /// acquired while holding a session-local lock.
    mutex: std.Thread.Mutex = .{},
    /// Unix-epoch milliseconds at which this registry was created. Used by
    /// `hty info --json` to report the server's uptime.
    started_at_ms: i64 = 0,

    pub fn init(alloc: Allocator) SessionRegistry {
        return .{
            .alloc = alloc,
            .started_at_ms = std.time.milliTimestamp(),
        };
    }

    pub fn deinit(self: *SessionRegistry) void {
        // No lock needed: callers must drop all references before deinit.
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
        self.mutex.lock();
        defer self.mutex.unlock();

        if (name_owned) |n| {
            if (self.name_index.contains(n)) return error.NameAlreadyExists;
            // `nameInUse` does filesystem I/O (scans the log dir). We hold
            // the registry lock across it because the alternative — check
            // without the lock, then take it — is TOCTOU-prone and session
            // creation is cold-path.
            if (log_mod.nameInUse(self.alloc, self.log_dir, n)) return error.NameAlreadyExists;
        }

        const sess = try self.alloc.create(Session);
        errdefer self.alloc.destroy(sess);

        const now = std.time.milliTimestamp();
        const atomics = Session.initAtomics(now);
        sess.* = .{
            .alloc = self.alloc,
            .id = undefined,
            .name = name_owned,
            .terminal = terminal,
            .program = program_owned,
            .args_joined = args_joined_owned,
            .created_at_ms = now,
            .last_screen_change_at_ms_atomic = atomics.last_screen_change_at_ms_atomic,
            .status_atomic = atomics.status_atomic,
            .exit_code_atomic = atomics.exit_code_atomic,
        };
        uuid_mod.generateUuidV7(&sess.id);

        // Server sessions write PTY input through the per-session pending
        // buffer, which needs a non-blocking master fd (a child that stops
        // reading its tty must surface WouldBlock, never stall the event
        // loop). The library reader thread tolerates the flag by waiting
        // in poll() when a read would block.
        session_mod.setStreamNonBlocking(terminal.master_fd) catch {};

        try self.by_id.put(self.alloc, &sess.id, sess);
        if (name_owned) |n| try self.name_index.put(self.alloc, n, sess);
        return sess;
    }

    /// Exact-name lookup used by the event loop to promote parked
    /// `pending_watch` connections when their target session appears.
    /// Prefix/id resolution is deliberately not applied — promotion keys
    /// on the exact name the watcher asked for, matching the semantics of
    /// the old pending-watcher bucket. On a hit the session's refcount is
    /// incremented; the caller borrows the pointer and MUST pair the call
    /// with `release()`.
    pub fn findByName(self: *SessionRegistry, name: []const u8) ?*Session {
        self.mutex.lock();
        defer self.mutex.unlock();
        const sess = self.name_index.get(name) orelse return null;
        sess.ref_count += 1;
        return sess;
    }

    /// Flush every session's pending-input buffer as far as the master fd
    /// allows, and collect the master fds of sessions that still have
    /// queued input — the event loop arms POLLOUT on those so the next
    /// writability wakes it for another flush.
    pub fn flushPendingInputAll(
        self: *SessionRegistry,
        alloc: Allocator,
        still_pending: *std.ArrayListUnmanaged(std.posix.fd_t),
    ) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        var it = self.by_id.valueIterator();
        while (it.next()) |sess_ptr| {
            const sess = sess_ptr.*;
            sess.flushPendingInput();
            if (sess.hasPendingInput()) {
                still_pending.append(alloc, sess.terminal.master_fd) catch {};
            }
        }
    }

    /// Resolve a session reference (full UUID, unique prefix, or name).
    /// Returns null if no match. Returns error.AmbiguousPrefix if prefix matches 2+.
    /// On a successful (non-null) resolve the session's refcount is
    /// incremented — the caller borrows the pointer and MUST pair the call
    /// with `release()` on every exit path.
    pub fn resolve(self: *SessionRegistry, reference: []const u8) !?*Session {
        self.mutex.lock();
        defer self.mutex.unlock();
        const sess = try self.resolveLocked(reference);
        if (sess) |s| s.ref_count += 1;
        return sess;
    }

    /// Caller must hold `self.mutex`. Used internally by `resolve` and by
    /// operations like `resolveOrSole` that need to do multiple map reads
    /// under a single lock.
    fn resolveLocked(self: *SessionRegistry, reference: []const u8) !?*Session {
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

    /// Resolve or pick the sole session when reference is null.
    /// On success the session's refcount is incremented while `self.mutex`
    /// is still held — the caller borrows the pointer and MUST pair the
    /// call with `release()` on every exit path (typically via `defer`).
    /// The borrow keeps the Session storage alive across a concurrent
    /// `hty delete` / `--remove` sweep; those unpublish the session
    /// immediately, but the memory is only freed once the last borrow is
    /// released.
    pub fn resolveOrSole(self: *SessionRegistry, reference: ?[]const u8) !*Session {
        self.mutex.lock();
        defer self.mutex.unlock();
        const sess = blk: {
            if (reference) |r| {
                break :blk (try self.resolveLocked(r)) orelse return error.SessionNotFound;
            }
            if (self.by_id.count() == 0) return error.SessionNotFound;
            if (self.by_id.count() > 1) return error.AmbiguousPrefix;
            var it = self.by_id.valueIterator();
            break :blk it.next().?.*;
        };
        sess.ref_count += 1;
        return sess;
    }

    /// Drop a borrow acquired by `resolve` / `resolveOrSole`. If the
    /// session was doomed (unpublished by `removeLocked`) and this was the
    /// last borrow, the session is freed here. The free runs outside
    /// `self.mutex`: nothing else can reach the session anymore (it's out
    /// of both maps and the count is zero), and `Session.deinit` joins
    /// attach reader threads, which we don't want serialized under the
    /// registry lock.
    pub fn release(self: *SessionRegistry, sess: *Session) void {
        self.mutex.lock();
        std.debug.assert(sess.ref_count > 0);
        sess.ref_count -= 1;
        const free_now = sess.ref_count == 0 and sess.isDoomed();
        self.mutex.unlock();
        if (free_now) {
            sess.deinit();
            self.alloc.destroy(sess);
        }
    }

    pub fn remove(self: *SessionRegistry, sess: *Session) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.removeLocked(sess);
    }

    /// Caller must hold `self.mutex`. Unpublishes the session from both
    /// maps immediately — no new resolve can find it — and marks it
    /// doomed. If no handler currently borrows the session it is torn
    /// down and freed right here; otherwise the last `release()` frees
    /// it. Used by the locked auto-remove sweep in `drainAll` and by the
    /// public `remove` (which takes the lock first).
    pub fn removeLocked(self: *SessionRegistry, sess: *Session) void {
        _ = self.by_id.remove(&sess.id);
        if (sess.name) |n| _ = self.name_index.remove(n);
        sess.doomed_atomic.store(true, .release);
        if (sess.ref_count == 0) {
            sess.deinit();
            self.alloc.destroy(sess);
        }
    }

    /// Drain any queued events, updating last_screen_change_at, status, the
    /// session log file, and any attached `hty attach` clients. Does **not**
    /// remove sessions from the registry — ended sessions linger as records
    /// that `hty list` / `hty logs` / `hty replay` can still find, until
    /// explicitly removed with `hty delete`.
    ///
    /// Holds `registry.mutex` for the whole iteration so workers can't
    /// remove a session mid-drain. The per-session work inside the loop
    /// acquires session-local locks (terminal, log, attach) — these are
    /// always taken after `registry.mutex`, matching the declared lock order.
    pub fn drainAll(self: *SessionRegistry) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        var it = self.by_id.valueIterator();
        while (it.next()) |sess_ptr| {
            const sess = sess_ptr.*;
            while (sess.terminal.pollEvent()) |event| {
                const now = std.time.milliTimestamp();
                switch (event) {
                    .screen_update => sess.touchLastScreenChange(now),
                    .exited => |code| {
                        // Only transition from .running — if the session
                        // was already marked .killed by handleKill, don't
                        // overwrite that with .exited when the child dies
                        // from the SIGKILL.
                        if (sess.getStatus() == .running) {
                            // Write exit_code before status so the release
                            // store on status publishes both atomically.
                            sess.setExitCode(code orelse Session.no_exit_code);
                            sess.setStatus(.exited);
                            sess.markTerminal(now);
                            log_mod.logDrainedEvent(sess, now, event);
                            attach.broadcastExitedToAttach(sess, code);
                            log_mod.closeLogFile(sess);
                            // Name stays reserved until `hty delete` so
                            // `hty replay NAME` still finds the session.
                        }
                    },
                    .failure => {
                        if (sess.getStatus() == .running) {
                            sess.setStatus(.failed);
                            sess.markTerminal(now);
                            log_mod.logDrainedEvent(sess, now, event);
                            log_mod.closeLogFile(sess);
                        }
                    },
                    .raw_bytes => |bytes| {
                        // Sniff DEC private-mode toggles (CSI ? Pm h/l)
                        // out of the output stream so `hty send --click`
                        // knows which apps have opted into mouse input
                        // and which encoding they prefer. See issue #24.
                        session_mod.applyMouseModeTogglesFromOutput(&sess.mouse_state, bytes);
                        log_mod.logDrainedEvent(sess, now, event);
                        attach.broadcastRawBytesToAttach(sess, bytes);
                    },
                    .title_changed, .bell => log_mod.logDrainedEvent(sess, now, event),
                    else => {},
                }
                var owned = event;
                owned.deinit(sess.alloc);
            }
            // Push out any bytes buffered for momentarily-slow attach
            // clients (non-blocking; a client over its buffer bound is
            // marked closed and picked up by the reap below).
            attach.flushPendingToAttach(sess);
            // Reap any self-owned attach clients that have closed (the
            // event loop reaps conn-owned ones itself).
            attach.reapClosedAttachClients(sess);
            // Backstop flush for queued PTY input; the event loop also
            // flushes on master-fd writability.
            sess.flushPendingInput();
        }

        // Auto-remove sweep for `--remove` sessions whose child has
        // exited. Removal is immediate: `removeLocked` unpublishes the
        // session from the maps and any in-flight wait/snapshot handler
        // is protected by the borrow it acquired at resolve time (the
        // last release frees the storage). The sweep runs under
        // `self.mutex`, same lock the maps + session teardown need, so
        // racing `hty kill` / `hty delete` can't double-free: whichever
        // path wins the mutex observes the other's state change.
        var to_remove: std.ArrayListUnmanaged(*Session) = .{};
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
                    std.fs.deleteFileAbsolute(p) catch {};
                } else |_| {}
                if (sess.name) |name| {
                    if (std.fmt.bufPrint(
                        &path_buf,
                        "{s}/by-name/{s}.jsonl",
                        .{ log_dir, name },
                    )) |p| {
                        std.fs.deleteFileAbsolute(p) catch {};
                    } else |_| {}
                }
            }
            self.removeLocked(sess);
        }
    }

    /// Number of sessions still running. Exited/failed sessions are held in
    /// the registry as zombies until either `hty kill` reaps them explicitly
    /// or the server auto-shuts-down. Used by the auto-shutdown timer — we
    /// don't want zombies to block an otherwise-idle server from exiting.
    pub fn activeCount(self: *SessionRegistry) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        var count: usize = 0;
        var it = self.by_id.valueIterator();
        while (it.next()) |sess_ptr| {
            if (sess_ptr.*.getStatus() == .running) count += 1;
        }
        return count;
    }
};
