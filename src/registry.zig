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
const hex_mod = @import("hex.zig");

const Allocator = std.mem.Allocator;
const Session = session_mod.Session;
const AttachClient = session_mod.AttachClient;

/// A `hty watch` (or `hty attach`) subscriber that arrived before its
/// target session existed. Parked in `SessionRegistry.pending_watchers_by_name`
/// and promoted to a full `AttachClient` the moment a session with that name
/// is created. See LatentEvals/hty#29.
///
/// Shape mirrors `AttachClient` minus the session back-pointer (it has none
/// yet) and the per-session log plumbing (nothing to log against until
/// promotion). The reader thread's only job while parked is to detect EOF
/// or client disconnect so the registry can reap the entry.
///
/// Wake-up uses a self-pipe rather than `shutdown(.recv)` because the
/// same socket fd is handed off to the promoted `AttachClient`, and
/// half-shutting the read side breaks *its* subsequent reads (EOF →
/// `closed = true` on first drain tick, losing live output). The pipe
/// lets us interrupt `poll()` without touching the real socket state.
pub const PendingWatcher = struct {
    alloc: Allocator,
    stream: std.net.Stream,
    /// Owned copy of the requested session name. Used to look up the bucket
    /// in `pending_watchers_by_name` during both promotion and reap.
    name: []u8,
    closed: std.atomic.Value(bool) = .init(false),
    reader_thread: ?std.Thread = null,
    /// Self-pipe used by `shutdown()` to wake the reader thread's
    /// `poll()` without half-closing the client socket.
    wake_r: std.posix.fd_t,
    wake_w: std.posix.fd_t,
    /// True while this struct owns `stream`. `promoteOnePendingWatcher`
    /// transfers the stream to a freshly-constructed `AttachClient` and
    /// flips this to false so `deinit()` skips `stream.close()`.
    owns_stream: bool = true,

    pub fn isClosed(self: *const PendingWatcher) bool {
        return self.closed.load(.acquire);
    }

    /// Wake the reader thread so it exits its poll loop. Does NOT touch
    /// the socket's read/write halves — after promotion the socket is
    /// reused by the AttachClient, and half-closing either side here
    /// would break the new owner's first read/write. Idempotent via the
    /// `closed` atomic.
    pub fn shutdown(self: *PendingWatcher) void {
        if (self.closed.swap(true, .acq_rel)) return;
        // One byte is enough to wake poll(); write failures mean the
        // pipe is already torn down, which is fine.
        var byte: [1]u8 = .{0};
        _ = std.posix.write(self.wake_w, &byte) catch {};
    }

    /// Join the reader thread, close owned fds, free owned storage, and
    /// destroy the struct. Must be called *after* the pending watcher has
    /// been removed from the registry's bucket. Skips `stream.close()`
    /// when `owns_stream` is false (stream was transferred to an
    /// AttachClient at promotion time).
    pub fn deinit(self: *PendingWatcher) void {
        self.shutdown();
        if (self.reader_thread) |t| t.join();
        std.posix.close(self.wake_r);
        std.posix.close(self.wake_w);
        if (self.owns_stream) self.stream.close();
        self.alloc.free(self.name);
        self.alloc.destroy(self);
    }
};

/// Reader thread for a parked `PendingWatcher`. Polls the client socket
/// and the wake pipe. Exits on: socket readable with 0 bytes (EOF /
/// client disconnect), socket readable with an error, or wake pipe
/// readable (promotion or registry tear-down). Any exit flips `closed`.
/// Crucially, this loop does NOT close or shutdown the socket — the
/// AttachClient that takes ownership at promotion time needs it intact.
fn pendingWatcherReaderLoop(pw: *PendingWatcher) void {
    defer pw.closed.store(true, .release);

    var pfds = [_]std.posix.pollfd{
        .{ .fd = pw.stream.handle, .events = std.posix.POLL.IN, .revents = 0 },
        .{ .fd = pw.wake_r, .events = std.posix.POLL.IN, .revents = 0 },
    };
    var buf: [256]u8 = undefined;
    while (!pw.isClosed()) {
        const rc = std.posix.poll(&pfds, -1) catch break;
        if (rc == 0) continue;

        // Wake pipe triggered — promoter or reaper signalled us.
        if ((pfds[1].revents & std.posix.POLL.IN) != 0) break;

        if ((pfds[0].revents & std.posix.POLL.IN) != 0) {
            const n = pw.stream.read(&buf) catch break;
            if (n == 0) break; // EOF from client.
            // Ignore any bytes — a parked watcher isn't supposed to be
            // sending input. Loop and keep polling.
        }
        // Socket error conditions (HUP/ERR/NVAL) are terminal.
        if ((pfds[0].revents & (std.posix.POLL.HUP | std.posix.POLL.ERR | std.posix.POLL.NVAL)) != 0) break;
    }
}

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
    /// Pre-creation watch/attach subscribers, bucketed by the session name
    /// they're waiting for. Protected by `self.mutex`. On `create()`, the
    /// bucket for the new session's name is drained and each pending
    /// watcher is promoted to a full `AttachClient` on the session — all
    /// while still holding `self.mutex`, so no watch op can race and see
    /// "neither pending nor live". See LatentEvals/hty#29.
    pending_watchers_by_name: std.StringHashMapUnmanaged(std.ArrayListUnmanaged(*PendingWatcher)) = .{},

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

        // Tear down any still-parked pending watchers. Shutdown the
        // socket first so their reader threads can unblock, then join &
        // free. The bucket key `name` aliases each watcher's `.name`, so
        // we free the value slice before dropping the map entry.
        var pit = self.pending_watchers_by_name.iterator();
        while (pit.next()) |entry| {
            var list = entry.value_ptr.*;
            for (list.items) |pw| pw.deinit();
            list.deinit(self.alloc);
        }
        self.pending_watchers_by_name.deinit(self.alloc);
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
            // `nameInUse` is a single O(1) access on the authoritative
            // by-name symlink (a one-time startup reconciliation covers
            // logs from older hty versions). We hold the registry lock
            // across it because the alternative — check without the lock,
            // then take it — is TOCTOU-prone and session creation is
            // cold-path.
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

        // Promote any pre-creation watchers waiting on this name. We do
        // this while still holding `self.mutex` so a racing watch op can't
        // observe a window where the session is published but the pending
        // bucket still exists. See LatentEvals/hty#29.
        if (name_owned) |n| self.promotePendingWatchersLocked(sess, n);
        return sess;
    }

    /// Caller must hold `self.mutex`. Drains the pending-watchers bucket
    /// for `name`, promotes each parked socket to a read-only
    /// `AttachClient` on `sess`, and removes the bucket. Best-effort: if
    /// any step fails we close the pending watcher and skip it rather
    /// than unwind session creation.
    fn promotePendingWatchersLocked(self: *SessionRegistry, sess: *Session, name: []const u8) void {
        const kv = self.pending_watchers_by_name.fetchRemove(name) orelse return;
        var list = kv.value;
        defer list.deinit(self.alloc);

        for (list.items) |pw| {
            // If the pending watcher's socket already died (client
            // Ctrl-C'd during the race window), drop it.
            if (pw.isClosed()) {
                pw.deinit();
                continue;
            }
            self.promoteOnePendingWatcher(sess, pw);
        }
    }

    /// Promote a single PendingWatcher to a full read-only AttachClient
    /// on `sess`. Called from `promotePendingWatchersLocked`; must be
    /// invoked while holding `self.mutex` so the session pointer can't
    /// be reaped underneath us. On any failure, tears down the pending
    /// watcher (closes socket, frees storage) via the regular deinit
    /// path — `owns_stream` stays true until we've successfully handed
    /// the stream off to an `AttachClient`.
    fn promoteOnePendingWatcher(self: *SessionRegistry, sess: *Session, pw: *PendingWatcher) void {
        // Wake the reader thread via the self-pipe and join it so we
        // can safely reuse the socket fd. shutdown() only writes a
        // byte to the wake pipe — the real socket is untouched, so the
        // new AttachClient's first read() and write() both succeed.
        pw.shutdown();
        if (pw.reader_thread) |t| t.join();
        pw.reader_thread = null;

        // Reuse the same AttachClient bring-up dance that
        // server_attach.handleAttachConnection uses on the live-session
        // path. Keep this in sync with that function.
        var uuid_buf: [36]u8 = undefined;
        uuid_mod.generateUuidV7(&uuid_buf);
        const client_id = std.fmt.allocPrint(self.alloc, "attach-{s}", .{uuid_buf[0..]}) catch {
            pw.deinit();
            return;
        };
        errdefer self.alloc.free(client_id);

        const client = self.alloc.create(AttachClient) catch {
            self.alloc.free(client_id);
            pw.deinit();
            return;
        };
        client.* = .{
            .alloc = self.alloc,
            .session = sess,
            .stream = pw.stream,
            .client_id = client_id,
            .read_only = true,
        };

        sess.attach_mutex.lock();
        sess.attach_clients.append(self.alloc, client) catch {
            sess.attach_mutex.unlock();
            self.alloc.free(client.client_id);
            self.alloc.destroy(client);
            // Promotion failed before stream ownership transferred — let
            // the normal deinit path close the socket.
            pw.deinit();
            return;
        };
        sess.attach_mutex.unlock();

        // Stream ownership has now transferred to `client`. Mark the
        // pending watcher so its deinit won't double-close.
        pw.owns_stream = false;

        // Match the live-attach setup: the socket must be non-blocking
        // before it can sit on the broadcast list, so a promoted watcher
        // that stops reading can't stall the drain step either. On
        // failure drop the client instead of risking a blocking write.
        session_mod.setStreamNonBlocking(client.stream.handle) catch {
            client.shutdown();
        };

        // Log the connect event and send the started+snapshot frames.
        // Use a local arena so failures here don't leak.
        var arena_state = std.heap.ArenaAllocator.init(self.alloc);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        log_mod.logAttachConnectEvent(arena, sess, client.client_id);

        // `started` gates the attach-client's raw-mode flip on the client
        // side; watch clients use it to clear their "Waiting..." paint.
        _ = client.tryWriteFrame("{\"kind\":\"started\"}\n");

        // Send the initial snapshot so the watcher sees the current
        // screen immediately after promotion, matching what a
        // first-time-live attach/watch receives.
        if (sess.terminal.snapshot()) |snap| {
            var owned = snap;
            defer owned.deinit(sess.alloc);
            const hex_str = hex_mod.encodeHex(arena, owned.screen_ansi) catch null;
            if (hex_str) |h| {
                const frame = std.fmt.allocPrint(
                    arena,
                    "{{\"kind\":\"output\",\"bytes_hex\":\"{s}\"}}\n",
                    .{h},
                ) catch null;
                if (frame) |f| _ = client.tryWriteFrame(f);
            }
        } else |_| {}

        // Spawn the full attach reader loop so input/resize frames the
        // client sends get dispatched (and dropped for read-only clients)
        // and detach/EOF properly reap the client.
        const server_attach = @import("server_attach.zig");
        if (std.Thread.spawn(.{}, server_attach.attachReaderLoop, .{client})) |t| {
            client.reader_thread = t;
        } else |_| {
            // On spawn failure, mark the client closed and let the next
            // reap sweep pick it up. The session still owns the client;
            // we leave it on the list and emit a disconnect.
            client.closed.store(true, .release);
            if (!client.disconnect_logged.swap(true, .acq_rel)) {
                log_mod.logAttachDisconnectEvent(arena, sess, client.client_id);
            }
        }

        // Free the pending watcher (its reader thread is already joined
        // and owns_stream=false ensures deinit doesn't double-close the
        // socket the AttachClient now owns).
        pw.deinit();
    }

    /// Park a pre-creation watcher on the `name` bucket. Takes ownership
    /// of `stream` (the caller's `handleAttachConnection` surrenders
    /// socket ownership in the same way a live attach would). Spawns the
    /// minimal reader thread that detects client disconnect. Caller must
    /// NOT hold `self.mutex`.
    pub fn parkPendingWatcher(
        self: *SessionRegistry,
        name: []const u8,
        stream: std.net.Stream,
    ) !*PendingWatcher {
        const name_owned = try self.alloc.dupe(u8, name);
        errdefer self.alloc.free(name_owned);

        // Self-pipe for waking the reader thread without disturbing the
        // real client socket (which may be reused by a promoted
        // AttachClient).
        const pipe_fds = try std.posix.pipe();
        errdefer {
            std.posix.close(pipe_fds[0]);
            std.posix.close(pipe_fds[1]);
        }

        const pw = try self.alloc.create(PendingWatcher);
        errdefer self.alloc.destroy(pw);
        pw.* = .{
            .alloc = self.alloc,
            .stream = stream,
            .name = name_owned,
            .wake_r = pipe_fds[0],
            .wake_w = pipe_fds[1],
        };

        self.mutex.lock();
        const gop = self.pending_watchers_by_name.getOrPut(self.alloc, pw.name) catch |err| {
            self.mutex.unlock();
            return err;
        };
        if (!gop.found_existing) {
            gop.value_ptr.* = .{};
        }
        gop.value_ptr.append(self.alloc, pw) catch |err| {
            // Remove the entry we just added if it's now empty (we were
            // the first and only putter).
            if (!gop.found_existing) {
                _ = self.pending_watchers_by_name.remove(pw.name);
            }
            self.mutex.unlock();
            return err;
        };
        self.mutex.unlock();

        pw.reader_thread = std.Thread.spawn(.{}, pendingWatcherReaderLoop, .{pw}) catch |err| {
            // Roll back the bucket insert before propagating.
            self.mutex.lock();
            if (self.pending_watchers_by_name.getPtr(pw.name)) |list_ptr| {
                var i: usize = 0;
                while (i < list_ptr.items.len) : (i += 1) {
                    if (list_ptr.items[i] == pw) {
                        _ = list_ptr.swapRemove(i);
                        break;
                    }
                }
                if (list_ptr.items.len == 0) {
                    list_ptr.deinit(self.alloc);
                    _ = self.pending_watchers_by_name.remove(pw.name);
                }
            }
            self.mutex.unlock();
            return err;
        };

        return pw;
    }

    /// Reap any pending watchers whose socket has closed (client Ctrl-C
    /// or EOF). Called from the drain step. Takes `self.mutex` briefly
    /// for the scan+remove, then joins + frees outside the lock.
    pub fn reapClosedPendingWatchers(self: *SessionRegistry) void {
        self.mutex.lock();
        var reaped = self.reapClosedPendingWatchersLocked();
        self.mutex.unlock();
        defer reaped.deinit(self.alloc);

        // Join and free outside the lock — deinit joins the reader
        // thread, which could otherwise deadlock if the thread is
        // mid-shutdown and we're holding the map mutex it might want.
        for (reaped.items) |pw| pw.deinit();
    }

    /// Core of the pending-watcher reap: unlink every closed watcher from
    /// `pending_watchers_by_name` (dropping emptied buckets) and return
    /// the unlinked watchers. Caller must hold `self.mutex`, owns the
    /// returned list, and must call `deinit()` on each watcher — ideally
    /// after releasing the lock, since that joins its reader thread.
    /// Shared by `reapClosedPendingWatchers` and `drainAll`.
    fn reapClosedPendingWatchersLocked(
        self: *SessionRegistry,
    ) std.ArrayListUnmanaged(*PendingWatcher) {
        var reaped: std.ArrayListUnmanaged(*PendingWatcher) = .{};

        var empty_keys: std.ArrayListUnmanaged([]const u8) = .{};
        defer empty_keys.deinit(self.alloc);

        var it = self.pending_watchers_by_name.iterator();
        while (it.next()) |entry| {
            var list_ptr = entry.value_ptr;
            var i: usize = 0;
            while (i < list_ptr.items.len) {
                const pw = list_ptr.items[i];
                if (pw.isClosed()) {
                    _ = list_ptr.swapRemove(i);
                    reaped.append(self.alloc, pw) catch {};
                    continue;
                }
                i += 1;
            }
            if (list_ptr.items.len == 0) {
                empty_keys.append(self.alloc, entry.key_ptr.*) catch {};
            }
        }
        for (empty_keys.items) |key| {
            if (self.pending_watchers_by_name.fetchRemove(key)) |kv| {
                var v = kv.value;
                v.deinit(self.alloc);
            }
        }
        return reaped;
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
            // Reap any attach clients whose reader thread has exited.
            attach.reapClosedAttachClients(sess);
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

        // Reap pending watchers (pre-creation subscribers) whose socket
        // has closed. We already hold `self.mutex` (released by the
        // outer `defer` on return), so call the shared locked core
        // directly — `reapClosedPendingWatchers` would self-deadlock.
        var reaped = self.reapClosedPendingWatchersLocked();
        defer reaped.deinit(self.alloc);
        // Deinit (which joins reader threads) happens under the mutex
        // here. The reader thread doesn't touch the registry, so no
        // deadlock risk; the only cost is that join is serialized with
        // other drain work, which is fine at the rate this runs (25ms
        // tick, handful of watchers).
        for (reaped.items) |pw| pw.deinit();
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
