const std = @import("std");
const hty = @import("hty");

const Allocator = std.mem.Allocator;

const c = @cImport({
    @cInclude("poll.h");
    @cInclude("unistd.h");
    @cInclude("fcntl.h");
    @cInclude("sys/stat.h");
    @cInclude("sys/ioctl.h");
    @cInclude("time.h");
});

/// Suppress std.log output below error level across the whole binary.
/// The Ghostty VT parser emits warn-level messages when it hits escape
/// sequences it doesn't implement (e.g. the non-standard "CSI m with
/// intermediate: 63" vim occasionally sends). Those go to stderr, and
/// for the replay / watch / attach clients stderr is the user's
/// terminal — the warnings land right on top of the rendered frame.
/// The server redirects stdio to /dev/null so raising the level there
/// costs nothing; raising it for the clients fixes the visual glitch.
pub const std_options: std.Options = .{
    .log_level = .err,
};

// ============================================================================
// Exit codes (stable contract across versions once we ship 0.1)
// ============================================================================

const ExitCode = struct {
    const ok: u8 = 0;
    const generic: u8 = 1;
    const not_found: u8 = 2;
    const wait_timeout: u8 = 3;
    const ambiguous_prefix: u8 = 4;
    const name_exists: u8 = 5;
};

// ============================================================================
// XDG paths: socket in $XDG_RUNTIME_DIR/hty, logs in $XDG_STATE_HOME/hty/logs
// ============================================================================

fn resolveSocketPath(alloc: Allocator) ![]u8 {
    // Explicit override wins — used for SSH-tunneled sockets, tests, or any
    // other time you want the client to talk to a non-default socket.
    // Does NOT ensureOwnedDir, because the override path may live in a
    // directory the caller doesn't own (e.g. a tunnel endpoint).
    if (std.posix.getenv("HTY_SOCKET")) |override| {
        if (override.len > 0) return alloc.dupe(u8, override);
    }

    const dir = try resolveRuntimeDir(alloc);
    defer alloc.free(dir);
    try ensureOwnedDir(alloc, dir);
    return std.fmt.allocPrint(alloc, "{s}/sock", .{dir});
}

fn resolveRuntimeDir(alloc: Allocator) ![]u8 {
    if (std.posix.getenv("XDG_RUNTIME_DIR")) |runtime| {
        if (runtime.len > 0) {
            return std.fmt.allocPrint(alloc, "{s}/hty", .{runtime});
        }
    }
    const uid = c.getuid();
    return std.fmt.allocPrint(alloc, "/tmp/hty-{d}", .{uid});
}

fn resolveLogDir(alloc: Allocator) ![]u8 {
    if (std.posix.getenv("XDG_STATE_HOME")) |state| {
        if (state.len > 0) {
            const dir = try std.fmt.allocPrint(alloc, "{s}/hty/logs", .{state});
            errdefer alloc.free(dir);
            try ensureOwnedDir(alloc, dir);
            return dir;
        }
    }
    const home = std.posix.getenv("HOME") orelse return error.HomeNotSet;
    const dir = try std.fmt.allocPrint(alloc, "{s}/.local/state/hty/logs", .{home});
    errdefer alloc.free(dir);
    try ensureOwnedDir(alloc, dir);
    return dir;
}

/// Ensure `path` exists as a directory owned by the current user with mode 0700.
/// Recursively creates missing parents. Bails out if the resulting directory is
/// owned by a different uid (symlink-attack defense).
fn ensureOwnedDir(alloc: Allocator, path: []const u8) !void {
    std.fs.cwd().makePath(path) catch |err| return err;

    const path_z = try alloc.dupeZ(u8, path);
    defer alloc.free(path_z);

    var st: c.struct_stat = undefined;
    if (c.stat(path_z.ptr, &st) != 0) return error.CannotStatDir;
    const uid = c.getuid();
    if (st.st_uid != uid) return error.DirectoryStolen;
    _ = c.chmod(path_z.ptr, 0o700);
}

// ============================================================================
// UUID v7 generation + prefix resolution
// ============================================================================

/// Generate a UUIDv7 into `out` as a 36-char hex-with-dashes string.
/// Layout: 48 bits unix-ms timestamp | 4 bits version=7 | 12 bits rand |
///         2 bits variant=10 | 62 bits rand.
fn generateUuidV7(out: *[36]u8) void {
    var bytes: [16]u8 = undefined;
    std.crypto.random.bytes(&bytes);

    const ms: u64 = @intCast(std.time.milliTimestamp());
    bytes[0] = @intCast((ms >> 40) & 0xff);
    bytes[1] = @intCast((ms >> 32) & 0xff);
    bytes[2] = @intCast((ms >> 24) & 0xff);
    bytes[3] = @intCast((ms >> 16) & 0xff);
    bytes[4] = @intCast((ms >> 8) & 0xff);
    bytes[5] = @intCast(ms & 0xff);

    // Version 7 in the high nibble of byte 6
    bytes[6] = (bytes[6] & 0x0f) | 0x70;
    // Variant 10 in the top 2 bits of byte 8
    bytes[8] = (bytes[8] & 0x3f) | 0x80;

    const hex = "0123456789abcdef";
    var idx: usize = 0;
    for (bytes, 0..) |b, i| {
        if (i == 4 or i == 6 or i == 8 or i == 10) {
            out[idx] = '-';
            idx += 1;
        }
        out[idx] = hex[b >> 4];
        out[idx + 1] = hex[b & 0x0f];
        idx += 2;
    }
}

// ============================================================================
// Session + SessionRegistry
// ============================================================================

const SessionStatus = enum { running, exited, failed, killed };

const Session = struct {
    alloc: Allocator,
    id: [36]u8,
    name: ?[]u8,
    terminal: *hty.InteractiveTerminal,
    program: []u8,
    args_joined: []u8,
    created_at_ms: i64,
    last_screen_change_at_ms: i64,
    status: SessionStatus,
    exit_code: ?i32 = null,
    log_file: ?std.fs.File = null,
    /// Active `hty attach` clients subscribed to this session's output.
    attach_clients: std.ArrayListUnmanaged(*AttachClient) = .{},
    /// Protects attach_clients against concurrent broadcast and remove.
    attach_mutex: std.Thread.Mutex = .{},

    fn deinit(self: *Session) void {
        // Tear down any still-attached clients before freeing the session.
        // Takes the mutex just to be safe against a rogue late broadcast.
        self.attach_mutex.lock();
        for (self.attach_clients.items) |client| {
            client.shutdown();
        }
        const clients_snapshot = self.attach_clients.toOwnedSlice(self.alloc) catch &.{};
        self.attach_mutex.unlock();
        for (clients_snapshot) |client| client.deinit();
        if (clients_snapshot.len > 0) self.alloc.free(clients_snapshot);

        if (self.log_file) |*f| {
            f.close();
            self.log_file = null;
        }
        self.terminal.deinit();
        self.alloc.free(self.program);
        self.alloc.free(self.args_joined);
        if (self.name) |name| self.alloc.free(name);
    }
};

/// One live `hty attach` connection. The main accept loop's drain step
/// broadcasts raw PTY bytes to each attach_client on the owning session;
/// a per-client reader thread reads input frames from the socket and
/// forwards them back into the session's terminal.
const AttachClient = struct {
    alloc: Allocator,
    session: *Session,
    stream: std.net.Stream,
    write_mutex: std.Thread.Mutex = .{},
    closed: std.atomic.Value(bool) = .init(false),
    reader_thread: ?std.Thread = null,

    fn isClosed(self: *const AttachClient) bool {
        return self.closed.load(.acquire);
    }

    fn shutdown(self: *AttachClient) void {
        if (self.closed.swap(true, .acq_rel)) return;
        // Shutting down the socket unblocks any in-flight read() on the
        // reader thread so it can exit cleanly.
        std.posix.shutdown(self.stream.handle, .both) catch {};
    }

    /// Best-effort write of a pre-framed JSONL line (with trailing '\n').
    /// Marks the client closed on any write error so the broadcaster
    /// will drop it on the next pass.
    fn tryWriteFrame(self: *AttachClient, frame: []const u8) bool {
        if (self.isClosed()) return false;
        self.write_mutex.lock();
        defer self.write_mutex.unlock();
        self.stream.writeAll(frame) catch {
            _ = self.closed.store(true, .release);
            return false;
        };
        return true;
    }

    fn deinit(self: *AttachClient) void {
        self.shutdown();
        if (self.reader_thread) |t| t.join();
        self.stream.close();
        self.alloc.destroy(self);
    }
};

const SessionRegistry = struct {
    alloc: Allocator,
    by_id: std.StringHashMapUnmanaged(*Session) = .{},
    name_index: std.StringHashMapUnmanaged(*Session) = .{},
    /// Absolute path to the session log directory. Borrowed from the caller
    /// (runServer owns the allocation). If null, session spawn/drain hooks
    /// skip log-file operations — used by unit tests.
    log_dir: ?[]const u8 = null,

    fn init(alloc: Allocator) SessionRegistry {
        return .{ .alloc = alloc };
    }

    fn deinit(self: *SessionRegistry) void {
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
    fn create(
        self: *SessionRegistry,
        terminal: *hty.InteractiveTerminal,
        program_owned: []u8,
        args_joined_owned: []u8,
        name_owned: ?[]u8,
    ) !*Session {
        if (name_owned) |n| {
            if (self.name_index.contains(n)) return error.NameAlreadyExists;
        }

        const sess = try self.alloc.create(Session);
        errdefer self.alloc.destroy(sess);

        const now = std.time.milliTimestamp();
        sess.* = .{
            .alloc = self.alloc,
            .id = undefined,
            .name = name_owned,
            .terminal = terminal,
            .program = program_owned,
            .args_joined = args_joined_owned,
            .created_at_ms = now,
            .last_screen_change_at_ms = now,
            .status = .running,
        };
        generateUuidV7(&sess.id);

        try self.by_id.put(self.alloc, &sess.id, sess);
        if (name_owned) |n| try self.name_index.put(self.alloc, n, sess);
        return sess;
    }

    /// Resolve a session reference (full UUID, unique prefix, or name).
    /// Returns null if no match. Returns error.AmbiguousPrefix if prefix matches 2+.
    fn resolve(self: *SessionRegistry, reference: []const u8) !?*Session {
        // Exact ID match
        if (self.by_id.get(reference)) |sess| return sess;
        // Name match
        if (self.name_index.get(reference)) |sess| return sess;
        // Prefix match on IDs
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
    fn resolveOrSole(self: *SessionRegistry, reference: ?[]const u8) !*Session {
        if (reference) |r| {
            return (try self.resolve(r)) orelse error.SessionNotFound;
        }
        if (self.by_id.count() == 0) return error.SessionNotFound;
        if (self.by_id.count() > 1) return error.AmbiguousPrefix;
        var it = self.by_id.valueIterator();
        return it.next().?.*;
    }

    fn remove(self: *SessionRegistry, sess: *Session) void {
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
    fn drainAll(self: *SessionRegistry) void {
        var it = self.by_id.valueIterator();
        while (it.next()) |sess_ptr| {
            const sess = sess_ptr.*;
            while (sess.terminal.pollEvent()) |event| {
                const now = std.time.milliTimestamp();
                switch (event) {
                    .screen_update => sess.last_screen_change_at_ms = now,
                    .exited => |code| {
                        // Only transition from .running — if the session
                        // was already marked .killed by handleKill, don't
                        // overwrite that with .exited when the child dies
                        // from the SIGKILL.
                        if (sess.status == .running) {
                            sess.status = .exited;
                            sess.exit_code = code;
                            logDrainedEvent(sess, now, event);
                            broadcastExitedToAttach(sess, code);
                            closeLogFile(sess);
                            // Name stays reserved until `hty delete` so
                            // `hty replay NAME` still finds the session.
                        }
                    },
                    .failure => {
                        if (sess.status == .running) {
                            sess.status = .failed;
                            logDrainedEvent(sess, now, event);
                            closeLogFile(sess);
                        }
                    },
                    .raw_bytes => |bytes| {
                        logDrainedEvent(sess, now, event);
                        broadcastRawBytesToAttach(sess, bytes);
                    },
                    .title_changed, .bell => logDrainedEvent(sess, now, event),
                    else => {},
                }
                var owned = event;
                owned.deinit(sess.alloc);
            }
            // Reap any attach clients whose reader thread has exited.
            reapClosedAttachClients(sess);
        }
    }

    /// Number of sessions still running. Exited/failed sessions are held in
    /// the registry as zombies until either `hty kill` reaps them explicitly
    /// or the server auto-shuts-down. Used by the auto-shutdown timer — we
    /// don't want zombies to block an otherwise-idle server from exiting.
    fn activeCount(self: *const SessionRegistry) usize {
        var count: usize = 0;
        var it = self.by_id.valueIterator();
        while (it.next()) |sess_ptr| {
            if (sess_ptr.*.status == .running) count += 1;
        }
        return count;
    }
};

// ============================================================================
// Session event log
// ============================================================================

/// Append one JSONL line (no trailing newline on input) to the session's log
/// file, followed by '\n'. Silent no-op if the session has no log file.
fn writeLogEvent(sess: *Session, line: []const u8) void {
    const log_file = sess.log_file orelse return;
    log_file.writeAll(line) catch return;
    log_file.writeAll("\n") catch return;
}

fn closeLogFile(sess: *Session) void {
    if (sess.log_file) |*f| {
        f.close();
        sess.log_file = null;
    }
}

/// Open the log file for a freshly-created session and write the spawn event.
/// Best-effort: on failure, logs a warning and leaves sess.log_file null.
fn openSessionLog(
    arena: Allocator,
    registry: *SessionRegistry,
    sess: *Session,
    program: []const u8,
    args: []const []const u8,
    rows: u16,
    cols: u16,
) void {
    const log_dir = registry.log_dir orelse return;

    const log_path = std.fmt.allocPrint(arena, "{s}/{s}.jsonl", .{ log_dir, &sess.id }) catch |err| {
        std.debug.print("session log alloc failed: {s}\n", .{@errorName(err)});
        return;
    };

    const file = std.fs.createFileAbsolute(log_path, .{
        .truncate = false,
        .mode = 0o600,
    }) catch |err| {
        std.debug.print("session log open failed ({s}): {s}\n", .{ log_path, @errorName(err) });
        return;
    };
    file.seekFromEnd(0) catch |err| {
        std.debug.print("session log seek failed: {s}\n", .{@errorName(err)});
        file.close();
        return;
    };
    sess.log_file = file;

    const spawn_payload = .{
        .t = std.time.milliTimestamp(),
        .kind = "spawn",
        .program = program,
        .args = args,
        .name = sess.name,
        .rows = rows,
        .cols = cols,
    };
    const line = std.json.Stringify.valueAlloc(arena, spawn_payload, .{}) catch return;
    writeLogEvent(sess, line);

    if (sess.name) |name| {
        createByNameSymlink(arena, log_dir, name, &sess.id) catch |err| {
            std.debug.print("by-name symlink failed ({s}): {s}\n", .{ name, @errorName(err) });
        };
    }
}

fn createByNameSymlink(
    arena: Allocator,
    log_dir: []const u8,
    name: []const u8,
    id: []const u8,
) !void {
    // Defensive: reject names that would escape the by-name directory.
    if (std.mem.indexOfScalar(u8, name, '/') != null) return error.UnsafeName;
    if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return error.UnsafeName;

    const link_path = try std.fmt.allocPrint(arena, "{s}/by-name/{s}.jsonl", .{ log_dir, name });
    // Relative target so the link keeps working if the log dir is moved.
    const target = try std.fmt.allocPrint(arena, "../{s}.jsonl", .{id});

    std.fs.deleteFileAbsolute(link_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    const target_z = try arena.dupeZ(u8, target);
    const link_z = try arena.dupeZ(u8, link_path);
    try std.posix.symlink(target_z, link_z);
}

/// Append a drained PTY event to the session log. Caller has already decided
/// the event kind is loggable; screen_update and started are filtered upstream.
fn logDrainedEvent(sess: *Session, now_ms: i64, event: hty.OutputEvent) void {
    if (sess.log_file == null) return;
    var arena_state = std.heap.ArenaAllocator.init(sess.alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const line = switch (event) {
        .raw_bytes => |bytes| std.json.Stringify.valueAlloc(arena, .{
            .t = now_ms,
            .kind = "output",
            .bytes_hex = encodeHex(arena, bytes) catch return,
        }, .{}) catch return,
        .title_changed => |title| std.json.Stringify.valueAlloc(arena, .{
            .t = now_ms,
            .kind = "title",
            .title = title,
        }, .{}) catch return,
        .bell => std.json.Stringify.valueAlloc(arena, .{
            .t = now_ms,
            .kind = "bell",
        }, .{}) catch return,
        .exited => |code| std.json.Stringify.valueAlloc(arena, .{
            .t = now_ms,
            .kind = "exited",
            .code = code,
        }, .{}) catch return,
        .failure => |message| std.json.Stringify.valueAlloc(arena, .{
            .t = now_ms,
            .kind = "failure",
            .message = message,
        }, .{}) catch return,
        else => return,
    };
    writeLogEvent(sess, line);
}

fn logInputEvent(arena: Allocator, sess: *Session, bytes: []const u8) void {
    if (sess.log_file == null) return;
    const hex = encodeHex(arena, bytes) catch return;
    const line = std.json.Stringify.valueAlloc(arena, .{
        .t = std.time.milliTimestamp(),
        .kind = "input",
        .bytes_hex = hex,
    }, .{}) catch return;
    writeLogEvent(sess, line);
}

fn logKilledEvent(arena: Allocator, sess: *Session) void {
    if (sess.log_file == null) return;
    const line = std.json.Stringify.valueAlloc(arena, .{
        .t = std.time.milliTimestamp(),
        .kind = "killed",
    }, .{}) catch return;
    writeLogEvent(sess, line);
}

// ============================================================================
// Attach broadcast
// ============================================================================

/// Build a JSONL output frame ({"kind":"output","bytes_hex":"..."}) and
/// broadcast it to every client attached to `sess`. Clients whose write
/// fails get marked closed and reaped on the next drain pass.
fn broadcastRawBytesToAttach(sess: *Session, bytes: []const u8) void {
    sess.attach_mutex.lock();
    defer sess.attach_mutex.unlock();
    if (sess.attach_clients.items.len == 0) return;

    var arena_state = std.heap.ArenaAllocator.init(sess.alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const hex = encodeHex(arena, bytes) catch return;
    const frame = std.fmt.allocPrint(
        arena,
        "{{\"kind\":\"output\",\"bytes_hex\":\"{s}\"}}\n",
        .{hex},
    ) catch return;
    for (sess.attach_clients.items) |client| _ = client.tryWriteFrame(frame);
}

fn broadcastExitedToAttach(sess: *Session, code: ?i32) void {
    sess.attach_mutex.lock();
    defer sess.attach_mutex.unlock();
    if (sess.attach_clients.items.len == 0) return;

    var arena_state = std.heap.ArenaAllocator.init(sess.alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const frame = std.fmt.allocPrint(
        arena,
        "{{\"kind\":\"exited\",\"code\":{d}}}\n",
        .{code orelse 0},
    ) catch return;
    for (sess.attach_clients.items) |client| {
        _ = client.tryWriteFrame(frame);
        // Exit is terminal for the session, so also mark the client closed
        // so its reader thread (and the deinit path) can shut down cleanly.
        client.shutdown();
    }
}

/// Remove any attached clients whose socket has been closed (either by the
/// client itself or by a failed write in the broadcast loop).
fn reapClosedAttachClients(sess: *Session) void {
    sess.attach_mutex.lock();
    var reaped: std.ArrayListUnmanaged(*AttachClient) = .{};
    defer reaped.deinit(sess.alloc);

    var i: usize = 0;
    while (i < sess.attach_clients.items.len) {
        const client = sess.attach_clients.items[i];
        if (client.isClosed()) {
            _ = sess.attach_clients.swapRemove(i);
            reaped.append(sess.alloc, client) catch {};
            continue;
        }
        i += 1;
    }
    sess.attach_mutex.unlock();

    // deinit joins the reader thread — do it outside the mutex so the reader
    // can call back into session state without deadlocking.
    for (reaped.items) |client| client.deinit();
}

// ============================================================================
// Wire protocol types
// ============================================================================

const Response = struct {
    id: ?i64 = null,
    ok: bool,
    @"error": ?[]const u8 = null,
    timed_out: bool = false,
    snapshot: ?SnapshotPayload = null,
    event: ?EventPayload = null,
    session: ?SessionSummary = null,
    sessions: ?[]const SessionSummary = null,
};

const SnapshotPayload = struct {
    rows: u16,
    cols: u16,
    cursor_row: u16,
    cursor_col: u16,
    title: ?[]const u8,
    buffer: []const u8,
    screen_ansi: []const u8,
    lines: []const []const u8,
    status: []const u8 = "running",
};

const EventPayload = struct {
    kind: []const u8,
    code: ?i32 = null,
    title: ?[]const u8 = null,
    message: ?[]const u8 = null,
    bytes_hex: ?[]const u8 = null,
};

const SessionSummary = struct {
    id: []const u8,
    name: ?[]const u8,
    program: []const u8,
    args: []const u8,
    status: []const u8,
    created_at_ms: i64,
};

fn statusName(status: SessionStatus) []const u8 {
    return switch (status) {
        .running => "running",
        .exited => "exited",
        .failed => "failed",
        .killed => "killed",
    };
}

// ============================================================================
// Server: accept loop + request dispatch
// ============================================================================

const empty_grace_ms: i64 = 10_000;

fn runServer(alloc: Allocator, socket_path: []const u8) !void {
    // Unlink stale socket file if present.
    std.posix.unlink(socket_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };

    const address = try std.net.Address.initUnix(socket_path);
    var server = try address.listen(.{ .reuse_address = true });
    defer server.deinit();
    defer std.posix.unlink(socket_path) catch {};

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

    // Auto-shutdown: start in "empty" state. Every time the registry drops to
    // zero running sessions we note the timestamp; if we sit there for
    // empty_grace_ms without a new session, exit the server. A new session
    // clears the timer. The grace period absorbs rapid kill+run sequences.
    var empty_since_ms: ?i64 = std.time.milliTimestamp();

    while (true) {
        // Short poll so the accept loop wakes ~40 times per second and can
        // drain PTY events into the log / attach broadcast pipeline even
        // when no new RPC traffic arrives. 25ms matches the wait_for_*
        // polling granularity elsewhere in the server.
        var poll_fds = [_]std.posix.pollfd{.{
            .fd = server.stream.handle,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};
        const ready = std.posix.poll(&poll_fds, 25) catch |err| {
            std.debug.print("poll failed: {s}\n", .{@errorName(err)});
            continue;
        };

        // Drain every tick so attach clients see output promptly and the
        // session log file captures bytes even if the session has no RPC
        // traffic driving it.
        registry.drainAll();

        if (ready > 0 and (poll_fds[0].revents & std.posix.POLL.IN) != 0) {
            var conn = server.accept() catch |err| {
                std.debug.print("accept failed: {s}\n", .{@errorName(err)});
                continue;
            };
            const result = handleConnection(alloc, &registry, &conn) catch |err| blk: {
                std.debug.print("request failed: {s}\n", .{@errorName(err)});
                break :blk ConnectionResult.done;
            };
            switch (result) {
                .done => conn.stream.close(),
                .attached => {}, // Reader thread owns the stream now.
            }
        }

        // Update the empty-tracking timer based on the post-tick state.
        // Zombie (exited) sessions don't count — we only care whether
        // there's any _running_ process we'd be cutting off.
        if (registry.activeCount() > 0) {
            empty_since_ms = null;
        } else if (empty_since_ms == null) {
            empty_since_ms = std.time.milliTimestamp();
        }

        if (empty_since_ms) |since| {
            if (std.time.milliTimestamp() - since >= empty_grace_ms) return;
        }
    }
}

const ConnectionResult = enum { done, attached };

fn handleConnection(
    alloc: Allocator,
    registry: *SessionRegistry,
    conn: *std.net.Server.Connection,
) !ConnectionResult {
    // Read one request line.
    var buffer = std.array_list.Managed(u8).init(alloc);
    defer buffer.deinit();

    var chunk: [4096]u8 = undefined;
    while (true) {
        const n = try conn.stream.read(&chunk);
        if (n == 0) break;
        try buffer.appendSlice(chunk[0..n]);
        if (std.mem.indexOfScalar(u8, buffer.items, '\n') != null) break;
    }

    const newline = std.mem.indexOfScalar(u8, buffer.items, '\n') orelse buffer.items.len;
    const line = buffer.items[0..newline];

    if (std.mem.trim(u8, line, " \t\r").len == 0) {
        const empty = try encodeResponse(alloc, .{ .ok = false, .@"error" = "empty request" });
        defer alloc.free(empty);
        _ = try conn.stream.writeAll(empty);
        return .done;
    }

    // Peek at the op without consuming arena state; attach needs a
    // different lifecycle (keep the connection open, spawn a reader
    // thread) so we branch here before the normal RPC dispatch.
    const is_attach = detectAttachOp(alloc, line);
    if (is_attach) {
        return handleAttachConnection(alloc, registry, conn, line);
    }

    const response = try processRequestLine(alloc, registry, line);
    defer alloc.free(response);
    _ = try conn.stream.writeAll(response);
    return .done;
}

/// Parse the request line far enough to recognize an attach op. Errors and
/// non-attach ops both return false so the normal RPC path handles them.
fn detectAttachOp(alloc: Allocator, line: []const u8) bool {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, line, .{}) catch return false;
    const object = switch (parsed) {
        .object => |o| o,
        else => return false,
    };
    const op_val = object.get("op") orelse return false;
    if (op_val != .string) return false;
    return std.mem.eql(u8, op_val.string, "attach");
}

/// Full lifecycle of an attach-style connection: parse the request,
/// resolve the session, register a subscriber, write the initial ack
/// and snapshot frame, and spawn a reader thread that owns the socket
/// for the rest of the attach lifetime. Returns `.attached` on success
/// so the accept loop hands off socket ownership; `.done` on failure
/// (the accept loop closes the connection).
fn handleAttachConnection(
    alloc: Allocator,
    registry: *SessionRegistry,
    conn: *std.net.Server.Connection,
    line: []const u8,
) !ConnectionResult {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, line, .{}) catch {
        try writeAttachError(conn.stream, "invalid json");
        return .done;
    };
    const object = switch (parsed) {
        .object => |o| o,
        else => {
            try writeAttachError(conn.stream, "request must be a JSON object");
            return .done;
        },
    };

    const session_ref = readOptionalString(object, "session") catch null;
    const sess = registry.resolveOrSole(session_ref) catch |err| {
        try writeAttachError(conn.stream, requestErrorMessage(err));
        return .done;
    };

    // Optional resize on attach so the PTY matches the observer's terminal.
    if (object.get("rows")) |rv| {
        if (object.get("cols")) |cv| {
            if (rv == .integer and cv == .integer) {
                const rows: u16 = @intCast(@max(1, rv.integer));
                const cols: u16 = @intCast(@max(1, cv.integer));
                sess.terminal.resize(rows, cols) catch {};
            }
        }
    }

    // Create the client and register it under the session's attach mutex.
    const client = alloc.create(AttachClient) catch return .done;
    client.* = .{
        .alloc = alloc,
        .session = sess,
        .stream = conn.stream,
    };
    sess.attach_mutex.lock();
    sess.attach_clients.append(alloc, client) catch {
        sess.attach_mutex.unlock();
        alloc.destroy(client);
        return .done;
    };
    sess.attach_mutex.unlock();

    // Write the attach ack. Once this goes out the client flips into
    // streaming mode.
    try writeAttachAck(conn.stream);

    // Send an initial snapshot so the attach viewer has something to
    // show right away (the recorded output stream doesn't replay).
    if (sess.terminal.snapshot()) |snap| {
        var owned = snap;
        defer owned.deinit(sess.alloc);
        // Reuse the broadcast encoder shape — feed the raw screen_ansi
        // as an output frame so the client's output decoder handles it.
        const hex = encodeHex(arena, owned.screen_ansi) catch null;
        if (hex) |h| {
            const frame = std.fmt.allocPrint(
                arena,
                "{{\"kind\":\"output\",\"bytes_hex\":\"{s}\"}}\n",
                .{h},
            ) catch null;
            if (frame) |f| _ = client.tryWriteFrame(f);
        }
    } else |_| {}

    // Spawn the reader thread that owns the socket from here on.
    client.reader_thread = std.Thread.spawn(.{}, attachReaderLoop, .{client}) catch {
        // On spawn failure, remove from the list and tear down.
        sess.attach_mutex.lock();
        var i: usize = 0;
        while (i < sess.attach_clients.items.len) : (i += 1) {
            if (sess.attach_clients.items[i] == client) {
                _ = sess.attach_clients.swapRemove(i);
                break;
            }
        }
        sess.attach_mutex.unlock();
        client.deinit();
        return .done;
    };

    return .attached;
}

fn writeAttachAck(stream: std.net.Stream) !void {
    try stream.writeAll("{\"ok\":true}\n");
}

fn writeAttachError(stream: std.net.Stream, message: []const u8) !void {
    var buf: [256]u8 = undefined;
    const line = std.fmt.bufPrint(
        &buf,
        "{{\"ok\":false,\"error\":\"{s}\"}}\n",
        .{message},
    ) catch "{\"ok\":false,\"error\":\"attach failed\"}\n";
    try stream.writeAll(line);
}

/// Reader thread for one attach connection. Reads JSONL frames from the
/// socket and dispatches: input bytes get forwarded to the PTY, resize
/// ops retarget the terminal, detach ops exit the loop cleanly. Any
/// error (EOF, parse failure, bad socket) ends the loop; the client is
/// marked closed so the next drain pass reaps it.
fn attachReaderLoop(client: *AttachClient) void {
    defer client.closed.store(true, .release);

    const alloc = client.alloc;
    var buffer = std.array_list.Managed(u8).init(alloc);
    defer buffer.deinit();

    var chunk: [4096]u8 = undefined;
    while (!client.isClosed()) {
        const n = client.stream.read(&chunk) catch break;
        if (n == 0) break;
        buffer.appendSlice(chunk[0..n]) catch break;

        while (std.mem.indexOfScalar(u8, buffer.items, '\n')) |nl| {
            const line = buffer.items[0..nl];
            dispatchAttachFrame(client, line) catch break;
            // Shift leftover bytes to the front.
            const rest = buffer.items[nl + 1 ..];
            std.mem.copyForwards(u8, buffer.items[0..rest.len], rest);
            buffer.shrinkRetainingCapacity(rest.len);
        }
    }
}

fn dispatchAttachFrame(client: *AttachClient, line: []const u8) !void {
    if (std.mem.trim(u8, line, " \t\r").len == 0) return;

    var arena_state = std.heap.ArenaAllocator.init(client.alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, line, .{}) catch return error.BadFrame;
    const object = switch (parsed) {
        .object => |o| o,
        else => return error.BadFrame,
    };

    const op_val = object.get("op") orelse return;
    if (op_val != .string) return;
    const op = op_val.string;

    if (std.mem.eql(u8, op, "input")) {
        const hex_val = object.get("bytes_hex") orelse return;
        if (hex_val != .string) return;
        const bytes = decodeHex(arena, hex_val.string) catch return;
        client.session.terminal.send(.{ .bytes = bytes }) catch {};
        // Mirror the RPC send path: record input in the log too.
        logInputEvent(arena, client.session, bytes);
        return;
    }

    if (std.mem.eql(u8, op, "resize")) {
        const rows_val = object.get("rows") orelse return;
        const cols_val = object.get("cols") orelse return;
        if (rows_val != .integer or cols_val != .integer) return;
        const rows: u16 = @intCast(@max(1, rows_val.integer));
        const cols: u16 = @intCast(@max(1, cols_val.integer));
        client.session.terminal.resize(rows, cols) catch {};
        return;
    }

    if (std.mem.eql(u8, op, "detach")) {
        return error.Detach;
    }
}

fn processRequestLine(alloc: Allocator, registry: *SessionRegistry, line: []const u8) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const value = std.json.parseFromSliceLeaky(std.json.Value, arena, line, .{}) catch |err| {
        return encodeResponse(alloc, .{
            .ok = false,
            .@"error" = @errorName(err),
        });
    };

    const object = switch (value) {
        .object => |object| object,
        else => {
            return encodeResponse(alloc, .{
                .ok = false,
                .@"error" = "request must be a JSON object",
            });
        },
    };

    const id = readOptionalId(object);
    const op = readRequiredString(object, "op") catch |err| {
        return encodeResponse(alloc, .{
            .id = id,
            .ok = false,
            .@"error" = @errorName(err),
        });
    };

    const response: Response = dispatchRequest(arena, registry, object, op, id) catch |err| .{
        .id = id,
        .ok = false,
        .@"error" = requestErrorMessage(err),
    };
    return encodeResponse(alloc, response);
}

fn dispatchRequest(
    arena: Allocator,
    registry: *SessionRegistry,
    object: std.json.ObjectMap,
    op: []const u8,
    id: ?i64,
) !Response {
    if (std.mem.eql(u8, op, "spawn")) return handleSpawn(arena, registry, object, id);
    if (std.mem.eql(u8, op, "list")) return handleList(arena, registry, id);

    // Validate the op before touching the session registry so unknown ops
    // surface as UnknownOperation rather than SessionNotFound.
    const known_ops = [_][]const u8{
        "snapshot",      "send_text",     "send_key",       "send_bytes_hex",
        "resize",        "wait_for_text", "wait_for_idle",  "wait_for_exit",
        "kill",          "delete",
    };
    var matched_op = false;
    for (known_ops) |candidate| {
        if (std.mem.eql(u8, op, candidate)) {
            matched_op = true;
            break;
        }
    }
    if (!matched_op) return error.UnknownOperation;

    const session_ref = try readOptionalString(object, "session");
    const sess = try registry.resolveOrSole(session_ref);

    if (std.mem.eql(u8, op, "snapshot")) return handleSnapshot(arena, sess, id);
    if (std.mem.eql(u8, op, "send_text")) return handleSendText(arena, sess, object, id);
    if (std.mem.eql(u8, op, "send_key")) return handleSendKey(arena, sess, object, id);
    if (std.mem.eql(u8, op, "send_bytes_hex")) return handleSendBytesHex(arena, sess, object, id);
    if (std.mem.eql(u8, op, "resize")) return handleResize(sess, object, id);
    if (std.mem.eql(u8, op, "wait_for_text")) return handleWaitForText(arena, registry, sess, object, id);
    if (std.mem.eql(u8, op, "wait_for_idle")) return handleWaitForIdle(arena, registry, sess, object, id);
    if (std.mem.eql(u8, op, "wait_for_exit")) return handleWaitForExit(arena, registry, sess, object, id);
    if (std.mem.eql(u8, op, "kill")) return handleKill(arena, registry, sess, id);
    if (std.mem.eql(u8, op, "delete")) return handleDelete(arena, registry, sess, id);

    return error.UnknownOperation;
}

fn handleSpawn(
    arena: Allocator,
    registry: *SessionRegistry,
    object: std.json.ObjectMap,
    id: ?i64,
) !Response {
    const program = try readRequiredString(object, "program");
    const args = try readStringArray(arena, object, "args");
    const env = try readEnvArray(arena, object, "env");
    const rows = try readOptionalU16(object, "rows", 24);
    const cols = try readOptionalU16(object, "cols", 80);
    const scrollback = try readOptionalUsize(object, "scrollback", 10_000);
    const cwd = try readOptionalString(object, "cwd");
    // Session logging always needs raw bytes; the client-provided value is
    // accepted for forward-compat but ignored.
    _ = try readOptionalBool(object, "emit_raw_bytes", true);
    const emit_raw_bytes = true;
    const emit_screen_updates = try readOptionalBool(object, "emit_screen_updates", true);
    const name = try readOptionalString(object, "name");

    const terminal = try hty.InteractiveTerminal.spawn(
        registry.alloc,
        .{
            .program = program,
            .args = args,
        },
        .{
            .rows = rows,
            .cols = cols,
            .scrollback = scrollback,
            .env = env,
            .cwd = cwd,
            .emit_raw_bytes = emit_raw_bytes,
            .emit_screen_updates = emit_screen_updates,
        },
    );
    errdefer terminal.deinit();

    const program_owned = try registry.alloc.dupe(u8, program);
    errdefer registry.alloc.free(program_owned);

    const args_joined_owned = try joinArgs(registry.alloc, args);
    errdefer registry.alloc.free(args_joined_owned);

    const name_owned: ?[]u8 = if (name) |n| try registry.alloc.dupe(u8, n) else null;
    errdefer if (name_owned) |n| registry.alloc.free(n);

    const sess = try registry.create(terminal, program_owned, args_joined_owned, name_owned);

    openSessionLog(arena, registry, sess, program, args, rows, cols);

    return .{
        .id = id,
        .ok = true,
        .session = try buildSessionSummary(arena, sess),
    };
}

fn handleList(arena: Allocator, registry: *SessionRegistry, id: ?i64) !Response {
    const summaries = try arena.alloc(SessionSummary, registry.by_id.count());
    var it = registry.by_id.valueIterator();
    var index: usize = 0;
    while (it.next()) |sess_ptr| : (index += 1) {
        summaries[index] = try buildSessionSummary(arena, sess_ptr.*);
    }

    return .{
        .id = id,
        .ok = true,
        .sessions = summaries,
    };
}

fn handleSnapshot(arena: Allocator, sess: *Session, id: ?i64) !Response {
    var snapshot = try sess.terminal.snapshot();
    defer snapshot.deinit(sess.alloc);

    const buffer = try arena.dupe(u8, snapshot.buffer);
    const screen_ansi = try arena.dupe(u8, snapshot.screen_ansi);
    const title = if (snapshot.title) |current_title|
        try arena.dupe(u8, current_title)
    else
        null;
    const lines = try arena.alloc([]const u8, snapshot.lines.len);
    var line_iter = std.mem.splitScalar(u8, buffer, '\n');
    var idx: usize = 0;
    while (line_iter.next()) |line| : (idx += 1) {
        lines[idx] = line;
    }

    return .{
        .id = id,
        .ok = true,
        .snapshot = .{
            .rows = snapshot.rows,
            .cols = snapshot.cols,
            .cursor_row = snapshot.cursor_row,
            .cursor_col = snapshot.cursor_col,
            .title = title,
            .buffer = buffer,
            .screen_ansi = screen_ansi,
            .lines = lines,
            .status = statusName(sess.status),
        },
    };
}

fn handleSendText(arena: Allocator, sess: *Session, object: std.json.ObjectMap, id: ?i64) !Response {
    const text = try readRequiredString(object, "text");
    logInputEvent(arena, sess, text);
    try sess.terminal.send(.{ .text = text });
    return .{ .id = id, .ok = true };
}

fn handleSendKey(arena: Allocator, sess: *Session, object: std.json.ObjectMap, id: ?i64) !Response {
    const key = try readRequiredString(object, "key");
    const bytes = try keyToBytes(arena, key);
    logInputEvent(arena, sess, bytes);
    try sess.terminal.send(.{ .bytes = bytes });
    return .{ .id = id, .ok = true };
}

fn handleSendBytesHex(arena: Allocator, sess: *Session, object: std.json.ObjectMap, id: ?i64) !Response {
    const bytes_hex = try readRequiredString(object, "bytes_hex");
    const bytes = try decodeHex(arena, bytes_hex);
    logInputEvent(arena, sess, bytes);
    try sess.terminal.send(.{ .bytes = bytes });
    return .{ .id = id, .ok = true };
}

fn handleResize(sess: *Session, object: std.json.ObjectMap, id: ?i64) !Response {
    const rows = try readRequiredU16(object, "rows");
    const cols = try readRequiredU16(object, "cols");
    try sess.terminal.resize(rows, cols);
    return .{ .id = id, .ok = true };
}

fn handleWaitForText(
    arena: Allocator,
    registry: *SessionRegistry,
    sess: *Session,
    object: std.json.ObjectMap,
    id: ?i64,
) !Response {
    const needle = try readRequiredString(object, "text");
    const timeout_ms = try readOptionalU64(object, "timeout_ms", 10_000);
    const deadline = std.time.milliTimestamp() + @as(i64, @intCast(timeout_ms));

    while (std.time.milliTimestamp() <= deadline) {
        registry.drainAll();
        var snapshot = try sess.terminal.snapshot();
        const matched = std.mem.indexOf(u8, snapshot.buffer, needle) != null;
        if (matched) {
            defer snapshot.deinit(sess.alloc);
            return try snapshotResponse(arena, id, snapshot, sess);
        }
        snapshot.deinit(sess.alloc);
        std.Thread.sleep(25 * std.time.ns_per_ms);
    }
    return .{ .id = id, .ok = true, .timed_out = true };
}

fn handleWaitForIdle(
    arena: Allocator,
    registry: *SessionRegistry,
    sess: *Session,
    object: std.json.ObjectMap,
    id: ?i64,
) !Response {
    const idle_ms_field = try readOptionalU64(object, "idle_ms", 250);
    const timeout_ms = try readOptionalU64(object, "timeout_ms", 10_000);
    const idle_ms: i64 = @intCast(idle_ms_field);
    const deadline = std.time.milliTimestamp() + @as(i64, @intCast(timeout_ms));

    while (std.time.milliTimestamp() <= deadline) {
        registry.drainAll();
        const since = std.time.milliTimestamp() - sess.last_screen_change_at_ms;
        if (since >= idle_ms) {
            var snapshot = try sess.terminal.snapshot();
            defer snapshot.deinit(sess.alloc);
            return try snapshotResponse(arena, id, snapshot, sess);
        }
        std.Thread.sleep(25 * std.time.ns_per_ms);
    }
    return .{ .id = id, .ok = true, .timed_out = true };
}

fn handleWaitForExit(
    arena: Allocator,
    registry: *SessionRegistry,
    sess: *Session,
    object: std.json.ObjectMap,
    id: ?i64,
) !Response {
    _ = arena;
    const timeout_ms = try readOptionalU64(object, "timeout_ms", 10_000);
    const deadline = std.time.milliTimestamp() + @as(i64, @intCast(timeout_ms));

    while (std.time.milliTimestamp() <= deadline) {
        registry.drainAll();
        if (sess.status != .running) {
            return .{
                .id = id,
                .ok = true,
                .event = .{ .kind = "exited", .code = sess.exit_code },
            };
        }
        std.Thread.sleep(25 * std.time.ns_per_ms);
    }
    return .{ .id = id, .ok = true, .timed_out = true };
}

fn handleKill(arena: Allocator, registry: *SessionRegistry, sess: *Session, id: ?i64) !Response {
    _ = registry;
    if (sess.status == .running) {
        logKilledEvent(arena, sess);
        closeLogFile(sess);
        sess.terminal.kill() catch {};
        sess.status = .killed;
        // Name stays reserved — the session record is still browsable and
        // replayable until explicitly removed with `hty delete`.
    }
    return .{ .id = id, .ok = true };
}

fn handleDelete(arena: Allocator, registry: *SessionRegistry, sess: *Session, id: ?i64) !Response {
    // Terminate the child if it's still running so we don't orphan it.
    if (sess.status == .running) {
        logKilledEvent(arena, sess);
        closeLogFile(sess);
        sess.terminal.kill() catch {};
        sess.status = .killed;
    } else {
        // Already ended; just make sure the log file handle is closed.
        closeLogFile(sess);
    }

    // Delete the log file and by-name symlink from disk before the session
    // struct (and its id/name storage) go away.
    if (registry.log_dir) |log_dir| {
        const uuid_path = std.fmt.allocPrint(
            arena,
            "{s}/{s}.jsonl",
            .{ log_dir, &sess.id },
        ) catch null;
        if (uuid_path) |p| std.fs.deleteFileAbsolute(p) catch {};

        if (sess.name) |name| {
            const link_path = std.fmt.allocPrint(
                arena,
                "{s}/by-name/{s}.jsonl",
                .{ log_dir, name },
            ) catch null;
            if (link_path) |p| std.fs.deleteFileAbsolute(p) catch {};
        }
    }

    registry.remove(sess);
    return .{ .id = id, .ok = true };
}

fn snapshotResponse(arena: Allocator, id: ?i64, snapshot: hty.ScreenSnapshot, sess: *Session) !Response {
    const buffer = try arena.dupe(u8, snapshot.buffer);
    const screen_ansi = try arena.dupe(u8, snapshot.screen_ansi);
    const title = if (snapshot.title) |current_title|
        try arena.dupe(u8, current_title)
    else
        null;
    const lines = try arena.alloc([]const u8, snapshot.lines.len);
    var line_iter = std.mem.splitScalar(u8, buffer, '\n');
    var idx: usize = 0;
    while (line_iter.next()) |line| : (idx += 1) {
        lines[idx] = line;
    }

    return .{
        .id = id,
        .ok = true,
        .snapshot = .{
            .rows = snapshot.rows,
            .cols = snapshot.cols,
            .cursor_row = snapshot.cursor_row,
            .cursor_col = snapshot.cursor_col,
            .title = title,
            .buffer = buffer,
            .screen_ansi = screen_ansi,
            .lines = lines,
            .status = statusName(sess.status),
        },
    };
}

fn buildSessionSummary(arena: Allocator, sess: *Session) !SessionSummary {
    return .{
        .id = try arena.dupe(u8, &sess.id),
        .name = if (sess.name) |n| try arena.dupe(u8, n) else null,
        .program = try arena.dupe(u8, sess.program),
        .args = try arena.dupe(u8, sess.args_joined),
        .status = statusName(sess.status),
        .created_at_ms = sess.created_at_ms,
    };
}

fn joinArgs(alloc: Allocator, args: []const []const u8) ![]u8 {
    if (args.len == 0) return try alloc.alloc(u8, 0);
    var total: usize = 0;
    for (args) |arg| total += arg.len + 1;
    const out = try alloc.alloc(u8, total - 1);
    var idx: usize = 0;
    for (args, 0..) |arg, i| {
        if (i > 0) {
            out[idx] = ' ';
            idx += 1;
        }
        @memcpy(out[idx..][0..arg.len], arg);
        idx += arg.len;
    }
    return out;
}

// ============================================================================
// ensureServer — auto-start on first client command
// ============================================================================

const EnsureServerOptions = struct {
    attempts: usize = 30,
    delay_ms: u64 = 50,
};

fn ensureServer(alloc: Allocator, socket_path: []const u8, opts: EnsureServerOptions) !std.net.Stream {
    if (tryConnect(socket_path)) |stream| return stream else |err| switch (err) {
        error.FileNotFound, error.ConnectionRefused => {
            // When HTY_SOCKET is set we assume the server lives on another
            // machine (or at least another namespace) behind that endpoint.
            // Don't try to spawn a local one — fail fast so the user knows
            // their tunnel is down.
            if (std.posix.getenv("HTY_SOCKET")) |override| {
                if (override.len > 0) return error.ServerUnreachable;
            }
            // Stale or missing socket — try to unlink and spawn.
            std.posix.unlink(socket_path) catch {};
            try spawnServer(alloc, socket_path);
        },
        else => return err,
    }

    // Retry connection with backoff.
    var attempt: usize = 0;
    while (attempt < opts.attempts) : (attempt += 1) {
        if (tryConnect(socket_path)) |stream| return stream else |_| {}
        std.Thread.sleep(opts.delay_ms * std.time.ns_per_ms);
    }
    return error.ServerUnreachable;
}

fn tryConnect(socket_path: []const u8) !std.net.Stream {
    return std.net.connectUnixSocket(socket_path);
}

fn spawnServer(alloc: Allocator, socket_path: []const u8) !void {
    const pid = std.posix.fork() catch return error.ForkFailed;
    if (pid != 0) return;

    // Child: detach from terminal, redirect stdio to /dev/null, then exec a
    // fresh `hty __server__ <socket>` so `ps`/`pgrep` can find the server
    // process by a distinct argv rather than inheriting the parent's.
    _ = c.setsid();
    const devnull = std.posix.open("/dev/null", .{ .ACCMODE = .RDWR }, 0) catch {
        std.posix.exit(1);
    };
    _ = std.posix.dup2(devnull, 0) catch {};
    _ = std.posix.dup2(devnull, 1) catch {};
    _ = std.posix.dup2(devnull, 2) catch {};
    if (devnull > 2) std.posix.close(devnull);

    var self_buf: [std.fs.max_path_bytes]u8 = undefined;
    const self_exe = std.fs.selfExePath(&self_buf) catch {
        // Fallback: run the server in-process. The process name will still
        // be the parent's argv, but at least the server starts.
        runServer(alloc, socket_path) catch std.posix.exit(1);
        std.posix.exit(0);
    };

    const self_exe_z = alloc.dupeZ(u8, self_exe) catch std.posix.exit(1);
    defer alloc.free(self_exe_z);
    const socket_z = alloc.dupeZ(u8, socket_path) catch std.posix.exit(1);
    defer alloc.free(socket_z);

    const argv = [_:null]?[*:0]const u8{
        self_exe_z.ptr,
        "__server__",
        socket_z.ptr,
        null,
    };

    // Pass the parent's environment so $HOME, $XDG_STATE_HOME, $XDG_RUNTIME_DIR
    // etc. reach the server. With an empty envp the log dir can't be resolved.
    _ = c.execve(self_exe_z.ptr, @ptrCast(&argv), @ptrCast(std.c.environ));
    // execve only returns on failure.
    runServer(alloc, socket_path) catch std.posix.exit(1);
    std.posix.exit(0);
}

// ============================================================================
// Client-side request helper
// ============================================================================

fn sendRequest(alloc: Allocator, request_value: anytype) !std.json.Parsed(std.json.Value) {
    const socket_path = try resolveSocketPath(alloc);
    defer alloc.free(socket_path);

    var stream = try ensureServer(alloc, socket_path, .{});
    defer stream.close();

    const payload = try std.json.Stringify.valueAlloc(alloc, request_value, .{});
    defer alloc.free(payload);

    try stream.writeAll(payload);
    try stream.writeAll("\n");

    var response_buf = std.array_list.Managed(u8).init(alloc);
    defer response_buf.deinit();

    var chunk: [4096]u8 = undefined;
    while (true) {
        const n = try stream.read(&chunk);
        if (n == 0) break;
        try response_buf.appendSlice(chunk[0..n]);
        if (std.mem.indexOfScalar(u8, response_buf.items, '\n') != null) break;
    }

    const newline = std.mem.indexOfScalar(u8, response_buf.items, '\n') orelse response_buf.items.len;
    return std.json.parseFromSlice(std.json.Value, alloc, response_buf.items[0..newline], .{});
}

/// Low-level: send a pre-built JSON string to the server; return raw response.
/// Caller owns the returned slice.
fn sendRawRequest(alloc: Allocator, request_json: []const u8) ![]u8 {
    const socket_path = try resolveSocketPath(alloc);
    defer alloc.free(socket_path);

    var stream = try ensureServer(alloc, socket_path, .{});
    defer stream.close();

    try stream.writeAll(request_json);
    try stream.writeAll("\n");

    var response_buf = std.array_list.Managed(u8).init(alloc);
    defer response_buf.deinit();

    var chunk: [4096]u8 = undefined;
    while (true) {
        const n = try stream.read(&chunk);
        if (n == 0) break;
        try response_buf.appendSlice(chunk[0..n]);
        if (std.mem.indexOfScalar(u8, response_buf.items, '\n') != null) break;
    }

    const newline = std.mem.indexOfScalar(u8, response_buf.items, '\n') orelse response_buf.items.len;
    return alloc.dupe(u8, response_buf.items[0..newline]);
}

fn printJsonLine(object: anytype) !void {
    const alloc = std.heap.c_allocator;
    const json = try std.json.Stringify.valueAlloc(alloc, object, .{});
    defer alloc.free(json);
    var stdout = std.fs.File.stdout();
    _ = try stdout.writeAll(json);
    _ = try stdout.writeAll("\n");
}

fn printLine(text: []const u8) !void {
    var stdout = std.fs.File.stdout();
    _ = try stdout.writeAll(text);
    _ = try stdout.writeAll("\n");
}

fn printRaw(text: []const u8) !void {
    var stdout = std.fs.File.stdout();
    _ = try stdout.writeAll(text);
}

fn printErr(text: []const u8) !void {
    var stderr = std.fs.File.stderr();
    _ = try stderr.writeAll(text);
    _ = try stderr.writeAll("\n");
}

fn printErrFmt(comptime fmt: []const u8, args: anytype) !void {
    const alloc = std.heap.c_allocator;
    const msg = try std.fmt.allocPrint(alloc, fmt, args);
    defer alloc.free(msg);
    try printErr(msg);
}

/// Check that a response envelope has ok=true; return the response object.
/// Emits an error message to stderr and exits with the appropriate code on failure.
fn expectOkOrExit(parsed: std.json.Parsed(std.json.Value)) !std.json.ObjectMap {
    const object = switch (parsed.value) {
        .object => |o| o,
        else => {
            try printErr("invalid response from server");
            std.process.exit(ExitCode.generic);
        },
    };
    const ok = object.get("ok") orelse {
        try printErr("malformed response: missing ok field");
        std.process.exit(ExitCode.generic);
    };
    switch (ok) {
        .bool => |v| if (!v) {
            const msg = if (object.get("error")) |err_val|
                switch (err_val) {
                    .string => |s| s,
                    else => "unknown error",
                }
            else
                "unknown error";
            try printErrFmt("error: {s}", .{msg});
            const code = errorToExitCode(msg);
            std.process.exit(code);
        },
        else => {
            try printErr("malformed response: ok is not a boolean");
            std.process.exit(ExitCode.generic);
        },
    }
    return object;
}

fn errorToExitCode(msg: []const u8) u8 {
    if (std.mem.indexOf(u8, msg, "session not found") != null) return ExitCode.not_found;
    if (std.mem.indexOf(u8, msg, "SessionNotFound") != null) return ExitCode.not_found;
    if (std.mem.indexOf(u8, msg, "ambiguous") != null) return ExitCode.ambiguous_prefix;
    if (std.mem.indexOf(u8, msg, "AmbiguousPrefix") != null) return ExitCode.ambiguous_prefix;
    if (std.mem.indexOf(u8, msg, "already exists") != null) return ExitCode.name_exists;
    if (std.mem.indexOf(u8, msg, "NameAlreadyExists") != null) return ExitCode.name_exists;
    return ExitCode.generic;
}

// ============================================================================
// Client subcommands
// ============================================================================

fn runClientRun(alloc: Allocator, args: []const []const u8) !void {
    var name: ?[]const u8 = null;
    var rows: u16 = 24;
    var cols: u16 = 80;
    var cwd: ?[]const u8 = null;
    var scrollback: usize = 10_000;

    var i: usize = 0;
    var program_args_start: ?usize = null;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--")) {
            program_args_start = i + 1;
            break;
        } else if (std.mem.eql(u8, arg, "--name")) {
            i += 1;
            if (i >= args.len) return printUsageAndExit("--name requires a value");
            name = args[i];
        } else if (std.mem.eql(u8, arg, "-d") or std.mem.eql(u8, arg, "--detach")) {
            // Accepted as a no-op — every `hty run` session is detached by
            // default; use `hty attach` afterwards for an interactive
            // bidirectional view.
        } else if (std.mem.eql(u8, arg, "--rows")) {
            i += 1;
            if (i >= args.len) return printUsageAndExit("--rows requires a value");
            rows = try std.fmt.parseInt(u16, args[i], 10);
        } else if (std.mem.eql(u8, arg, "--cols")) {
            i += 1;
            if (i >= args.len) return printUsageAndExit("--cols requires a value");
            cols = try std.fmt.parseInt(u16, args[i], 10);
        } else if (std.mem.eql(u8, arg, "--cwd")) {
            i += 1;
            if (i >= args.len) return printUsageAndExit("--cwd requires a value");
            cwd = args[i];
        } else if (std.mem.eql(u8, arg, "--scrollback")) {
            i += 1;
            if (i >= args.len) return printUsageAndExit("--scrollback requires a value");
            scrollback = try std.fmt.parseInt(usize, args[i], 10);
        } else if (std.mem.startsWith(u8, arg, "--")) {
            try printErrFmt("unknown flag: {s}", .{arg});
            std.process.exit(ExitCode.generic);
        } else {
            // First positional = program, rest = args
            program_args_start = i;
            break;
        }
    }

    const start = program_args_start orelse return printUsageAndExit("missing program");
    if (start >= args.len) return printUsageAndExit("missing program after --");

    const program = args[start];
    const program_args = args[start + 1 ..];

    // Build spawn request as a JSON object manually so we can include name + args cleanly.
    var payload_buf = std.array_list.Managed(u8).init(alloc);
    defer payload_buf.deinit();
    var writer = payload_buf.writer();

    try writer.writeAll("{\"op\":\"spawn\",\"program\":");
    try writeJsonString(writer.any(), program);
    try writer.writeAll(",\"args\":[");
    for (program_args, 0..) |a, idx| {
        if (idx > 0) try writer.writeAll(",");
        try writeJsonString(writer.any(), a);
    }
    try writer.writeAll("]");
    if (name) |n| {
        try writer.writeAll(",\"name\":");
        try writeJsonString(writer.any(), n);
    }
    try writer.print(",\"rows\":{d},\"cols\":{d},\"scrollback\":{d}", .{ rows, cols, scrollback });
    if (cwd) |c_val| {
        try writer.writeAll(",\"cwd\":");
        try writeJsonString(writer.any(), c_val);
    }
    try writer.writeAll("}");

    const response_line = try sendRawRequest(alloc, payload_buf.items);
    defer alloc.free(response_line);

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, response_line, .{});
    defer parsed.deinit();
    const object = try expectOkOrExit(parsed);

    const sess_value = object.get("session") orelse {
        try printErr("server did not return a session");
        std.process.exit(ExitCode.generic);
    };
    const sess_obj = switch (sess_value) {
        .object => |o| o,
        else => {
            try printErr("invalid session payload");
            std.process.exit(ExitCode.generic);
        },
    };

    const id_val = sess_obj.get("id") orelse return;
    const id_str = switch (id_val) {
        .string => |s| s,
        else => return,
    };
    const name_val = sess_obj.get("name");
    const display_name: ?[]const u8 = if (name_val) |nv| switch (nv) {
        .string => |s| s,
        else => null,
    } else null;

    if (display_name) |dn| {
        try printLine(try std.fmt.allocPrint(alloc, "session \"{s}\" started ({s})", .{ dn, id_str[0..8] }));
    } else {
        try printLine(try std.fmt.allocPrint(alloc, "session {s} started", .{id_str[0..8]}));
    }
}

fn writeJsonString(writer: std.io.AnyWriter, s: []const u8) !void {
    try writer.writeByte('"');
    for (s) |b| {
        switch (b) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            0...0x08, 0x0b, 0x0c, 0x0e...0x1f => try writer.print("\\u{x:0>4}", .{b}),
            else => try writer.writeByte(b),
        }
    }
    try writer.writeByte('"');
}

/// Try to read the server's live session list without auto-spawning
/// one. Returns null (owned by the caller) if the server is not
/// currently running.
fn querySeverListIfLive(alloc: Allocator) !?[]u8 {
    const socket_path = try resolveSocketPath(alloc);
    defer alloc.free(socket_path);

    var stream = tryConnect(socket_path) catch return null;
    defer stream.close();

    stream.writeAll("{\"op\":\"list\"}\n") catch return null;

    var buf = std.array_list.Managed(u8).init(alloc);
    defer buf.deinit();

    var chunk: [4096]u8 = undefined;
    while (true) {
        const n = stream.read(&chunk) catch return null;
        if (n == 0) break;
        buf.appendSlice(chunk[0..n]) catch return null;
        if (std.mem.indexOfScalar(u8, buf.items, '\n') != null) break;
    }

    const nl = std.mem.indexOfScalar(u8, buf.items, '\n') orelse buf.items.len;
    return try alloc.dupe(u8, buf.items[0..nl]);
}

const SessionEntry = struct {
    id: []const u8,
    name: []const u8,
    program: []const u8,
    status: []const u8,
    created_at_ms: i64,
};

fn runClientList(alloc: Allocator, args: []const []const u8) !void {
    var json_output = false;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--json")) json_output = true;
    }

    // Arena for the merged-list view: server entries and disk-derived
    // entries both allocate into this and are freed together.
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var entries: std.ArrayListUnmanaged(SessionEntry) = .{};
    var seen_ids = std.StringHashMap(void).init(arena);
    defer seen_ids.deinit();

    // Pull live sessions from the server first — using tryConnect so we
    // DON'T auto-spawn a server just to answer "hty list". If the server
    // isn't running, fall through to the disk scan, which covers any
    // historical records that outlive the server.
    const server_line = querySeverListIfLive(alloc) catch null;
    defer if (server_line) |line| alloc.free(line);

    if (json_output) {
        if (server_line) |line| try printRaw(line);
        try printRaw("\n");
        return;
    }

    if (server_line) |line| {
        var parsed = std.json.parseFromSlice(std.json.Value, alloc, line, .{}) catch null;
        defer if (parsed) |*p| p.deinit();
        if (parsed) |*p| {
            if (p.value == .object) {
                if (p.value.object.get("sessions")) |sessions_val| {
                    if (sessions_val == .array) {
                        for (sessions_val.array.items) |s| {
                            if (s != .object) continue;
                            const obj = s.object;
                            const id_str = getString(obj, "id") orelse continue;
                            const entry = SessionEntry{
                                .id = try arena.dupe(u8, id_str),
                                .name = try arena.dupe(u8, getString(obj, "name") orelse ""),
                                .program = try arena.dupe(u8, getString(obj, "program") orelse ""),
                                .status = try arena.dupe(u8, getString(obj, "status") orelse ""),
                                .created_at_ms = if (obj.get("created_at_ms")) |v| switch (v) {
                                    .integer => |i| i,
                                    else => 0,
                                } else 0,
                            };
                            try entries.append(arena, entry);
                            try seen_ids.put(entry.id, {});
                        }
                    }
                }
            }
        }
    }

    // Supplement with any session log files on disk that the server
    // doesn't know about — crashed sessions, sessions from prior server
    // instances, anything the current registry can't reach.
    scanDiskSessions(arena, &entries, &seen_ids) catch {};

    if (entries.items.len == 0) {
        try printErr("no sessions");
        return;
    }

    // Sort by created_at_ms descending so newest sessions show first.
    std.mem.sort(SessionEntry, entries.items, {}, struct {
        fn lt(_: void, a: SessionEntry, b: SessionEntry) bool {
            return a.created_at_ms > b.created_at_ms;
        }
    }.lt);

    const ids = try arena.alloc([]const u8, entries.items.len);
    for (entries.items, 0..) |e, idx| ids[idx] = e.id;
    const id_len = shortestUniquePrefixLen(ids, 8);

    const header = try std.fmt.allocPrint(alloc, "{s: <[w]}  NAME             PROGRAM          STATUS     STARTED", .{ .s = "ID", .w = id_len });
    defer alloc.free(header);
    try printLine(header);

    for (entries.items) |e| {
        const now = std.time.milliTimestamp();
        const age_ms = now - e.created_at_ms;
        const age_str = try formatAge(alloc, age_ms);
        defer alloc.free(age_str);

        const short_id = if (e.id.len >= id_len) e.id[0..id_len] else e.id;
        const short_name = if (e.name.len > 16) e.name[0..16] else e.name;
        const short_program = if (e.program.len > 16) e.program[0..16] else e.program;

        const line = try std.fmt.allocPrint(alloc, "{s}  {s: <16} {s: <16} {s: <10} {s}", .{
            short_id,
            short_name,
            short_program,
            e.status,
            age_str,
        });
        defer alloc.free(line);
        try printLine(line);
    }
}

/// Walk the session log directory, parse each orphan log file's first
/// and last event, and append a synthetic entry for any id not already
/// seen. The arena owns the strings in the returned entries.
fn scanDiskSessions(
    arena: Allocator,
    entries: *std.ArrayListUnmanaged(SessionEntry),
    seen_ids: *std.StringHashMap(void),
) !void {
    const log_dir = resolveLogDirForClient(arena) catch return;

    var dir = std.fs.openDirAbsolute(log_dir, .{ .iterate = true }) catch return;
    defer dir.close();

    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".jsonl")) continue;
        const stem = entry.name[0 .. entry.name.len - ".jsonl".len];
        if (seen_ids.contains(stem)) continue;

        const path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ log_dir, entry.name });
        const file = std.fs.openFileAbsolute(path, .{}) catch continue;
        defer file.close();
        const bytes = file.readToEndAlloc(arena, 64 * 1024 * 1024) catch continue;

        const parsed_entry = parseLogFileForListing(arena, stem, bytes) orelse continue;
        try entries.append(arena, parsed_entry);
        try seen_ids.put(parsed_entry.id, {});
    }
}

/// Like resolveLogDir but never creates the directory — if it doesn't
/// exist, returns an error instead of trying to mkdir. Used by the list
/// disk scan where creating a log dir as a side effect of `hty list`
/// would be surprising.
fn resolveLogDirForClient(alloc: Allocator) ![]u8 {
    if (std.posix.getenv("XDG_STATE_HOME")) |state| {
        if (state.len > 0) {
            return std.fmt.allocPrint(alloc, "{s}/hty/logs", .{state});
        }
    }
    const home = std.posix.getenv("HOME") orelse return error.HomeNotSet;
    return std.fmt.allocPrint(alloc, "{s}/.local/state/hty/logs", .{home});
}

/// Build a SessionEntry from the contents of a log file. Reads the
/// first line (spawn event) for metadata and the last line for status.
fn parseLogFileForListing(arena: Allocator, stem: []const u8, bytes: []const u8) ?SessionEntry {
    if (bytes.len == 0) return null;

    const first_nl = std.mem.indexOfScalar(u8, bytes, '\n') orelse bytes.len;
    const first_line = bytes[0..first_nl];

    var first_parsed = std.json.parseFromSlice(std.json.Value, arena, first_line, .{}) catch return null;
    defer first_parsed.deinit();
    const first_obj = switch (first_parsed.value) {
        .object => |o| o,
        else => return null,
    };
    const program = getString(first_obj, "program") orelse "";
    const name = getString(first_obj, "name") orelse "";
    const created = getInteger(first_obj, "t") orelse 0;

    // Scan backward for the last non-empty line to determine status.
    var end = bytes.len;
    while (end > 0 and (bytes[end - 1] == '\n' or bytes[end - 1] == '\r')) end -= 1;
    var last_start = end;
    while (last_start > 0 and bytes[last_start - 1] != '\n') last_start -= 1;
    const last_line = if (end > last_start) bytes[last_start..end] else first_line;

    var last_parsed = std.json.parseFromSlice(std.json.Value, arena, last_line, .{}) catch return null;
    defer last_parsed.deinit();
    const last_obj = switch (last_parsed.value) {
        .object => |o| o,
        else => return null,
    };
    const last_kind = getString(last_obj, "kind") orelse "";
    const status: []const u8 = if (std.mem.eql(u8, last_kind, "exited"))
        "exited"
    else if (std.mem.eql(u8, last_kind, "killed"))
        "killed"
    else if (std.mem.eql(u8, last_kind, "failure"))
        "failed"
    else
        // No terminal event — session never finished cleanly. The server
        // either crashed mid-session or is a stale record from before an
        // abnormal shutdown. We can't know for sure so flag it.
        "stale";

    return SessionEntry{
        .id = arena.dupe(u8, stem) catch return null,
        .name = arena.dupe(u8, name) catch return null,
        .program = arena.dupe(u8, program) catch return null,
        .status = arena.dupe(u8, status) catch return null,
        .created_at_ms = created,
    };
}

/// Return the smallest prefix length at which every string in `ids` is unique,
/// clamped to [min_len, 36]. Used to size the ID column in `hty list` so that
/// UUIDv7 collisions within the same millisecond grow the display instead of
/// showing visually-duplicate rows.
fn shortestUniquePrefixLen(ids: []const []const u8, min_len: usize) usize {
    var len = min_len;
    while (len <= 36) : (len += 1) {
        var collision = false;
        for (ids, 0..) |a, i| {
            for (ids[i + 1 ..]) |b| {
                if (a.len >= len and b.len >= len and std.mem.eql(u8, a[0..len], b[0..len])) {
                    collision = true;
                    break;
                }
            }
            if (collision) break;
        }
        if (!collision) return len;
    }
    return 36;
}

fn formatAge(alloc: Allocator, age_ms: i64) ![]u8 {
    if (age_ms < 1000) return alloc.dupe(u8, "just now");
    const secs = @divFloor(age_ms, 1000);
    if (secs < 60) return std.fmt.allocPrint(alloc, "{d}s ago", .{secs});
    const mins = @divFloor(secs, 60);
    if (mins < 60) return std.fmt.allocPrint(alloc, "{d}m ago", .{mins});
    const hours = @divFloor(mins, 60);
    if (hours < 24) return std.fmt.allocPrint(alloc, "{d}h ago", .{hours});
    const days = @divFloor(hours, 24);
    return std.fmt.allocPrint(alloc, "{d}d ago", .{days});
}

fn getString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

fn runClientKill(alloc: Allocator, args: []const []const u8) !void {
    const session_ref = if (args.len > 0) args[0] else null;

    var payload_buf = std.array_list.Managed(u8).init(alloc);
    defer payload_buf.deinit();
    try payload_buf.appendSlice("{\"op\":\"kill\"");
    if (session_ref) |s| {
        try payload_buf.appendSlice(",\"session\":");
        try writeJsonString(payload_buf.writer().any(), s);
    }
    try payload_buf.appendSlice("}");

    const response_line = try sendRawRequest(alloc, payload_buf.items);
    defer alloc.free(response_line);

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, response_line, .{});
    defer parsed.deinit();
    _ = try expectOkOrExit(parsed);

    const display = session_ref orelse "session";
    const msg = try std.fmt.allocPrint(alloc, "killed {s} (record kept — `hty delete` to remove)", .{display});
    defer alloc.free(msg);
    try printLine(msg);
}

fn runClientDelete(alloc: Allocator, args: []const []const u8) !void {
    const session_ref = if (args.len > 0) args[0] else null;

    // First try the server — it owns any live or zombie sessions in the
    // current registry and will cleanly kill + unlink them.
    var payload_buf = std.array_list.Managed(u8).init(alloc);
    defer payload_buf.deinit();
    try payload_buf.appendSlice("{\"op\":\"delete\"");
    if (session_ref) |s| {
        try payload_buf.appendSlice(",\"session\":");
        try writeJsonString(payload_buf.writer().any(), s);
    }
    try payload_buf.appendSlice("}");

    var server_ok = false;
    if (sendRawRequest(alloc, payload_buf.items)) |response_line| {
        defer alloc.free(response_line);
        var parsed = std.json.parseFromSlice(std.json.Value, alloc, response_line, .{}) catch null;
        defer if (parsed) |*p| p.deinit();
        if (parsed) |*p| {
            if (p.value == .object) {
                if (p.value.object.get("ok")) |ok_val| {
                    if (ok_val == .bool and ok_val.bool) server_ok = true;
                }
            }
        }
    } else |_| {}

    if (server_ok) {
        const display = session_ref orelse "session";
        const msg = try std.fmt.allocPrint(alloc, "deleted {s}", .{display});
        defer alloc.free(msg);
        try printLine(msg);
        return;
    }

    // Server didn't know about it (orphan from a prior server instance,
    // or server unreachable). Unlink the log file and symlink directly.
    const ref = session_ref orelse {
        try printErr("hty delete: session not found");
        std.process.exit(ExitCode.not_found);
    };

    const path = resolveLogPath(alloc, ref) catch |err| {
        switch (err) {
            error.SessionNotFound => try printErr("hty delete: session not found"),
            error.AmbiguousPrefix => try printErr("hty delete: ambiguous session prefix"),
            error.AmbiguousSole => try printErr("hty delete: more than one session exists — name one explicitly"),
            else => try printErrFmt("hty delete: {s}", .{@errorName(err)}),
        }
        std.process.exit(ExitCode.not_found);
    };
    defer alloc.free(path);

    // `path` may be the by-name symlink or a direct UUID file. Resolve
    // it to the canonical UUID file so we can delete both it and the
    // symlink (if any) cleanly.
    const real_path = std.fs.realpathAlloc(alloc, path) catch try alloc.dupe(u8, path);
    defer alloc.free(real_path);

    std.fs.deleteFileAbsolute(real_path) catch |err| {
        try printErrFmt("hty delete: failed to unlink {s}: {s}", .{ real_path, @errorName(err) });
        std.process.exit(ExitCode.generic);
    };
    // Also remove the name symlink if the reference was a name.
    if (!std.mem.eql(u8, path, real_path)) {
        std.fs.deleteFileAbsolute(path) catch {};
    }

    const msg = try std.fmt.allocPrint(alloc, "deleted {s} (log file unlinked)", .{ref});
    defer alloc.free(msg);
    try printLine(msg);
}

fn runClientSend(alloc: Allocator, args: []const []const u8) !void {
    var session_ref: ?[]const u8 = null;
    var text: ?[]const u8 = null;
    var key: ?[]const u8 = null;
    var bytes_hex: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--text")) {
            i += 1;
            if (i >= args.len) return printUsageAndExit("--text requires a value");
            text = args[i];
        } else if (std.mem.eql(u8, arg, "--key")) {
            i += 1;
            if (i >= args.len) return printUsageAndExit("--key requires a value");
            key = args[i];
        } else if (std.mem.eql(u8, arg, "--bytes-hex")) {
            i += 1;
            if (i >= args.len) return printUsageAndExit("--bytes-hex requires a value");
            bytes_hex = args[i];
        } else if (std.mem.startsWith(u8, arg, "--")) {
            try printErrFmt("unknown flag: {s}", .{arg});
            std.process.exit(ExitCode.generic);
        } else if (session_ref == null) {
            session_ref = arg;
        } else {
            try printErrFmt("unexpected argument: {s}", .{arg});
            std.process.exit(ExitCode.generic);
        }
    }

    var op_count: u8 = 0;
    if (text != null) op_count += 1;
    if (key != null) op_count += 1;
    if (bytes_hex != null) op_count += 1;
    if (op_count != 1) {
        try printErr("hty send requires exactly one of --text, --key, --bytes-hex");
        std.process.exit(ExitCode.generic);
    }

    var payload_buf = std.array_list.Managed(u8).init(alloc);
    defer payload_buf.deinit();
    var writer = payload_buf.writer();

    if (text) |t| {
        try writer.writeAll("{\"op\":\"send_text\",\"text\":");
        try writeJsonString(writer.any(), t);
    } else if (key) |k| {
        try writer.writeAll("{\"op\":\"send_key\",\"key\":");
        try writeJsonString(writer.any(), k);
    } else if (bytes_hex) |b| {
        try writer.writeAll("{\"op\":\"send_bytes_hex\",\"bytes_hex\":");
        try writeJsonString(writer.any(), b);
    }

    if (session_ref) |s| {
        try writer.writeAll(",\"session\":");
        try writeJsonString(writer.any(), s);
    }
    try writer.writeAll("}");

    const response_line = try sendRawRequest(alloc, payload_buf.items);
    defer alloc.free(response_line);

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, response_line, .{});
    defer parsed.deinit();
    _ = try expectOkOrExit(parsed);
}

fn runClientSnapshot(alloc: Allocator, args: []const []const u8) !void {
    var session_ref: ?[]const u8 = null;
    var json_output = false;
    var ansi_output = false;

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--json")) {
            json_output = true;
        } else if (std.mem.eql(u8, arg, "--ansi")) {
            ansi_output = true;
        } else if (std.mem.startsWith(u8, arg, "--")) {
            try printErrFmt("unknown flag: {s}", .{arg});
            std.process.exit(ExitCode.generic);
        } else if (session_ref == null) {
            session_ref = arg;
        }
    }

    var payload_buf = std.array_list.Managed(u8).init(alloc);
    defer payload_buf.deinit();
    try payload_buf.appendSlice("{\"op\":\"snapshot\"");
    if (session_ref) |s| {
        try payload_buf.appendSlice(",\"session\":");
        try writeJsonString(payload_buf.writer().any(), s);
    }
    try payload_buf.appendSlice("}");

    const response_line = try sendRawRequest(alloc, payload_buf.items);
    defer alloc.free(response_line);

    if (json_output) {
        try printRaw(response_line);
        try printRaw("\n");
        return;
    }

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, response_line, .{});
    defer parsed.deinit();
    const object = try expectOkOrExit(parsed);

    const snap_val = object.get("snapshot") orelse return;
    const snap_obj = switch (snap_val) {
        .object => |o| o,
        else => return,
    };
    const field = if (ansi_output) "screen_ansi" else "buffer";
    const text = getString(snap_obj, field) orelse "";
    try printRaw(text);
    try printRaw("\n");
}

fn runClientWait(alloc: Allocator, args: []const []const u8) !void {
    var session_ref: ?[]const u8 = null;
    var wait_text: ?[]const u8 = null;
    var idle_ms: ?u64 = null;
    var wait_exit = false;
    var timeout_ms: u64 = 10_000;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--text")) {
            i += 1;
            if (i >= args.len) return printUsageAndExit("--text requires a value");
            wait_text = args[i];
        } else if (std.mem.eql(u8, arg, "--idle")) {
            i += 1;
            if (i >= args.len) return printUsageAndExit("--idle requires a value");
            idle_ms = try std.fmt.parseInt(u64, args[i], 10);
        } else if (std.mem.eql(u8, arg, "--exit")) {
            wait_exit = true;
        } else if (std.mem.eql(u8, arg, "--timeout")) {
            i += 1;
            if (i >= args.len) return printUsageAndExit("--timeout requires a value");
            timeout_ms = try std.fmt.parseInt(u64, args[i], 10);
        } else if (std.mem.startsWith(u8, arg, "--")) {
            try printErrFmt("unknown flag: {s}", .{arg});
            std.process.exit(ExitCode.generic);
        } else if (session_ref == null) {
            session_ref = arg;
        }
    }

    var modes: u8 = 0;
    if (wait_text != null) modes += 1;
    if (idle_ms != null) modes += 1;
    if (wait_exit) modes += 1;
    if (modes != 1) {
        try printErr("hty wait requires exactly one of --text, --idle, --exit");
        std.process.exit(ExitCode.generic);
    }

    var payload_buf = std.array_list.Managed(u8).init(alloc);
    defer payload_buf.deinit();
    var writer = payload_buf.writer();

    if (wait_text) |t| {
        try writer.print("{{\"op\":\"wait_for_text\",\"text\":", .{});
        try writeJsonString(writer.any(), t);
        try writer.print(",\"timeout_ms\":{d}", .{timeout_ms});
    } else if (idle_ms) |ms| {
        try writer.print("{{\"op\":\"wait_for_idle\",\"idle_ms\":{d},\"timeout_ms\":{d}", .{ ms, timeout_ms });
    } else {
        try writer.print("{{\"op\":\"wait_for_exit\",\"timeout_ms\":{d}", .{timeout_ms});
    }

    if (session_ref) |s| {
        try writer.writeAll(",\"session\":");
        try writeJsonString(writer.any(), s);
    }
    try writer.writeAll("}");

    const response_line = try sendRawRequest(alloc, payload_buf.items);
    defer alloc.free(response_line);

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, response_line, .{});
    defer parsed.deinit();
    const object = try expectOkOrExit(parsed);

    if (object.get("timed_out")) |to_val| {
        if (to_val == .bool and to_val.bool) {
            try printErr("timed out");
            std.process.exit(ExitCode.wait_timeout);
        }
    }
}

fn runClientWatch(alloc: Allocator, args: []const []const u8) !void {
    const session_ref: ?[]const u8 = if (args.len > 0 and !std.mem.startsWith(u8, args[0], "--")) args[0] else null;

    // Build a reusable request payload once.
    var payload_buf = std.array_list.Managed(u8).init(alloc);
    defer payload_buf.deinit();
    try payload_buf.appendSlice("{\"op\":\"snapshot\"");
    if (session_ref) |s| {
        try payload_buf.appendSlice(",\"session\":");
        try writeJsonString(payload_buf.writer().any(), s);
    }
    try payload_buf.appendSlice("}\n");
    const request_payload = payload_buf.items;

    // Setup: alt-screen, raw mode on stdin (for Ctrl-C detection). When stdin
    // isn't a TTY (e.g. piped or redirected), skip the raw-mode dance entirely.
    const stdin_fd = std.posix.STDIN_FILENO;
    const stdout_fd = std.posix.STDOUT_FILENO;
    const stdin_is_tty = std.posix.isatty(stdin_fd);

    // Register the process.exit defer FIRST so it runs LAST (defers are
    // LIFO). Otherwise it would fire before the alt-screen restore below
    // and std.process.exit would prevent the terminal cleanup from ever
    // running — the user gets stranded with vim's private modes still
    // active. The exit_code var is mutated later in the loop.
    var exit_code: u8 = ExitCode.ok;
    defer std.process.exit(exit_code);

    try enterAltScreen(stdout_fd);
    defer leaveAltScreen(stdout_fd);

    const saved_termios: ?std.posix.termios = if (stdin_is_tty)
        std.posix.tcgetattr(stdin_fd) catch null
    else
        null;
    if (saved_termios) |st| {
        var raw = st;
        raw.iflag.BRKINT = false;
        raw.iflag.ICRNL = false;
        raw.iflag.INPCK = false;
        raw.iflag.ISTRIP = false;
        raw.iflag.IXON = false;
        raw.lflag.ECHO = false;
        raw.lflag.ICANON = false;
        raw.lflag.IEXTEN = false;
        raw.lflag.ISIG = false;
        raw.cc[@intFromEnum(std.c.V.MIN)] = 0;
        raw.cc[@intFromEnum(std.c.V.TIME)] = 0;
        std.posix.tcsetattr(stdin_fd, .FLUSH, raw) catch {};
    }
    defer if (saved_termios) |st| std.posix.tcsetattr(stdin_fd, .FLUSH, st) catch {};

    const socket_path = try resolveSocketPath(alloc);
    defer alloc.free(socket_path);

    var input_buf: [32]u8 = undefined;

    while (true) {
        // Non-blocking check for Ctrl-C / Ctrl-Q — only meaningful when stdin
        // is a real terminal. Otherwise we rely on the session-exit path to
        // break out of the loop.
        if (stdin_is_tty) {
            var poll_fd: c.pollfd = .{
                .fd = stdin_fd,
                .events = c.POLLIN,
                .revents = 0,
            };
            if (c.poll(&poll_fd, 1, 0) > 0 and (poll_fd.revents & c.POLLIN) != 0) {
                const n = std.posix.read(stdin_fd, &input_buf) catch 0;
                for (input_buf[0..n]) |b| {
                    if (b == 0x03 or b == 0x11) return; // Ctrl-C or Ctrl-Q
                }
            }
        }

        // Connect and send snapshot request.
        var stream = ensureServer(alloc, socket_path, .{}) catch {
            break;
        };
        stream.writeAll(request_payload) catch {
            stream.close();
            break;
        };

        var resp_buf = std.array_list.Managed(u8).init(alloc);
        defer resp_buf.deinit();

        var chunk: [4096]u8 = undefined;
        while (true) {
            const n = stream.read(&chunk) catch 0;
            if (n == 0) break;
            resp_buf.appendSlice(chunk[0..n]) catch break;
            if (std.mem.indexOfScalar(u8, resp_buf.items, '\n') != null) break;
        }
        stream.close();

        const newline = std.mem.indexOfScalar(u8, resp_buf.items, '\n') orelse resp_buf.items.len;
        const line = resp_buf.items[0..newline];

        // Parse and paint.
        var parsed = std.json.parseFromSlice(std.json.Value, alloc, line, .{}) catch {
            std.Thread.sleep(50 * std.time.ns_per_ms);
            continue;
        };
        defer parsed.deinit();

        if (parsed.value != .object) {
            std.Thread.sleep(50 * std.time.ns_per_ms);
            continue;
        }
        const object = parsed.value.object;

        const ok = object.get("ok") orelse {
            std.Thread.sleep(50 * std.time.ns_per_ms);
            continue;
        };
        if (ok != .bool or !ok.bool) {
            // Treat the first ok=false as fatal — most likely the target
            // session doesn't exist, so mirror the exit code the `send` or
            // `kill` subcommands would return for the same situation.
            if (object.get("error")) |err_val| {
                if (err_val == .string) {
                    exit_code = errorToExitCode(err_val.string);
                }
            }
            if (exit_code == ExitCode.ok) exit_code = ExitCode.not_found;
            return;
        }

        const snap_val = object.get("snapshot") orelse {
            std.Thread.sleep(50 * std.time.ns_per_ms);
            continue;
        };
        const snap_obj = switch (snap_val) {
            .object => |o| o,
            else => {
                std.Thread.sleep(50 * std.time.ns_per_ms);
                continue;
            },
        };
        const screen_ansi = getString(snap_obj, "screen_ansi") orelse "";

        _ = std.posix.write(stdout_fd, "\x1b[H") catch {};
        _ = std.posix.write(stdout_fd, screen_ansi) catch {};

        // If the session has exited, paint the final frame once and bail.
        const status = getString(snap_obj, "status") orelse "running";
        if (!std.mem.eql(u8, status, "running")) {
            std.Thread.sleep(100 * std.time.ns_per_ms);
            return;
        }

        std.Thread.sleep(50 * std.time.ns_per_ms);
    }
}

// ============================================================================
// Terminal state helpers (shared by watch, replay, and attach)
// ============================================================================

/// Sequence to switch into the alt-screen, hide the cursor, clear, and home.
const alt_screen_enter = "\x1b[?1049h\x1b[?25l\x1b[2J\x1b[H";

/// Comprehensive restore sequence. Programs like vim enable a zoo of DEC
/// private modes (bracketed paste, mouse tracking, focus events,
/// application cursor keys, application keypad) and if we leave the
/// alt-screen without undoing them the user's terminal is stranded — Ctrl-K
/// and similar shortcuts stop working because the terminal is still in
/// mouse / app-keys mode. Reset all of them explicitly in addition to
/// exiting the alt-screen itself.
const alt_screen_exit =
    "\x1b[?1049l" ++ // exit alt screen
    "\x1b[?25h" ++ // show cursor
    "\x1b[0m" ++ // reset SGR
    "\x1b[?2004l" ++ // bracketed paste off
    "\x1b[?1004l" ++ // focus events off
    "\x1b[?1000l" ++ // mouse button tracking off
    "\x1b[?1002l" ++ // mouse motion tracking off
    "\x1b[?1006l" ++ // SGR mouse mode off
    "\x1b[?1l" ++ // cursor keys → normal
    "\x1b>" ++ // keypad → numeric
    "\x1b[?7h"; // autowrap back on

fn enterAltScreen(stdout_fd: std.posix.fd_t) !void {
    _ = try std.posix.write(stdout_fd, alt_screen_enter);
}

fn leaveAltScreen(stdout_fd: std.posix.fd_t) void {
    _ = std.posix.write(stdout_fd, alt_screen_exit) catch {};
}

// ============================================================================
// hty attach
// ============================================================================

/// Global SIGWINCH flag. The attach loop checks this each tick and emits
/// a resize frame when set. Atomic so the signal handler stays trivial.
var attach_resized = std.atomic.Value(bool).init(false);

fn attachSigwinchHandler(_: i32) callconv(.c) void {
    attach_resized.store(true, .release);
}

/// Shared state between the attach main thread and its reader thread.
/// The reader owns the socket read half; the main thread owns the write
/// half and the stdin loop.
const AttachClientState = struct {
    stream: std.net.Stream,
    done: std.atomic.Value(bool) = .init(false),
};

fn runClientAttach(alloc: Allocator, args: []const []const u8) !void {
    var session_ref: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.startsWith(u8, arg, "--")) {
            printUsageAndExit("unknown flag for `hty attach`");
        }
        if (session_ref != null) printUsageAndExit("only one session argument is allowed");
        session_ref = arg;
    }

    const stdin_fd = std.posix.STDIN_FILENO;
    const stdout_fd = std.posix.STDOUT_FILENO;
    const stdin_is_tty = std.posix.isatty(stdin_fd);

    // Read observer terminal dimensions so we can resize the PTY to match.
    var winsize = std.mem.zeroes(c.winsize);
    if (stdin_is_tty) {
        _ = c.ioctl(stdout_fd, c.TIOCGWINSZ, &winsize);
    }
    const init_rows: u16 = if (winsize.ws_row > 0) winsize.ws_row else 24;
    const init_cols: u16 = if (winsize.ws_col > 0) winsize.ws_col else 80;

    // Connect and issue the attach request before flipping the terminal
    // into raw mode so errors land on the user's normal terminal.
    const socket_path = try resolveSocketPath(alloc);
    defer alloc.free(socket_path);

    var stream = ensureServer(alloc, socket_path, .{}) catch {
        try printErr("hty attach: cannot connect to server");
        std.process.exit(ExitCode.generic);
    };

    var request_buf = std.array_list.Managed(u8).init(alloc);
    defer request_buf.deinit();
    try request_buf.appendSlice("{\"op\":\"attach\"");
    if (session_ref) |s| {
        try request_buf.appendSlice(",\"session\":");
        try writeJsonString(request_buf.writer().any(), s);
    }
    try request_buf.writer().any().print(",\"rows\":{d},\"cols\":{d}}}\n", .{ init_rows, init_cols });
    stream.writeAll(request_buf.items) catch {
        stream.close();
        try printErr("hty attach: failed to send attach request");
        std.process.exit(ExitCode.generic);
    };

    // Read the attach ack line before going into raw mode.
    var ack_buf = std.array_list.Managed(u8).init(alloc);
    defer ack_buf.deinit();
    var ack_chunk: [512]u8 = undefined;
    while (true) {
        const n = stream.read(&ack_chunk) catch {
            stream.close();
            try printErr("hty attach: server hung up before ack");
            std.process.exit(ExitCode.generic);
        };
        if (n == 0) {
            stream.close();
            try printErr("hty attach: server closed connection before ack");
            std.process.exit(ExitCode.generic);
        }
        try ack_buf.appendSlice(ack_chunk[0..n]);
        if (std.mem.indexOfScalar(u8, ack_buf.items, '\n') != null) break;
    }
    const nl = std.mem.indexOfScalar(u8, ack_buf.items, '\n').?;
    const ack_line = ack_buf.items[0..nl];
    {
        var parsed = std.json.parseFromSlice(std.json.Value, alloc, ack_line, .{}) catch {
            stream.close();
            try printErr("hty attach: malformed ack");
            std.process.exit(ExitCode.generic);
        };
        defer parsed.deinit();
        const obj = switch (parsed.value) {
            .object => |o| o,
            else => {
                stream.close();
                try printErr("hty attach: malformed ack");
                std.process.exit(ExitCode.generic);
            },
        };
        const ok = obj.get("ok") orelse {
            stream.close();
            try printErr("hty attach: ack missing ok field");
            std.process.exit(ExitCode.generic);
        };
        if (ok != .bool or !ok.bool) {
            const err_msg = if (obj.get("error")) |em| switch (em) {
                .string => em.string,
                else => "attach refused",
            } else "attach refused";
            stream.close();
            try printErrFmt("hty attach: {s}", .{err_msg});
            std.process.exit(ExitCode.not_found);
        }
    }

    // Any bytes that arrived on the socket after the ack's '\n' are early
    // output frames — feed them to the reader thread through a preload.
    const preload = if (nl + 1 < ack_buf.items.len)
        try alloc.dupe(u8, ack_buf.items[nl + 1 ..])
    else
        &[_]u8{};
    defer if (preload.len > 0) alloc.free(preload);

    // Setup alt-screen + raw mode.
    try enterAltScreen(stdout_fd);
    defer leaveAltScreen(stdout_fd);

    const saved_termios: ?std.posix.termios = if (stdin_is_tty)
        std.posix.tcgetattr(stdin_fd) catch null
    else
        null;
    if (saved_termios) |st| {
        var raw = st;
        raw.iflag.BRKINT = false;
        raw.iflag.ICRNL = false;
        raw.iflag.INPCK = false;
        raw.iflag.ISTRIP = false;
        raw.iflag.IXON = false;
        raw.lflag.ECHO = false;
        raw.lflag.ICANON = false;
        raw.lflag.IEXTEN = false;
        raw.lflag.ISIG = false;
        raw.cc[@intFromEnum(std.c.V.MIN)] = 0;
        raw.cc[@intFromEnum(std.c.V.TIME)] = 0;
        std.posix.tcsetattr(stdin_fd, .FLUSH, raw) catch {};
    }
    defer if (saved_termios) |st| std.posix.tcsetattr(stdin_fd, .FLUSH, st) catch {};

    // Install SIGWINCH handler so the PTY follows terminal resizes.
    var sa: std.posix.Sigaction = .{
        .handler = .{ .handler = attachSigwinchHandler },
        .mask = std.mem.zeroes(std.posix.sigset_t),
        .flags = 0,
    };
    std.posix.sigaction(std.c.SIG.WINCH, &sa, null);
    defer {
        var sa_reset: std.posix.Sigaction = .{
            .handler = .{ .handler = std.posix.SIG.DFL },
            .mask = std.mem.zeroes(std.posix.sigset_t),
            .flags = 0,
        };
        std.posix.sigaction(std.c.SIG.WINCH, &sa_reset, null);
    }

    // Shared state + reader thread.
    var shared = AttachClientState{ .stream = stream };
    const reader_thread = std.Thread.spawn(.{}, attachClientReaderLoop, .{ alloc, &shared, preload }) catch {
        stream.close();
        try printErr("hty attach: failed to spawn reader thread");
        std.process.exit(ExitCode.generic);
    };

    // Main loop: forward stdin into input frames with a Ctrl-A detach state
    // machine, watch for SIGWINCH to emit resize frames, and bail out if
    // the reader thread reports the session exited.
    var ctrl_a_pending = false;
    var input_buf: [4096]u8 = undefined;
    var cur_rows = init_rows;
    var cur_cols = init_cols;

    while (!shared.done.load(.acquire)) {
        // Propagate window-size changes.
        if (attach_resized.swap(false, .acq_rel)) {
            var ws = std.mem.zeroes(c.winsize);
            if (stdin_is_tty) _ = c.ioctl(stdout_fd, c.TIOCGWINSZ, &ws);
            const new_rows: u16 = if (ws.ws_row > 0) ws.ws_row else cur_rows;
            const new_cols: u16 = if (ws.ws_col > 0) ws.ws_col else cur_cols;
            if (new_rows != cur_rows or new_cols != cur_cols) {
                cur_rows = new_rows;
                cur_cols = new_cols;
                const frame = std.fmt.allocPrint(
                    alloc,
                    "{{\"op\":\"resize\",\"rows\":{d},\"cols\":{d}}}\n",
                    .{ new_rows, new_cols },
                ) catch continue;
                defer alloc.free(frame);
                stream.writeAll(frame) catch break;
            }
        }

        // Poll stdin with a short timeout so we wake often enough to
        // notice SIGWINCH flags and reader-thread exit.
        var pfd: c.pollfd = .{ .fd = stdin_fd, .events = c.POLLIN, .revents = 0 };
        const nr = c.poll(&pfd, 1, 25);
        if (nr <= 0) continue;
        if ((pfd.revents & c.POLLIN) == 0) continue;

        const n = std.posix.read(stdin_fd, &input_buf) catch break;
        if (n == 0) break;

        // Run the bytes through the detach state machine, accumulating any
        // pass-through bytes to send as a single input frame.
        var passthrough = std.array_list.Managed(u8).init(alloc);
        defer passthrough.deinit();
        var detach = false;
        for (input_buf[0..n]) |b| {
            if (ctrl_a_pending) {
                ctrl_a_pending = false;
                if (b == 'd') {
                    detach = true;
                    break;
                }
                if (b == 0x01) {
                    // Literal Ctrl-A.
                    passthrough.append(0x01) catch break;
                    continue;
                }
                // Unrecognized chord — forward Ctrl-A followed by the byte
                // so the session still sees both.
                passthrough.append(0x01) catch break;
                passthrough.append(b) catch break;
                continue;
            }
            if (b == 0x01) {
                ctrl_a_pending = true;
                continue;
            }
            passthrough.append(b) catch break;
        }

        if (passthrough.items.len > 0) {
            const hex = encodeHex(alloc, passthrough.items) catch continue;
            defer alloc.free(hex);
            const frame = std.fmt.allocPrint(
                alloc,
                "{{\"op\":\"input\",\"bytes_hex\":\"{s}\"}}\n",
                .{hex},
            ) catch continue;
            defer alloc.free(frame);
            stream.writeAll(frame) catch break;
        }

        if (detach) break;
    }

    // Signal the reader thread to wind down and join it.
    shared.done.store(true, .release);
    _ = stream.writeAll("{\"op\":\"detach\"}\n") catch {};
    std.posix.shutdown(stream.handle, .both) catch {};
    reader_thread.join();
    stream.close();
}

fn attachClientReaderLoop(alloc: Allocator, shared: *AttachClientState, preload: []const u8) void {
    defer shared.done.store(true, .release);

    const stdout_fd = std.posix.STDOUT_FILENO;
    var buffer = std.array_list.Managed(u8).init(alloc);
    defer buffer.deinit();

    if (preload.len > 0) {
        buffer.appendSlice(preload) catch return;
    }

    var chunk: [8192]u8 = undefined;
    while (!shared.done.load(.acquire)) {
        // Drain any complete lines already buffered.
        while (std.mem.indexOfScalar(u8, buffer.items, '\n')) |nl| {
            const line = buffer.items[0..nl];
            handleAttachServerFrame(alloc, shared, stdout_fd, line);
            const rest = buffer.items[nl + 1 ..];
            std.mem.copyForwards(u8, buffer.items[0..rest.len], rest);
            buffer.shrinkRetainingCapacity(rest.len);
        }

        if (shared.done.load(.acquire)) return;

        const n = shared.stream.read(&chunk) catch return;
        if (n == 0) return;
        buffer.appendSlice(chunk[0..n]) catch return;
    }
}

fn handleAttachServerFrame(
    alloc: Allocator,
    shared: *AttachClientState,
    stdout_fd: std.posix.fd_t,
    line: []const u8,
) void {
    if (std.mem.trim(u8, line, " \t\r").len == 0) return;

    var parsed = std.json.parseFromSlice(std.json.Value, alloc, line, .{}) catch return;
    defer parsed.deinit();

    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return,
    };

    const kind_val = obj.get("kind") orelse return;
    if (kind_val != .string) return;
    const kind = kind_val.string;

    if (std.mem.eql(u8, kind, "output")) {
        const hex_val = obj.get("bytes_hex") orelse return;
        if (hex_val != .string) return;
        const bytes = decodeHex(alloc, hex_val.string) catch return;
        defer alloc.free(bytes);
        _ = std.posix.write(stdout_fd, bytes) catch {};
        return;
    }

    if (std.mem.eql(u8, kind, "exited")) {
        shared.done.store(true, .release);
        return;
    }
}

// ============================================================================
// hty replay
// ============================================================================

const ReplayOptions = struct {
    session: ?[]const u8 = null,
    speed: f64 = 1.0,
    at_ms: ?u64 = null,
    to_ms: ?u64 = null,
    loop: bool = false,
};

const LoggedEvent = struct {
    t: i64,
    kind: []const u8,
    bytes: ?[]const u8 = null,
    rows: ?u16 = null,
    cols: ?u16 = null,
};

fn runClientReplay(alloc: Allocator, args: []const []const u8) !void {
    var opts = ReplayOptions{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--speed")) {
            i += 1;
            if (i >= args.len) printUsageAndExit("--speed requires an argument");
            opts.speed = std.fmt.parseFloat(f64, trimSpeedSuffix(args[i])) catch {
                printUsageAndExit("--speed must be a number (e.g. 1, 2x, 0.5)");
            };
            if (opts.speed <= 0) opts.speed = 0; // 0 = no sleep
        } else if (std.mem.eql(u8, arg, "--at")) {
            i += 1;
            if (i >= args.len) printUsageAndExit("--at requires an argument");
            opts.at_ms = parseDurationMs(args[i]) catch {
                printUsageAndExit("--at value is not a valid duration (examples: 5s, 1m, 500ms)");
            };
        } else if (std.mem.eql(u8, arg, "--to")) {
            i += 1;
            if (i >= args.len) printUsageAndExit("--to requires an argument");
            opts.to_ms = parseDurationMs(args[i]) catch {
                printUsageAndExit("--to value is not a valid duration");
            };
        } else if (std.mem.eql(u8, arg, "--loop")) {
            opts.loop = true;
        } else if (std.mem.startsWith(u8, arg, "--")) {
            printUsageAndExit("unknown flag for `hty replay`");
        } else {
            if (opts.session != null) printUsageAndExit("only one session argument is allowed");
            opts.session = arg;
        }
    }

    const path = resolveLogPath(alloc, opts.session) catch |err| {
        switch (err) {
            error.SessionNotFound => try printErr("session log not found"),
            error.AmbiguousPrefix => try printErr("ambiguous session prefix"),
            error.AmbiguousSole => try printErr("more than one session log exists — name one explicitly"),
            else => try printErrFmt("failed to resolve session log: {s}", .{@errorName(err)}),
        }
        std.process.exit(ExitCode.not_found);
    };
    defer alloc.free(path);

    const file = std.fs.openFileAbsolute(path, .{ .mode = .read_only }) catch |err| {
        try printErrFmt("cannot open {s}: {s}", .{ path, @errorName(err) });
        std.process.exit(ExitCode.generic);
    };
    defer file.close();

    const bytes = file.readToEndAlloc(alloc, 64 * 1024 * 1024) catch |err| {
        try printErrFmt("read failed: {s}", .{@errorName(err)});
        std.process.exit(ExitCode.generic);
    };
    defer alloc.free(bytes);

    // First pass: parse the spawn line for dimensions.
    var line_it = std.mem.splitScalar(u8, bytes, '\n');
    var rows: u16 = 24;
    var cols: u16 = 80;
    var first_t: ?i64 = null;
    const spawn_line = line_it.next() orelse {
        try printErr("log file is empty");
        std.process.exit(ExitCode.generic);
    };
    {
        var parsed = std.json.parseFromSlice(std.json.Value, alloc, spawn_line, .{}) catch {
            try printErr("log file is missing a valid spawn event on line 1");
            std.process.exit(ExitCode.generic);
        };
        defer parsed.deinit();
        if (parsed.value == .object) {
            const obj = parsed.value.object;
            if (getInteger(obj, "rows")) |r| rows = @intCast(r);
            if (getInteger(obj, "cols")) |c_| cols = @intCast(c_);
            if (getInteger(obj, "t")) |t| first_t = t;
        }
    }
    if (first_t == null) {
        try printErr("log file is missing a timestamp on line 1");
        std.process.exit(ExitCode.generic);
    }

    // Setup alt-screen + raw mode (so Ctrl-C leaves cleanly).
    const stdin_fd = std.posix.STDIN_FILENO;
    const stdout_fd = std.posix.STDOUT_FILENO;
    const stdin_is_tty = std.posix.isatty(stdin_fd);

    try enterAltScreen(stdout_fd);
    defer leaveAltScreen(stdout_fd);

    const saved_termios: ?std.posix.termios = if (stdin_is_tty)
        std.posix.tcgetattr(stdin_fd) catch null
    else
        null;
    if (saved_termios) |st| {
        var raw = st;
        raw.iflag.BRKINT = false;
        raw.iflag.ICRNL = false;
        raw.iflag.INPCK = false;
        raw.iflag.ISTRIP = false;
        raw.iflag.IXON = false;
        raw.lflag.ECHO = false;
        raw.lflag.ICANON = false;
        raw.lflag.IEXTEN = false;
        raw.lflag.ISIG = false;
        raw.cc[@intFromEnum(std.c.V.MIN)] = 0;
        raw.cc[@intFromEnum(std.c.V.TIME)] = 0;
        std.posix.tcsetattr(stdin_fd, .FLUSH, raw) catch {};
    }
    defer if (saved_termios) |st| std.posix.tcsetattr(stdin_fd, .FLUSH, st) catch {};

    replayLoop(alloc, bytes, rows, cols, first_t.?, opts) catch |err| {
        try printErrFmt("replay failed: {s}", .{@errorName(err)});
        std.process.exit(ExitCode.generic);
    };
}

fn replayLoop(
    alloc: Allocator,
    bytes: []const u8,
    initial_rows: u16,
    initial_cols: u16,
    first_t: i64,
    opts: ReplayOptions,
) !void {
    const stdin_fd = std.posix.STDIN_FILENO;
    const stdout_fd = std.posix.STDOUT_FILENO;

    const at_threshold: i64 = first_t + @as(i64, @intCast(opts.at_ms orelse 0));
    const to_threshold: ?i64 = if (opts.to_ms) |v| first_t + @as(i64, @intCast(v)) else null;

    while (true) {
        var terminal = try hty.ghostty_vt.Terminal.init(alloc, .{
            .cols = initial_cols,
            .rows = initial_rows,
            .max_scrollback = 10_000,
        });
        defer terminal.deinit(alloc);

        const handler = terminal.vtHandler();
        var stream = hty.ghostty_vt.TerminalStream.initAlloc(alloc, handler);
        defer stream.deinit();

        var cur_rows: u16 = initial_rows;
        var cur_cols: u16 = initial_cols;

        var prev_t: ?i64 = null;
        var it = std.mem.splitScalar(u8, bytes, '\n');
        // Skip the spawn line, already parsed.
        _ = it.next();

        _ = try std.posix.write(stdout_fd, "\x1b[2J\x1b[H");

        while (it.next()) |line| {
            if (line.len == 0) continue;

            if (checkCtrlCFromStdin(stdin_fd)) return;

            var parsed = std.json.parseFromSlice(std.json.Value, alloc, line, .{}) catch continue;
            defer parsed.deinit();
            if (parsed.value != .object) continue;
            const obj = parsed.value.object;

            const t = getInteger(obj, "t") orelse continue;
            if (to_threshold) |tt| if (t > tt) break;

            const kind_val = obj.get("kind") orelse continue;
            if (kind_val != .string) continue;
            const kind = kind_val.string;

            const past_at = t >= at_threshold;

            // Sleep between events (only once we're past --at, so we don't
            // wait real-time while fast-forwarding).
            if (past_at and prev_t != null and opts.speed > 0) {
                const dt_ms = t - prev_t.?;
                if (dt_ms > 0) {
                    const dt_ns = @as(u64, @intCast(dt_ms)) * std.time.ns_per_ms;
                    const scaled = @as(u64, @intFromFloat(@as(f64, @floatFromInt(dt_ns)) / opts.speed));
                    std.Thread.sleep(scaled);
                }
            }
            prev_t = t;

            if (std.mem.eql(u8, kind, "output")) {
                const hex = getString(obj, "bytes_hex") orelse continue;
                const decoded = decodeHex(alloc, hex) catch continue;
                defer alloc.free(decoded);
                stream.nextSlice(decoded);
                if (past_at) try paintFrame(alloc, &terminal, cur_rows, cur_cols);
            } else if (std.mem.eql(u8, kind, "resize")) {
                const nr = getInteger(obj, "rows") orelse continue;
                const nc = getInteger(obj, "cols") orelse continue;
                cur_rows = @intCast(nr);
                cur_cols = @intCast(nc);
                try terminal.resize(alloc, cur_cols, cur_rows);
                if (past_at) try paintFrame(alloc, &terminal, cur_rows, cur_cols);
            } else {
                // title, bell, input, killed, failure, exited: not visual.
            }
        }

        // End-of-log: without --loop, hold on the final frame until the
        // viewer hits Ctrl-C / Ctrl-Q. This matches the expectation that
        // replay is a post-mortem viewer, not a transient playback.
        if (!opts.loop) {
            while (true) {
                if (checkCtrlCFromStdin(stdin_fd)) return;
                std.Thread.sleep(50 * std.time.ns_per_ms);
            }
        }
        std.Thread.sleep(500 * std.time.ns_per_ms);
    }
}

fn paintFrame(alloc: Allocator, terminal: *hty.ghostty_vt.Terminal, rows: u16, cols: u16) !void {
    const frame = hty.renderScreenAnsi(alloc, terminal, rows, cols) catch return;
    defer alloc.free(frame);
    const stdout_fd = std.posix.STDOUT_FILENO;
    _ = std.posix.write(stdout_fd, "\x1b[H") catch return;
    _ = std.posix.write(stdout_fd, frame) catch return;
}

fn checkCtrlCFromStdin(stdin_fd: std.posix.fd_t) bool {
    var poll_fd: c.pollfd = .{ .fd = stdin_fd, .events = c.POLLIN, .revents = 0 };
    if (c.poll(&poll_fd, 1, 0) <= 0) return false;
    if ((poll_fd.revents & c.POLLIN) == 0) return false;
    var buf: [32]u8 = undefined;
    const n = std.posix.read(stdin_fd, &buf) catch return false;
    for (buf[0..n]) |b| {
        if (b == 0x03 or b == 0x11) return true;
    }
    return false;
}

fn trimSpeedSuffix(text: []const u8) []const u8 {
    if (text.len > 0 and (text[text.len - 1] == 'x' or text[text.len - 1] == 'X')) {
        return text[0 .. text.len - 1];
    }
    return text;
}

// ============================================================================
// hty logs
// ============================================================================

const LogsOptions = struct {
    session: ?[]const u8 = null,
    follow: bool = false,
    since_ms: ?u64 = null,
    json: bool = false,
};

fn runClientLogs(alloc: Allocator, args: []const []const u8) !void {
    var opts = LogsOptions{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--follow") or std.mem.eql(u8, arg, "-f")) {
            opts.follow = true;
        } else if (std.mem.eql(u8, arg, "--json")) {
            opts.json = true;
        } else if (std.mem.eql(u8, arg, "--since")) {
            i += 1;
            if (i >= args.len) printUsageAndExit("--since requires an argument");
            opts.since_ms = parseDurationMs(args[i]) catch {
                printUsageAndExit("--since value is not a valid duration (examples: 5s, 1m, 500ms, 30)");
            };
        } else if (std.mem.startsWith(u8, arg, "--")) {
            printUsageAndExit("unknown flag for `hty logs`");
        } else {
            if (opts.session != null) printUsageAndExit("only one session argument is allowed");
            opts.session = arg;
        }
    }

    const path = resolveLogPath(alloc, opts.session) catch |err| {
        switch (err) {
            error.SessionNotFound => try printErr("session log not found"),
            error.AmbiguousPrefix => try printErr("ambiguous session prefix"),
            error.AmbiguousSole => try printErr("more than one session log exists — name one explicitly"),
            else => try printErrFmt("failed to resolve session log: {s}", .{@errorName(err)}),
        }
        std.process.exit(ExitCode.not_found);
    };
    defer alloc.free(path);

    const file = std.fs.openFileAbsolute(path, .{ .mode = .read_only }) catch |err| {
        try printErrFmt("cannot open {s}: {s}", .{ path, @errorName(err) });
        std.process.exit(ExitCode.generic);
    };
    defer file.close();

    var buffered = std.array_list.Managed(u8).init(alloc);
    defer buffered.deinit();

    // Initial pass: read the whole file into memory. This keeps the filter
    // logic simple — we can't know the "last event timestamp" without seeing
    // every line, and even multi-megabyte logs are fine to load wholesale.
    const initial = file.readToEndAlloc(alloc, 64 * 1024 * 1024) catch |err| {
        try printErrFmt("read failed: {s}", .{@errorName(err)});
        std.process.exit(ExitCode.generic);
    };
    defer alloc.free(initial);

    const cutoff_ms: ?i64 = blk: {
        if (opts.since_ms) |since| {
            const last = lastTimestampInJsonl(initial) orelse break :blk null;
            break :blk last - @as(i64, @intCast(since));
        }
        break :blk null;
    };

    if (!opts.json) {
        try printLine("TIMESTAMP               KIND     DETAIL");
    }

    var file_pos: u64 = initial.len;
    try printJsonlLines(alloc, initial, cutoff_ms, opts.json);

    if (!opts.follow) return;

    // Follow loop: poll the file size and print new appended lines as they
    // appear. No inotify — append-only logs make size-watching sufficient.
    var leftover = std.array_list.Managed(u8).init(alloc);
    defer leftover.deinit();

    while (true) {
        const stat = file.stat() catch break;
        if (stat.size > file_pos) {
            try file.seekTo(file_pos);
            const remaining = stat.size - file_pos;
            const bytes = try alloc.alloc(u8, @intCast(remaining));
            defer alloc.free(bytes);
            const n = file.readAll(bytes) catch break;
            file_pos += @intCast(n);

            try leftover.appendSlice(bytes[0..n]);
            // Split on '\n' and print whole lines. Any trailing partial line
            // stays in `leftover` for the next iteration.
            var start: usize = 0;
            var idx: usize = 0;
            while (idx < leftover.items.len) : (idx += 1) {
                if (leftover.items[idx] == '\n') {
                    try printJsonlLine(alloc, leftover.items[start..idx], null, opts.json);
                    start = idx + 1;
                }
            }
            if (start > 0) {
                std.mem.copyForwards(u8, leftover.items[0..], leftover.items[start..]);
                leftover.shrinkRetainingCapacity(leftover.items.len - start);
            }
        }
        std.Thread.sleep(50 * std.time.ns_per_ms);
    }
}

fn printJsonlLines(alloc: Allocator, bytes: []const u8, cutoff_ms: ?i64, json_mode: bool) !void {
    var it = std.mem.splitScalar(u8, bytes, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        try printJsonlLine(alloc, line, cutoff_ms, json_mode);
    }
}

fn printJsonlLine(alloc: Allocator, line: []const u8, cutoff_ms: ?i64, json_mode: bool) !void {
    if (line.len == 0) return;

    var parsed = std.json.parseFromSlice(std.json.Value, alloc, line, .{}) catch {
        // Corrupt line — skip silently.
        return;
    };
    defer parsed.deinit();

    if (parsed.value != .object) return;
    const obj = parsed.value.object;
    const t = switch (obj.get("t") orelse return) {
        .integer => |v| v,
        else => return,
    };
    if (cutoff_ms) |cut| {
        if (t < cut) return;
    }

    if (json_mode) {
        try printLine(line);
        return;
    }

    try printFormattedEvent(alloc, obj, t);
}

fn printFormattedEvent(alloc: Allocator, obj: std.json.ObjectMap, t: i64) !void {
    var ts_buf: [32]u8 = undefined;
    const ts = formatLocalIsoMs(&ts_buf, t);

    const kind_val = obj.get("kind") orelse return;
    if (kind_val != .string) return;
    const kind = kind_val.string;

    const detail = try buildEventDetail(alloc, kind, obj);
    defer alloc.free(detail);

    const line = try std.fmt.allocPrint(alloc, "{s}  {s: <7}  {s}", .{ ts, kind, detail });
    defer alloc.free(line);
    try printLine(line);
}

fn buildEventDetail(alloc: Allocator, kind: []const u8, obj: std.json.ObjectMap) ![]u8 {
    if (std.mem.eql(u8, kind, "spawn")) {
        const program = getString(obj, "program") orelse "";
        const rows = getInteger(obj, "rows") orelse 0;
        const cols = getInteger(obj, "cols") orelse 0;
        var args_text = std.array_list.Managed(u8).init(alloc);
        defer args_text.deinit();
        if (obj.get("args")) |args_val| {
            if (args_val == .array) {
                for (args_val.array.items) |item| {
                    if (item == .string) {
                        try args_text.append(' ');
                        try args_text.appendSlice(item.string);
                    }
                }
            }
        }
        return try std.fmt.allocPrint(alloc, "{s}{s} ({d}x{d})", .{ program, args_text.items, rows, cols });
    }
    if (std.mem.eql(u8, kind, "input") or std.mem.eql(u8, kind, "output")) {
        const hex = getString(obj, "bytes_hex") orelse "";
        const nbytes = hex.len / 2;
        // For printable ASCII input, show the quoted string; else show hex.
        if (std.mem.eql(u8, kind, "input") and nbytes > 0 and nbytes <= 32) {
            var arena_state = std.heap.ArenaAllocator.init(alloc);
            defer arena_state.deinit();
            if (decodeHex(arena_state.allocator(), hex) catch null) |decoded| {
                if (isMostlyPrintable(decoded)) {
                    return try std.fmt.allocPrint(alloc, "{s} ({d} byte{s})", .{
                        try quoteForDisplay(alloc, decoded),
                        nbytes,
                        if (nbytes == 1) "" else "s",
                    });
                }
            }
        }
        const preview_len = @min(hex.len, 16);
        const preview = hex[0..preview_len];
        const ellipsis: []const u8 = if (hex.len > preview_len) "..." else "";
        return try std.fmt.allocPrint(alloc, "{s}{s} ({d} bytes)", .{ preview, ellipsis, nbytes });
    }
    if (std.mem.eql(u8, kind, "title")) {
        const title = getString(obj, "title") orelse "";
        return try std.fmt.allocPrint(alloc, "\"{s}\"", .{title});
    }
    if (std.mem.eql(u8, kind, "exited")) {
        const code = getInteger(obj, "code") orelse 0;
        return try std.fmt.allocPrint(alloc, "code={d}", .{code});
    }
    if (std.mem.eql(u8, kind, "failure")) {
        const message = getString(obj, "message") orelse "";
        return try std.fmt.allocPrint(alloc, "{s}", .{message});
    }
    // bell, killed, anything else: no detail.
    return try alloc.dupe(u8, "");
}

fn isMostlyPrintable(bytes: []const u8) bool {
    var printable: usize = 0;
    for (bytes) |b| {
        if ((b >= 0x20 and b < 0x7f) or b == '\n' or b == '\r' or b == '\t') printable += 1;
    }
    return printable * 4 >= bytes.len * 3;
}

fn quoteForDisplay(alloc: Allocator, bytes: []const u8) ![]u8 {
    var out = std.array_list.Managed(u8).init(alloc);
    errdefer out.deinit();
    try out.append('"');
    for (bytes) |b| {
        switch (b) {
            '\n' => try out.appendSlice("\\n"),
            '\r' => try out.appendSlice("\\r"),
            '\t' => try out.appendSlice("\\t"),
            '"' => try out.appendSlice("\\\""),
            '\\' => try out.appendSlice("\\\\"),
            else => if (b >= 0x20 and b < 0x7f) try out.append(b) else {
                var hex_buf: [4]u8 = undefined;
                const formatted = try std.fmt.bufPrint(&hex_buf, "\\x{x:0>2}", .{b});
                try out.appendSlice(formatted);
            },
        }
    }
    try out.append('"');
    return out.toOwnedSlice();
}

fn getInteger(obj: std.json.ObjectMap, key: []const u8) ?i64 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .integer => |i| i,
        else => null,
    };
}

fn lastTimestampInJsonl(bytes: []const u8) ?i64 {
    // Walk backwards to find the last non-empty line, parse its `t`.
    var end = bytes.len;
    while (end > 0 and bytes[end - 1] == '\n') end -= 1;
    if (end == 0) return null;
    var start = end;
    while (start > 0 and bytes[start - 1] != '\n') start -= 1;
    const line = bytes[start..end];
    // Minimal extraction: look for "t":N
    const needle = "\"t\":";
    const pos = std.mem.indexOf(u8, line, needle) orelse return null;
    var i = pos + needle.len;
    while (i < line.len and line[i] == ' ') i += 1;
    const num_start = i;
    while (i < line.len and (line[i] == '-' or (line[i] >= '0' and line[i] <= '9'))) i += 1;
    if (i == num_start) return null;
    return std.fmt.parseInt(i64, line[num_start..i], 10) catch null;
}

fn formatLocalIsoMs(buf: []u8, ms: i64) []const u8 {
    var t: c.time_t = @intCast(@divTrunc(ms, 1000));
    const tm_opt = c.localtime(&t);
    const millis: u32 = @intCast(@mod(ms, 1000));
    if (tm_opt) |tm_ptr| {
        const tm = tm_ptr.*;
        return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}", .{
            @as(u16, @intCast(tm.tm_year + 1900)),
            @as(u8, @intCast(tm.tm_mon + 1)),
            @as(u8, @intCast(tm.tm_mday)),
            @as(u8, @intCast(tm.tm_hour)),
            @as(u8, @intCast(tm.tm_min)),
            @as(u8, @intCast(tm.tm_sec)),
            millis,
        }) catch "????-??-??T??:??:??.???";
    }
    return std.fmt.bufPrint(buf, "{d}", .{ms}) catch "?";
}

fn parseDurationMs(text: []const u8) !u64 {
    if (text.len == 0) return error.InvalidDuration;
    var digit_end: usize = 0;
    while (digit_end < text.len and text[digit_end] >= '0' and text[digit_end] <= '9') digit_end += 1;
    if (digit_end == 0) return error.InvalidDuration;
    const n = try std.fmt.parseInt(u64, text[0..digit_end], 10);
    const suffix = text[digit_end..];
    if (suffix.len == 0) return n * 1000; // bare integer = seconds
    if (std.mem.eql(u8, suffix, "ms")) return n;
    if (std.mem.eql(u8, suffix, "s")) return n * 1000;
    if (std.mem.eql(u8, suffix, "m")) return n * 60 * 1000;
    if (std.mem.eql(u8, suffix, "h")) return n * 60 * 60 * 1000;
    return error.InvalidDuration;
}

fn resolveLogPath(alloc: Allocator, reference: ?[]const u8) ![]u8 {
    const log_dir = try resolveLogDir(alloc);
    defer alloc.free(log_dir);

    if (reference) |ref| {
        // 1. by-name symlink
        const name_path = try std.fmt.allocPrint(alloc, "{s}/by-name/{s}.jsonl", .{ log_dir, ref });
        if (fileExistsAbsolute(name_path)) return name_path;
        alloc.free(name_path);

        // 2. exact UUID
        const uuid_path = try std.fmt.allocPrint(alloc, "{s}/{s}.jsonl", .{ log_dir, ref });
        if (fileExistsAbsolute(uuid_path)) return uuid_path;
        alloc.free(uuid_path);

        // 3. prefix match
        var dir = try std.fs.openDirAbsolute(log_dir, .{ .iterate = true });
        defer dir.close();
        var it = dir.iterate();
        var match: ?[]u8 = null;
        errdefer if (match) |m| alloc.free(m);
        while (try it.next()) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".jsonl")) continue;
            const stem = entry.name[0 .. entry.name.len - ".jsonl".len];
            if (!std.mem.startsWith(u8, stem, ref)) continue;
            if (match != null) {
                alloc.free(match.?);
                match = null;
                return error.AmbiguousPrefix;
            }
            match = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ log_dir, entry.name });
        }
        if (match) |m| return m;
        return error.SessionNotFound;
    }

    // No reference: if exactly one .jsonl file exists, use it.
    var dir = try std.fs.openDirAbsolute(log_dir, .{ .iterate = true });
    defer dir.close();
    var it = dir.iterate();
    var sole: ?[]u8 = null;
    errdefer if (sole) |s| alloc.free(s);
    while (try it.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".jsonl")) continue;
        if (sole != null) {
            alloc.free(sole.?);
            sole = null;
            return error.AmbiguousSole;
        }
        sole = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ log_dir, entry.name });
    }
    if (sole) |s| return s;
    return error.SessionNotFound;
}

fn fileExistsAbsolute(path: []const u8) bool {
    std.fs.accessAbsolute(path, .{}) catch return false;
    return true;
}

// ============================================================================
// Misc helpers
// ============================================================================

fn printUsageAndExit(msg: []const u8) noreturn {
    printErr(msg) catch {};
    std.process.exit(ExitCode.generic);
}

fn encodeResponse(alloc: Allocator, response: Response) ![]u8 {
    const json = try std.json.Stringify.valueAlloc(alloc, response, .{});
    defer alloc.free(json);
    return std.fmt.allocPrint(alloc, "{s}\n", .{json});
}

fn requestErrorMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.SessionNotFound => "session not found",
        error.AmbiguousPrefix => "ambiguous session prefix; match is not unique",
        error.NameAlreadyExists => "a session with that name already exists — use `hty delete NAME` to free it",
        error.MissingField => "missing required field",
        error.InvalidFieldType => "invalid field type",
        error.InvalidFieldValue => "invalid field value",
        error.InvalidKey => "invalid key name; run `hty keys` for the list",
        error.InvalidHex => "invalid hex bytes; expected an even-length hexadecimal string",
        error.UnknownOperation => "unknown op",
        else => @errorName(err),
    };
}

// ============================================================================
// JSON field helpers (kept from pre-refactor)
// ============================================================================

fn readOptionalId(object: std.json.ObjectMap) ?i64 {
    const value = object.get("id") orelse return null;
    return switch (value) {
        .integer => |integer| integer,
        else => null,
    };
}

fn readRequiredString(object: std.json.ObjectMap, key: []const u8) ![]const u8 {
    const value = object.get(key) orelse return error.MissingField;
    return switch (value) {
        .string => |string| string,
        else => error.InvalidFieldType,
    };
}

fn readOptionalString(object: std.json.ObjectMap, key: []const u8) !?[]const u8 {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .null => null,
        .string => |string| string,
        else => error.InvalidFieldType,
    };
}

fn readOptionalBool(object: std.json.ObjectMap, key: []const u8, default: bool) !bool {
    const value = object.get(key) orelse return default;
    return switch (value) {
        .bool => |boolean| boolean,
        else => error.InvalidFieldType,
    };
}

fn readOptionalU64(object: std.json.ObjectMap, key: []const u8, default: u64) !u64 {
    const value = object.get(key) orelse return default;
    return switch (value) {
        .integer => |integer| {
            if (integer < 0) return error.InvalidFieldValue;
            return @intCast(integer);
        },
        else => error.InvalidFieldType,
    };
}

fn readOptionalUsize(object: std.json.ObjectMap, key: []const u8, default: usize) !usize {
    const value = object.get(key) orelse return default;
    return switch (value) {
        .integer => |integer| {
            if (integer < 0) return error.InvalidFieldValue;
            return @intCast(integer);
        },
        else => error.InvalidFieldType,
    };
}

fn readRequiredU16(object: std.json.ObjectMap, key: []const u8) !u16 {
    const value = object.get(key) orelse return error.MissingField;
    return toU16(value);
}

fn readOptionalU16(object: std.json.ObjectMap, key: []const u8, default: u16) !u16 {
    const value = object.get(key) orelse return default;
    return toU16(value);
}

fn toU16(value: std.json.Value) !u16 {
    return switch (value) {
        .integer => |integer| {
            if (integer < 0 or integer > std.math.maxInt(u16)) return error.InvalidFieldValue;
            return @intCast(integer);
        },
        else => error.InvalidFieldType,
    };
}

fn readStringArray(arena: Allocator, object: std.json.ObjectMap, key: []const u8) ![]const []const u8 {
    const value = object.get(key) orelse return &.{};
    const array = switch (value) {
        .array => |array| array,
        else => return error.InvalidFieldType,
    };

    const items = try arena.alloc([]const u8, array.items.len);
    for (array.items, 0..) |item, index| {
        items[index] = switch (item) {
            .string => |string| string,
            else => return error.InvalidFieldType,
        };
    }
    return items;
}

fn readEnvArray(arena: Allocator, object: std.json.ObjectMap, key: []const u8) ![]const hty.EnvVar {
    const value = object.get(key) orelse return &.{};

    return switch (value) {
        .object => |env_object| blk: {
            const items = try arena.alloc(hty.EnvVar, env_object.count());
            var iterator = env_object.iterator();
            var index: usize = 0;
            while (iterator.next()) |entry| : (index += 1) {
                items[index] = .{
                    .key = entry.key_ptr.*,
                    .value = switch (entry.value_ptr.*) {
                        .string => |string| string,
                        else => return error.InvalidFieldType,
                    },
                };
            }
            break :blk items;
        },
        .array => |env_array| blk: {
            const items = try arena.alloc(hty.EnvVar, env_array.items.len);
            for (env_array.items, 0..) |item, index| {
                const env_object = switch (item) {
                    .object => |env_object| env_object,
                    else => return error.InvalidFieldType,
                };
                items[index] = .{
                    .key = try readRequiredString(env_object, "key"),
                    .value = try readRequiredString(env_object, "value"),
                };
            }
            break :blk items;
        },
        else => error.InvalidFieldType,
    };
}

fn eventToPayload(arena: Allocator, event: hty.OutputEvent) !EventPayload {
    return switch (event) {
        .started => .{ .kind = "started" },
        .screen_update => .{ .kind = "screen_update" },
        .bell => .{ .kind = "bell" },
        .title_changed => |title| .{
            .kind = "title_changed",
            .title = try arena.dupe(u8, title),
        },
        .exited => |code| .{ .kind = "exited", .code = code },
        .failure => |message| .{
            .kind = "failure",
            .message = try arena.dupe(u8, message),
        },
        .raw_bytes => |bytes| .{
            .kind = "raw_bytes",
            .bytes_hex = try encodeHex(arena, bytes),
        },
    };
}

fn keyToBytes(arena: Allocator, key: []const u8) ![]const u8 {
    if (std.ascii.eqlIgnoreCase(key, "enter") or std.ascii.eqlIgnoreCase(key, "return")) return "\r";
    if (std.ascii.eqlIgnoreCase(key, "tab")) return "\t";
    if (std.ascii.eqlIgnoreCase(key, "esc") or std.ascii.eqlIgnoreCase(key, "escape")) return "\x1b";
    if (std.ascii.eqlIgnoreCase(key, "space")) return " ";
    if (std.ascii.eqlIgnoreCase(key, "backspace")) return "\x7f";
    if (std.ascii.eqlIgnoreCase(key, "up")) return "\x1b[A";
    if (std.ascii.eqlIgnoreCase(key, "down")) return "\x1b[B";
    if (std.ascii.eqlIgnoreCase(key, "right")) return "\x1b[C";
    if (std.ascii.eqlIgnoreCase(key, "left")) return "\x1b[D";
    if (std.ascii.eqlIgnoreCase(key, "home")) return "\x1b[H";
    if (std.ascii.eqlIgnoreCase(key, "end")) return "\x1b[F";
    if (std.ascii.eqlIgnoreCase(key, "pageup")) return "\x1b[5~";
    if (std.ascii.eqlIgnoreCase(key, "pagedown")) return "\x1b[6~";
    if (std.ascii.eqlIgnoreCase(key, "insert")) return "\x1b[2~";
    if (std.ascii.eqlIgnoreCase(key, "delete")) return "\x1b[3~";

    const ctrl_prefixes = [_][]const u8{ "ctrl-", "ctrl+", "c-" };
    for (ctrl_prefixes) |prefix| {
        if (startsWithIgnoreCase(key, prefix)) {
            const suffix = key[prefix.len..];
            if (suffix.len != 1) return error.InvalidKey;

            const char = std.ascii.toLower(suffix[0]);
            if (!std.ascii.isAlphanumeric(char) and char != '[' and char != '\\' and char != ']' and char != '^' and char != '_') {
                return error.InvalidKey;
            }

            const bytes = try arena.alloc(u8, 1);
            bytes[0] = char & 0x1f;
            return bytes;
        }
    }

    if (key.len == 1) return key;
    return error.InvalidKey;
}

fn startsWithIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    return std.ascii.eqlIgnoreCase(haystack[0..needle.len], needle);
}

fn encodeHex(arena: Allocator, bytes: []const u8) ![]const u8 {
    const out = try arena.alloc(u8, bytes.len * 2);
    const chars = "0123456789abcdef";
    for (bytes, 0..) |byte, index| {
        out[index * 2] = chars[byte >> 4];
        out[index * 2 + 1] = chars[byte & 0x0f];
    }
    return out;
}

fn decodeHex(arena: Allocator, text: []const u8) ![]const u8 {
    if (text.len % 2 != 0) return error.InvalidHex;

    const bytes = try arena.alloc(u8, text.len / 2);
    for (bytes, 0..) |*byte, index| {
        const hi = try fromHexNibble(text[index * 2]);
        const lo = try fromHexNibble(text[index * 2 + 1]);
        byte.* = (hi << 4) | lo;
    }
    return bytes;
}

fn fromHexNibble(ch: u8) !u8 {
    return switch (ch) {
        '0'...'9' => ch - '0',
        'a'...'f' => ch - 'a' + 10,
        'A'...'F' => ch - 'A' + 10,
        else => error.InvalidHex,
    };
}

// ============================================================================
// Help text
// ============================================================================

fn writeHelp(args: []const []const u8) !void {
    if (args.len == 0) {
        try printRaw(generalHelpText());
        return;
    }

    if (helpForTopic(args[0])) |help| {
        try printRaw(help);
        return;
    }

    const alloc = std.heap.c_allocator;
    const message = try std.fmt.allocPrint(alloc, "unknown help topic: {s}\n\n{s}", .{ args[0], generalHelpText() });
    defer alloc.free(message);
    try printRaw(message);
}

fn writeSupportedKeys() !void {
    try printRaw(supportedKeysText());
}

fn writeUsageError(arg: []const u8) !void {
    const alloc = std.heap.c_allocator;
    const message = try std.fmt.allocPrint(alloc, "unknown subcommand: {s}\n\n{s}", .{ arg, generalHelpText() });
    defer alloc.free(message);
    var stderr = std.fs.File.stderr();
    _ = try stderr.writeAll(message);
}

fn helpForTopic(topic: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, topic, "run")) return runHelpText();
    if (std.mem.eql(u8, topic, "list")) return listHelpText();
    if (std.mem.eql(u8, topic, "watch")) return watchHelpText();
    if (std.mem.eql(u8, topic, "send")) return sendHelpText();
    if (std.mem.eql(u8, topic, "snapshot")) return snapshotHelpText();
    if (std.mem.eql(u8, topic, "wait")) return waitHelpText();
    if (std.mem.eql(u8, topic, "kill")) return killHelpText();
    if (std.mem.eql(u8, topic, "delete")) return deleteHelpText();
    if (std.mem.eql(u8, topic, "logs")) return logsHelpText();
    if (std.mem.eql(u8, topic, "replay")) return replayHelpText();
    if (std.mem.eql(u8, topic, "attach")) return attachHelpText();
    if (std.mem.eql(u8, topic, "keys")) return supportedKeysText();
    return null;
}

fn generalHelpText() []const u8 {
    return
    \\Usage:
    \\  hty <command> [args...]
    \\
    \\Commands:
    \\  run       Start a new detached session in a fresh PTY
    \\  list      List running sessions
    \\  watch     Observe a session's rendered screen in real time (read-only)
    \\  send      Send text, a named key, or raw hex bytes to a session
    \\  snapshot  Read the current rendered screen of a session
    \\  wait      Block until the session matches a condition (text/idle/exit)
    \\  kill      Terminate a session's process (the record stays for replay)
    \\  delete    Permanently remove a session record and its log file
    \\  logs      Show the event log for a session (works after it has exited)
    \\  replay    Replay a recorded session by feeding its logged output back
    \\            through a fresh in-memory VT engine. No side effects.
    \\  attach    Interactively attach to a running session (bidirectional)
    \\  keys      Print supported symbolic key names for `hty send --key`
    \\  help      Print help. Pass a subcommand for details.
    \\
    \\Sessions are identified by a UUIDv7 (shown as its first 8 chars) or by a
    \\human-friendly `--name`. Any unambiguous prefix resolves to a full ID.
    \\If only one session is running, the session argument can be omitted.
    \\
    \\Examples:
    \\  hty run --name debug-vim -- vim /tmp/foo.txt
    \\  hty list
    \\  hty watch debug-vim
    \\  hty send debug-vim --text "ihello"
    \\  hty send debug-vim --key esc
    \\  hty wait debug-vim --idle 300 --timeout 2000
    \\  hty kill debug-vim
    \\
    ;
}

fn runHelpText() []const u8 {
    return
    \\hty run [--name NAME] [--rows N] [--cols N] [--cwd PATH] [--scrollback N] -- program [args...]
    \\
    \\Create a new session and start `program` inside a fresh PTY. The session
    \\is detached from your terminal; observe it with `hty watch` and drive it
    \\with `hty send`/`hty snapshot`/`hty wait`.
    \\
    \\Flags:
    \\  --name NAME       Human-friendly alias for the session. Must be unique.
    \\  --rows N          Initial row count (default 24)
    \\  --cols N          Initial column count (default 80)
    \\  --cwd PATH        Child's working directory
    \\  --scrollback N    Scrollback buffer size (default 10000)
    \\
    \\`-d` / `--detach` is accepted as a no-op — every `hty run` session is
    \\detached by default. Use `hty attach` for an interactive view.
    \\
    \\Example:
    \\  hty run --name debug-vim -- vim /tmp/foo.txt
    \\
    ;
}

fn listHelpText() []const u8 {
    return
    \\hty list [--json]
    \\
    \\List currently running sessions. Empty output if none.
    \\
    \\Flags:
    \\  --json   Emit the full structured response as JSON.
    \\
    ;
}

fn watchHelpText() []const u8 {
    return
    \\hty watch [SESSION]
    \\
    \\Attach to a session read-only and paint its rendered screen live to
    \\your terminal. Ctrl-C or Ctrl-Q to detach.
    \\
    \\SESSION may be a UUID prefix or the session's --name. If omitted and
    \\exactly one session is running, that one is used.
    \\
    ;
}

fn sendHelpText() []const u8 {
    return
    \\hty send [SESSION] --text "..." | --key NAME | --bytes-hex HEX
    \\
    \\Send input to a session. Exactly one of --text, --key, --bytes-hex is
    \\required.
    \\
    \\Flags:
    \\  --text STRING     UTF-8 text sent verbatim.
    \\  --key NAME        Named key. Run `hty keys` for the full list.
    \\  --bytes-hex HEX   Raw bytes encoded as hex.
    \\
    ;
}

fn snapshotHelpText() []const u8 {
    return
    \\hty snapshot [SESSION] [--ansi] [--json]
    \\
    \\Read the session's current rendered screen. Default output is plain
    \\text. Use --ansi to get the styled ANSI rendering, --json for the full
    \\structured response.
    \\
    ;
}

fn waitHelpText() []const u8 {
    return
    \\hty wait [SESSION] --text "..." | --idle MS | --exit [--timeout MS]
    \\
    \\Block until the session matches a condition. Exactly one mode flag is
    \\required. Exit 0 on match, 3 on timeout.
    \\
    \\Modes:
    \\  --text STRING   Wait until the rendered screen contains STRING.
    \\  --idle MS       Wait until the screen has been unchanged for MS
    \\                  milliseconds.
    \\  --exit          Wait until the child process exits.
    \\
    \\  --timeout MS    Max time to wait in milliseconds (default 10000).
    \\
    ;
}

fn killHelpText() []const u8 {
    return
    \\hty kill [SESSION]
    \\
    \\Terminate a session's underlying process. The session RECORD stays in
    \\place (same id, same name) so `hty list`, `hty logs` and `hty replay`
    \\keep working on it — use `hty delete` to free the name and remove the
    \\log file permanently.
    \\
    \\If SESSION is omitted and exactly one session is running, that one
    \\is killed.
    \\
    ;
}

fn deleteHelpText() []const u8 {
    return
    \\hty delete [SESSION]
    \\
    \\Permanently remove a session. If the child process is still running
    \\it's terminated first; the session's log file and by-name symlink
    \\are then unlinked from disk. After delete, the session's name is
    \\free to reuse.
    \\
    \\If SESSION is omitted and exactly one session is live, that one
    \\is deleted.
    \\
    ;
}

fn attachHelpText() []const u8 {
    return
    \\hty attach [SESSION]
    \\
    \\Interactively attach to a running session. Your terminal's keystrokes
    \\are forwarded into the PTY and the session's rendered output streams
    \\back — the same session an agent is driving can be taken over by a
    \\human (or multiple humans) at any time.
    \\
    \\Detach keybinds (tmux-style, Ctrl-A is the prefix):
    \\  Ctrl-A d      Detach cleanly.
    \\  Ctrl-A Ctrl-A Send a literal Ctrl-A to the session.
    \\
    \\The observer's terminal size is sent on attach and on SIGWINCH, so
    \\the child program sees the right LINES/COLUMNS.
    \\
    \\Multiple clients can attach to the same session simultaneously —
    \\writes are atomic per input frame, reads are broadcast to everyone.
    \\
    ;
}

fn replayHelpText() []const u8 {
    return
    \\hty replay [SESSION] [--speed Nx] [--at T] [--to T] [--loop]
    \\
    \\Replay a session by reading its log file and feeding the recorded
    \\output bytes back through a fresh in-memory VT engine. The program
    \\is NOT re-executed and no input is re-sent — replay is a pure
    \\visualization with zero side effects.
    \\
    \\Flags:
    \\  --speed Nx   Playback speed multiplier (default 1x). 0 = no sleep.
    \\  --at T       Fast-forward silently to T into the session before
    \\               painting (same duration syntax as --since).
    \\  --to T       Stop painting once the timeline reaches T.
    \\  --loop       Restart playback from the beginning when the log ends.
    \\
    \\Press Ctrl-C or Ctrl-Q to exit.
    \\
    ;
}

fn logsHelpText() []const u8 {
    return
    \\hty logs [SESSION] [--follow|-f] [--since DURATION] [--json]
    \\
    \\Print the JSONL event log for a session. Logs are read directly from
    \\disk, so this works for sessions that have already exited and even
    \\across server restarts.
    \\
    \\SESSION may be a --name, a full UUID, or any unambiguous prefix. If
    \\omitted and exactly one log file exists, that one is used.
    \\
    \\Flags:
    \\  --follow, -f     Tail the log as new events arrive.
    \\  --since DURATION Only show events within the last DURATION of logged
    \\                   activity. Accepts: 500ms, 5s, 1m, 2h, or a bare
    \\                   integer (seconds).
    \\  --json           Emit raw JSONL lines (one per event) instead of the
    \\                   human-readable table.
    \\
    \\Logs live at \$XDG_STATE_HOME/hty/logs (fallback ~/.local/state/hty/logs).
    \\
    ;
}

fn supportedKeysText() []const u8 {
    return
    \\Supported send_key names
    \\
    \\Navigation:
    \\  up, down, left, right, home, end, pageup, pagedown, insert, delete
    \\
    \\Editing and control:
    \\  enter, return, tab, esc, escape, space, backspace
    \\
    \\Ctrl chord syntax:
    \\  ctrl-x
    \\  ctrl-o
    \\  ctrl-[
    \\  c-a
    \\
    \\Single printable characters are also accepted directly:
    \\  "i"
    \\  ":"
    \\  "/"
    \\  "q"
    \\
    ;
}

// ============================================================================
// Entry point
// ============================================================================

pub fn main() !void {
    const alloc = std.heap.c_allocator;
    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);

    if (args.len < 2) {
        try printRaw(generalHelpText());
        return;
    }

    const verb = args[1];

    // Hidden server entry point.
    if (std.mem.eql(u8, verb, "__server__")) {
        if (args.len < 3) {
            try printErr("__server__ requires a socket path");
            std.process.exit(ExitCode.generic);
        }
        try runServer(alloc, args[2]);
        return;
    }

    if (std.mem.eql(u8, verb, "--help") or std.mem.eql(u8, verb, "-h") or std.mem.eql(u8, verb, "help")) {
        try writeHelp(args[2..]);
        return;
    }
    if (std.mem.eql(u8, verb, "keys")) {
        try writeSupportedKeys();
        return;
    }

    const subargs = args[2..];
    if (std.mem.eql(u8, verb, "run")) return runClientRun(alloc, subargs);
    if (std.mem.eql(u8, verb, "list")) return runClientList(alloc, subargs);
    if (std.mem.eql(u8, verb, "watch")) return runClientWatch(alloc, subargs);
    if (std.mem.eql(u8, verb, "send")) return runClientSend(alloc, subargs);
    if (std.mem.eql(u8, verb, "snapshot")) return runClientSnapshot(alloc, subargs);
    if (std.mem.eql(u8, verb, "wait")) return runClientWait(alloc, subargs);
    if (std.mem.eql(u8, verb, "kill")) return runClientKill(alloc, subargs);
    if (std.mem.eql(u8, verb, "delete")) return runClientDelete(alloc, subargs);
    if (std.mem.eql(u8, verb, "logs")) return runClientLogs(alloc, subargs);
    if (std.mem.eql(u8, verb, "replay")) return runClientReplay(alloc, subargs);
    if (std.mem.eql(u8, verb, "attach")) return runClientAttach(alloc, subargs);

    try writeUsageError(verb);
    std.process.exit(ExitCode.generic);
}

// ============================================================================
// Tests
// ============================================================================

test "key encoding covers arrows and control chords" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expectEqualStrings("\x1b[B", try keyToBytes(arena, "down"));
    try std.testing.expectEqualStrings("\r", try keyToBytes(arena, "enter"));
    try std.testing.expectEqualStrings("\x18", try keyToBytes(arena, "ctrl-x"));
    try std.testing.expectEqualStrings("\x01", try keyToBytes(arena, "c-a"));
}

test "help text lists all subcommands" {
    const general = generalHelpText();
    try std.testing.expect(std.mem.indexOf(u8, general, "run") != null);
    try std.testing.expect(std.mem.indexOf(u8, general, "list") != null);
    try std.testing.expect(std.mem.indexOf(u8, general, "watch") != null);
    try std.testing.expect(std.mem.indexOf(u8, general, "send") != null);
    try std.testing.expect(std.mem.indexOf(u8, general, "snapshot") != null);
    try std.testing.expect(std.mem.indexOf(u8, general, "wait") != null);
    try std.testing.expect(std.mem.indexOf(u8, general, "kill") != null);
    try std.testing.expect(std.mem.indexOf(u8, general, "logs") != null);
    try std.testing.expect(std.mem.indexOf(u8, general, "replay") != null);
    try std.testing.expect(std.mem.indexOf(u8, general, "attach") != null);
}

test "detectAttachOp recognizes attach requests" {
    const alloc = std.testing.allocator;
    try std.testing.expect(detectAttachOp(alloc, "{\"op\":\"attach\",\"session\":\"foo\"}"));
    try std.testing.expect(detectAttachOp(alloc, "{\"op\":\"attach\"}"));
    try std.testing.expect(!detectAttachOp(alloc, "{\"op\":\"snapshot\"}"));
    try std.testing.expect(!detectAttachOp(alloc, "{\"op\":\"spawn\",\"program\":\"/bin/sh\"}"));
    try std.testing.expect(!detectAttachOp(alloc, "not json"));
    try std.testing.expect(!detectAttachOp(alloc, "[\"attach\"]"));
}

test "parseDurationMs accepts bare integers, ms, s, m, h" {
    try std.testing.expectEqual(@as(u64, 5_000), try parseDurationMs("5"));
    try std.testing.expectEqual(@as(u64, 500), try parseDurationMs("500ms"));
    try std.testing.expectEqual(@as(u64, 10_000), try parseDurationMs("10s"));
    try std.testing.expectEqual(@as(u64, 60_000), try parseDurationMs("1m"));
    try std.testing.expectEqual(@as(u64, 2 * 60 * 60 * 1000), try parseDurationMs("2h"));
    try std.testing.expectError(error.InvalidDuration, parseDurationMs(""));
    try std.testing.expectError(error.InvalidDuration, parseDurationMs("abc"));
    try std.testing.expectError(error.InvalidDuration, parseDurationMs("5d"));
}

test "lastTimestampInJsonl finds the last t field" {
    const log =
        \\{"t":100,"kind":"spawn"}
        \\{"t":250,"kind":"output"}
        \\{"t":999,"kind":"exited"}
        \\
    ;
    try std.testing.expectEqual(@as(i64, 999), lastTimestampInJsonl(log).?);
}

test "lastTimestampInJsonl tolerates a trailing partial line" {
    const log =
        \\{"t":100,"kind":"spawn"}
        \\{"t":200,"kind":"output"}
    ;
    try std.testing.expectEqual(@as(i64, 200), lastTimestampInJsonl(log).?);
}

test "lastTimestampInJsonl returns null on empty input" {
    try std.testing.expect(lastTimestampInJsonl("") == null);
    try std.testing.expect(lastTimestampInJsonl("\n") == null);
}

test "isMostlyPrintable recognizes ascii" {
    try std.testing.expect(isMostlyPrintable("hello"));
    try std.testing.expect(isMostlyPrintable("hi there\n"));
    try std.testing.expect(!isMostlyPrintable("\x00\x01\x02"));
}

test "quoteForDisplay escapes unusual bytes" {
    const out = try quoteForDisplay(std.testing.allocator, "hi\n\ta");
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("\"hi\\n\\ta\"", out);
}

test "trimSpeedSuffix strips trailing x" {
    try std.testing.expectEqualStrings("2", trimSpeedSuffix("2x"));
    try std.testing.expectEqualStrings("0.5", trimSpeedSuffix("0.5X"));
    try std.testing.expectEqualStrings("1", trimSpeedSuffix("1"));
}

test "uuidv7 is well-formed" {
    var id: [36]u8 = undefined;
    generateUuidV7(&id);

    try std.testing.expectEqual(@as(u8, '-'), id[8]);
    try std.testing.expectEqual(@as(u8, '-'), id[13]);
    try std.testing.expectEqual(@as(u8, '-'), id[18]);
    try std.testing.expectEqual(@as(u8, '-'), id[23]);
    try std.testing.expectEqual(@as(u8, '7'), id[14]); // version

    // Variant nibble (high nibble of byte 8 in string form = id[19]).
    const variant = id[19];
    try std.testing.expect(variant == '8' or variant == '9' or variant == 'a' or variant == 'b');
}

test "uuidv7 is unique across calls" {
    var a: [36]u8 = undefined;
    var b: [36]u8 = undefined;
    generateUuidV7(&a);
    generateUuidV7(&b);
    try std.testing.expect(!std.mem.eql(u8, &a, &b));
}

test "shortestUniquePrefixLen grows past collisions" {
    // All unique at 8.
    {
        const ids = [_][]const u8{ "aaaaaaaaxxxx", "bbbbbbbbyyyy" };
        try std.testing.expectEqual(@as(usize, 8), shortestUniquePrefixLen(&ids, 8));
    }
    // Share 8 but differ at 9.
    {
        const ids = [_][]const u8{ "01860f08a000", "01860f08b000" };
        try std.testing.expectEqual(@as(usize, 9), shortestUniquePrefixLen(&ids, 8));
    }
    // Share first 11 chars (01860f08aa0), differ at index 11.
    {
        const ids = [_][]const u8{ "01860f08aa01", "01860f08aa02" };
        try std.testing.expectEqual(@as(usize, 12), shortestUniquePrefixLen(&ids, 8));
    }
    // Single session: min_len wins.
    {
        const ids = [_][]const u8{"01860f08abcdefgh"};
        try std.testing.expectEqual(@as(usize, 8), shortestUniquePrefixLen(&ids, 8));
    }
}

test "joinArgs handles empty, single, multi" {
    const empty_result = try joinArgs(std.testing.allocator, &.{});
    defer std.testing.allocator.free(empty_result);
    try std.testing.expectEqualStrings("", empty_result);

    const single_result = try joinArgs(std.testing.allocator, &.{"foo"});
    defer std.testing.allocator.free(single_result);
    try std.testing.expectEqualStrings("foo", single_result);

    const multi_result = try joinArgs(std.testing.allocator, &.{ "foo", "bar baz", "qux" });
    defer std.testing.allocator.free(multi_result);
    try std.testing.expectEqualStrings("foo bar baz qux", multi_result);
}

// ============================================================================
// Integration test helpers (drive the in-process dispatch without sockets)
// ============================================================================

fn testRequest(
    registry: *SessionRegistry,
    value: anytype,
) !std.json.Parsed(std.json.Value) {
    const alloc = std.testing.allocator;
    const request_line = try std.json.Stringify.valueAlloc(alloc, value, .{});
    defer alloc.free(request_line);

    const response_line = try processRequestLine(alloc, registry, request_line);
    defer alloc.free(response_line);

    const newline = std.mem.indexOfScalar(u8, response_line, '\n') orelse response_line.len;
    return std.json.parseFromSlice(std.json.Value, alloc, response_line[0..newline], .{});
}

fn expectTestOk(parsed: std.json.Parsed(std.json.Value)) !std.json.ObjectMap {
    const object = switch (parsed.value) {
        .object => |o| o,
        else => return error.InvalidResponse,
    };

    const ok = object.get("ok") orelse return error.InvalidResponse;
    switch (ok) {
        .bool => |v| if (!v) {
            if (object.get("error")) |err_val| {
                if (err_val == .string) {
                    std.debug.print("request failed: {s}\n", .{err_val.string});
                }
            }
            return error.ResponseNotOk;
        },
        else => return error.InvalidResponse,
    }
    return object;
}

fn commandExists(path: []const u8) bool {
    std.fs.accessAbsolute(path, .{}) catch return false;
    return true;
}

test "unknown operation returns actionable error" {
    var registry = SessionRegistry.init(std.testing.allocator);
    defer registry.deinit();

    var parsed = try testRequest(&registry, .{ .op = "bogus" });
    defer parsed.deinit();

    const object = switch (parsed.value) {
        .object => |o| o,
        else => return error.InvalidResponse,
    };
    const ok = object.get("ok") orelse return error.InvalidResponse;
    try std.testing.expectEqual(false, ok.bool);
    const message = object.get("error") orelse return error.InvalidResponse;
    try std.testing.expect(message == .string);
    try std.testing.expect(std.mem.indexOf(u8, message.string, "unknown op") != null);
}

test "list op returns empty array on a fresh registry" {
    var registry = SessionRegistry.init(std.testing.allocator);
    defer registry.deinit();

    var parsed = try testRequest(&registry, .{ .op = "list" });
    defer parsed.deinit();
    const object = try expectTestOk(parsed);

    const sessions = object.get("sessions") orelse return error.InvalidResponse;
    try std.testing.expect(sessions == .array);
    try std.testing.expectEqual(@as(usize, 0), sessions.array.items.len);
}

test "name collision is rejected" {
    var registry = SessionRegistry.init(std.testing.allocator);
    defer registry.deinit();

    {
        var parsed = try testRequest(&registry, .{
            .op = "spawn",
            .name = "dup",
            .program = "/bin/cat",
            .rows = 10,
            .cols = 40,
            .emit_raw_bytes = false,
        });
        defer parsed.deinit();
        _ = try expectTestOk(parsed);
    }
    {
        var parsed = try testRequest(&registry, .{
            .op = "spawn",
            .name = "dup",
            .program = "/bin/cat",
            .rows = 10,
            .cols = 40,
            .emit_raw_bytes = false,
        });
        defer parsed.deinit();
        const object = switch (parsed.value) {
            .object => |o| o,
            else => return error.InvalidResponse,
        };
        const ok = object.get("ok") orelse return error.InvalidResponse;
        try std.testing.expectEqual(false, ok.bool);
    }
    {
        var parsed = try testRequest(&registry, .{
            .op = "kill",
            .session = "dup",
        });
        defer parsed.deinit();
        _ = try expectTestOk(parsed);
    }
}

test "headless protocol can drive cat and snapshot echoed text" {
    var registry = SessionRegistry.init(std.testing.allocator);
    defer registry.deinit();

    {
        var parsed = try testRequest(&registry, .{
            .op = "spawn",
            .name = "cat",
            .program = "/bin/cat",
            .rows = 12,
            .cols = 50,
            .emit_raw_bytes = false,
        });
        defer parsed.deinit();
        _ = try expectTestOk(parsed);
    }

    {
        var parsed = try testRequest(&registry, .{
            .op = "send_text",
            .session = "cat",
            .text = "hello from headless\n",
        });
        defer parsed.deinit();
        _ = try expectTestOk(parsed);
    }

    {
        var parsed = try testRequest(&registry, .{
            .op = "wait_for_text",
            .session = "cat",
            .text = "hello from headless",
            .timeout_ms = 2_000,
        });
        defer parsed.deinit();
        const object = try expectTestOk(parsed);
        const snapshot = object.get("snapshot") orelse return error.InvalidResponse;
        const snapshot_object = switch (snapshot) {
            .object => |o| o,
            else => return error.InvalidResponse,
        };
        const buffer = snapshot_object.get("buffer") orelse return error.InvalidResponse;
        try std.testing.expect(buffer == .string);
        try std.testing.expect(std.mem.indexOf(u8, buffer.string, "hello from headless") != null);

        const screen_ansi = snapshot_object.get("screen_ansi") orelse return error.InvalidResponse;
        try std.testing.expect(screen_ansi == .string);
        try std.testing.expect(std.mem.indexOf(u8, screen_ansi.string, "hello from headless") != null);
        try std.testing.expect(std.mem.indexOf(u8, screen_ansi.string, "\x1b[") != null);
    }

    {
        var parsed = try testRequest(&registry, .{ .op = "kill", .session = "cat" });
        defer parsed.deinit();
        _ = try expectTestOk(parsed);
    }
}

test "session event log records spawn, input, output, killed" {
    const alloc = std.testing.allocator;

    // Make a temp log dir under /tmp so the test is self-contained and doesn't
    // pollute ~/.local/state/hty/logs.
    var log_dir_buf: [256]u8 = undefined;
    const log_dir = try std.fmt.bufPrint(
        &log_dir_buf,
        "/tmp/hty-log-test-{d}",
        .{std.time.nanoTimestamp()},
    );
    try std.fs.cwd().makePath(log_dir);
    defer std.fs.cwd().deleteTree(log_dir) catch {};
    const by_name = try std.fmt.allocPrint(alloc, "{s}/by-name", .{log_dir});
    defer alloc.free(by_name);
    try std.fs.cwd().makePath(by_name);

    var registry = SessionRegistry.init(alloc);
    defer registry.deinit();
    registry.log_dir = log_dir;

    {
        var parsed = try testRequest(&registry, .{
            .op = "spawn",
            .name = "logcat",
            .program = "/bin/cat",
            .rows = 8,
            .cols = 24,
        });
        defer parsed.deinit();
        _ = try expectTestOk(parsed);
    }
    {
        var parsed = try testRequest(&registry, .{
            .op = "send_text",
            .session = "logcat",
            .text = "hi\n",
        });
        defer parsed.deinit();
        _ = try expectTestOk(parsed);
    }
    {
        var parsed = try testRequest(&registry, .{
            .op = "wait_for_text",
            .session = "logcat",
            .text = "hi",
            .timeout_ms = 2_000,
        });
        defer parsed.deinit();
        _ = try expectTestOk(parsed);
    }
    {
        var parsed = try testRequest(&registry, .{ .op = "kill", .session = "logcat" });
        defer parsed.deinit();
        _ = try expectTestOk(parsed);
    }

    // Read the log file via the by-name symlink.
    const link_path = try std.fmt.allocPrint(alloc, "{s}/logcat.jsonl", .{by_name});
    defer alloc.free(link_path);

    const file = try std.fs.openFileAbsolute(link_path, .{});
    defer file.close();
    const contents = try file.readToEndAlloc(alloc, 1024 * 1024);
    defer alloc.free(contents);

    try std.testing.expect(std.mem.indexOf(u8, contents, "\"kind\":\"spawn\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "\"kind\":\"input\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "\"kind\":\"output\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "\"kind\":\"killed\"") != null);

    // Timestamps should be monotonically non-decreasing.
    var line_it = std.mem.splitScalar(u8, contents, '\n');
    var prev: i64 = 0;
    while (line_it.next()) |line| {
        if (line.len == 0) continue;
        const pos = std.mem.indexOf(u8, line, "\"t\":") orelse continue;
        var i = pos + 4;
        const num_start = i;
        while (i < line.len and line[i] >= '0' and line[i] <= '9') i += 1;
        if (i == num_start) continue;
        const t = try std.fmt.parseInt(i64, line[num_start..i], 10);
        try std.testing.expect(t >= prev);
        prev = t;
    }
}

test "headless protocol can use nano to write a file" {
    if (!commandExists("/usr/bin/nano")) return error.SkipZigTest;

    var registry = SessionRegistry.init(std.testing.allocator);
    defer registry.deinit();

    const path = try std.fmt.allocPrint(std.testing.allocator, "/tmp/hty-nano-{d}.txt", .{std.time.nanoTimestamp()});
    defer std.testing.allocator.free(path);
    std.fs.deleteFileAbsolute(path) catch {};
    defer std.fs.deleteFileAbsolute(path) catch {};

    {
        var parsed = try testRequest(&registry, .{
            .op = "spawn",
            .name = "nano",
            .program = "/usr/bin/nano",
            .args = [_][]const u8{path},
            .rows = 24,
            .cols = 80,
            .emit_raw_bytes = false,
        });
        defer parsed.deinit();
        _ = try expectTestOk(parsed);
    }

    // Wait for nano's UI to draw.
    {
        var parsed = try testRequest(&registry, .{
            .op = "wait_for_idle",
            .session = "nano",
            .idle_ms = 300,
            .timeout_ms = 5_000,
        });
        defer parsed.deinit();
        _ = try expectTestOk(parsed);
    }

    {
        var parsed = try testRequest(&registry, .{
            .op = "send_text",
            .session = "nano",
            .text = "hello from hty",
        });
        defer parsed.deinit();
        _ = try expectTestOk(parsed);
    }
    {
        var parsed = try testRequest(&registry, .{
            .op = "send_key",
            .session = "nano",
            .key = "enter",
        });
        defer parsed.deinit();
        _ = try expectTestOk(parsed);
    }
    {
        var parsed = try testRequest(&registry, .{
            .op = "send_text",
            .session = "nano",
            .text = "written through nano",
        });
        defer parsed.deinit();
        _ = try expectTestOk(parsed);
    }
    {
        var parsed = try testRequest(&registry, .{
            .op = "send_key",
            .session = "nano",
            .key = "ctrl-o",
        });
        defer parsed.deinit();
        _ = try expectTestOk(parsed);
    }
    {
        var parsed = try testRequest(&registry, .{
            .op = "send_key",
            .session = "nano",
            .key = "enter",
        });
        defer parsed.deinit();
        _ = try expectTestOk(parsed);
    }
    {
        var parsed = try testRequest(&registry, .{
            .op = "send_key",
            .session = "nano",
            .key = "ctrl-x",
        });
        defer parsed.deinit();
        _ = try expectTestOk(parsed);
    }

    // Wait for nano to exit.
    {
        var parsed = try testRequest(&registry, .{
            .op = "wait_for_exit",
            .session = "nano",
            .timeout_ms = 5_000,
        });
        defer parsed.deinit();
        _ = try expectTestOk(parsed);
    }

    const file = try std.fs.openFileAbsolute(path, .{});
    defer file.close();
    const contents = try file.readToEndAlloc(std.testing.allocator, 4096);
    defer std.testing.allocator.free(contents);
    try std.testing.expect(std.mem.indexOf(u8, contents, "hello from hty") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "written through nano") != null);
}

test "headless protocol can launch top and quit" {
    if (!commandExists("/usr/bin/top")) return error.SkipZigTest;

    var registry = SessionRegistry.init(std.testing.allocator);
    defer registry.deinit();

    {
        var parsed = try testRequest(&registry, .{
            .op = "spawn",
            .name = "top",
            .program = "/usr/bin/top",
            .rows = 20,
            .cols = 80,
            .emit_raw_bytes = false,
        });
        defer parsed.deinit();
        _ = try expectTestOk(parsed);
    }

    // Let top draw its initial UI.
    {
        var parsed = try testRequest(&registry, .{
            .op = "wait_for_idle",
            .session = "top",
            .idle_ms = 500,
            .timeout_ms = 5_000,
        });
        defer parsed.deinit();
        _ = try expectTestOk(parsed);
    }

    {
        var parsed = try testRequest(&registry, .{
            .op = "send_text",
            .session = "top",
            .text = "q",
        });
        defer parsed.deinit();
        _ = try expectTestOk(parsed);
    }

    {
        var parsed = try testRequest(&registry, .{
            .op = "wait_for_exit",
            .session = "top",
            .timeout_ms = 5_000,
        });
        defer parsed.deinit();
        _ = try expectTestOk(parsed);
    }
}
