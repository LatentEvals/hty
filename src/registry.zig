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

        try self.by_id.put(self.alloc, &sess.id, sess);
        if (name_owned) |n| try self.name_index.put(self.alloc, n, sess);
        return sess;
    }

    /// Resolve a session reference (full UUID, unique prefix, or name).
    /// Returns null if no match. Returns error.AmbiguousPrefix if prefix matches 2+.
    pub fn resolve(self: *SessionRegistry, reference: []const u8) !?*Session {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.resolveLocked(reference);
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
    pub fn resolveOrSole(self: *SessionRegistry, reference: ?[]const u8) !*Session {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (reference) |r| {
            return (try self.resolveLocked(r)) orelse error.SessionNotFound;
        }
        if (self.by_id.count() == 0) return error.SessionNotFound;
        if (self.by_id.count() > 1) return error.AmbiguousPrefix;
        var it = self.by_id.valueIterator();
        return it.next().?.*;
    }

    pub fn remove(self: *SessionRegistry, sess: *Session) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        _ = self.by_id.remove(&sess.id);
        if (sess.name) |n| _ = self.name_index.remove(n);
        sess.deinit();
        self.alloc.destroy(sess);
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
                            log_mod.logDrainedEvent(sess, now, event);
                            log_mod.closeLogFile(sess);
                        }
                    },
                    .raw_bytes => |bytes| {
                        log_mod.logDrainedEvent(sess, now, event);
                        attach.broadcastRawBytesToAttach(sess, bytes);
                    },
                    .title_changed, .bell => log_mod.logDrainedEvent(sess, now, event),
                    else => {},
                }
                var owned = event;
                owned.deinit(sess.alloc);
            }
            // Reap any attach clients whose reader thread has exited.
            attach.reapClosedAttachClients(sess);
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
