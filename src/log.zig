//! Session event logging. Every live session optionally owns a `log_file`
//! handle into `$XDG_STATE_HOME/hty/logs/<uuid>.jsonl`; this module appends
//! one JSONL event per input, output, resize, title change, bell, exit,
//! failure, or kill.
//!
//! All write helpers are best-effort and silent on failure — a wedged log
//! file should never propagate into session state. The replay code at
//! `headless.zig` is responsible for tolerating malformed/truncated lines.

const std = @import("std");
const hty = @import("hty");
const session_mod = @import("session.zig");
const hex_mod = @import("hex.zig");
const json_mod = @import("json.zig");

const Allocator = std.mem.Allocator;
const Session = session_mod.Session;
const getString = json_mod.getString;

/// Append one JSONL line (no trailing newline on input) to the session's log
/// file, followed by '\n'. Silent no-op if the session has no log file.
///
/// Takes `sess.log_mutex` so records from concurrent writers (drain thread,
/// attach reader thread, RPC worker threads) don't interleave mid-line. The
/// two `writeAll` calls underneath are not atomic at the syscall level —
/// without the mutex, a big record could have another thread's newline
/// injected between its payload and its terminator.
pub fn writeLogEvent(sess: *Session, line: []const u8) void {
    sess.log_mutex.lock();
    defer sess.log_mutex.unlock();
    writeLogEventLocked(sess, line);
}

/// Caller must hold `sess.log_mutex`. Used when a caller already holds the
/// lock for a compound operation (e.g. `openSessionLog` — install the file
/// handle and write the spawn line atomically with respect to drain events).
fn writeLogEventLocked(sess: *Session, line: []const u8) void {
    const log_file = sess.log_file orelse return;
    log_file.writeAll(line) catch return;
    log_file.writeAll("\n") catch return;
}

pub fn closeLogFile(sess: *Session) void {
    sess.log_mutex.lock();
    defer sess.log_mutex.unlock();
    if (sess.log_file) |*f| {
        f.close();
        sess.log_file = null;
    }
}

/// Open the log file for a freshly-created session and write the spawn event.
/// Best-effort: on failure, logs a warning and leaves sess.log_file null.
/// `log_dir` may be null (e.g. from unit tests) in which case the call is a
/// silent no-op.
pub fn openSessionLog(
    arena: Allocator,
    log_dir: ?[]const u8,
    sess: *Session,
    program: []const u8,
    args: []const []const u8,
    rows: u16,
    cols: u16,
) void {
    const dir = log_dir orelse return;

    const log_path = std.fmt.allocPrint(arena, "{s}/{s}.jsonl", .{ dir, &sess.id }) catch |err| {
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

    const spawn_payload = .{
        .t = std.time.milliTimestamp(),
        .kind = "spawn",
        .program = program,
        .args = args,
        .name = sess.name,
        .rows = rows,
        .cols = cols,
    };
    const line = std.json.Stringify.valueAlloc(arena, spawn_payload, .{}) catch {
        file.close();
        return;
    };

    // Install the file handle and write the spawn line atomically with
    // respect to any concurrent drain events that would otherwise sneak in
    // ahead of the spawn record.
    sess.log_mutex.lock();
    defer sess.log_mutex.unlock();
    sess.log_file = file;
    writeLogEventLocked(sess, line);

    if (sess.name) |name| {
        createByNameSymlink(arena, dir, name, &sess.id) catch |err| {
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
pub fn logDrainedEvent(sess: *Session, now_ms: i64, event: hty.OutputEvent) void {
    if (sess.log_file == null) return;
    var arena_state = std.heap.ArenaAllocator.init(sess.alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const line = switch (event) {
        .raw_bytes => |bytes| std.json.Stringify.valueAlloc(arena, .{
            .t = now_ms,
            .kind = "output",
            .bytes_hex = hex_mod.encodeHex(arena, bytes) catch return,
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

/// Every input event carries an `origin` tag (`"send"` or `"attach"`) so
/// forensic readers can tell agent RPC traffic apart from interactive
/// keystrokes. `client_id` is optional and only meaningful when origin is
/// `"attach"`; it lets two concurrent attach clients be disambiguated.
pub fn logInputEvent(
    arena: Allocator,
    sess: *Session,
    bytes: []const u8,
    origin: []const u8,
    client_id: ?[]const u8,
) void {
    if (sess.log_file == null) return;
    const hex = hex_mod.encodeHex(arena, bytes) catch return;
    const line = if (client_id) |cid|
        std.json.Stringify.valueAlloc(arena, .{
            .t = std.time.milliTimestamp(),
            .kind = "input",
            .origin = origin,
            .client_id = cid,
            .bytes_hex = hex,
        }, .{}) catch return
    else
        std.json.Stringify.valueAlloc(arena, .{
            .t = std.time.milliTimestamp(),
            .kind = "input",
            .origin = origin,
            .bytes_hex = hex,
        }, .{}) catch return;
    writeLogEvent(sess, line);
}

pub fn logAttachConnectEvent(arena: Allocator, sess: *Session, client_id: []const u8) void {
    if (sess.log_file == null) return;
    const line = std.json.Stringify.valueAlloc(arena, .{
        .t = std.time.milliTimestamp(),
        .kind = "attach_connect",
        .client_id = client_id,
    }, .{}) catch return;
    writeLogEvent(sess, line);
}

pub fn logAttachDisconnectEvent(arena: Allocator, sess: *Session, client_id: []const u8) void {
    if (sess.log_file == null) return;
    const line = std.json.Stringify.valueAlloc(arena, .{
        .t = std.time.milliTimestamp(),
        .kind = "attach_disconnect",
        .client_id = client_id,
    }, .{}) catch return;
    writeLogEvent(sess, line);
}

pub fn logKilledEvent(arena: Allocator, sess: *Session) void {
    if (sess.log_file == null) return;
    const line = std.json.Stringify.valueAlloc(arena, .{
        .t = std.time.milliTimestamp(),
        .kind = "killed",
    }, .{}) catch return;
    writeLogEvent(sess, line);
}

pub fn logResizeEvent(arena: Allocator, sess: *Session, rows: u16, cols: u16) void {
    if (sess.log_file == null) return;
    const line = std.json.Stringify.valueAlloc(arena, .{
        .t = std.time.milliTimestamp(),
        .kind = "resize",
        .rows = rows,
        .cols = cols,
    }, .{}) catch return;
    writeLogEvent(sess, line);
}

/// Best-effort O(1) check for whether `name` is already reserved by a session
/// log on disk. The `by-name/<name>.jsonl` symlink is authoritative: it is
/// created at spawn (`openSessionLog`) and removed by delete/auto-remove.
/// Logs written by hty versions that predate the symlink are covered by the
/// one-time `reconcileByNameLinks` scan at server startup, so this hot-path
/// check never iterates the log directory.
pub fn nameInUse(alloc: Allocator, log_dir: ?[]const u8, name: []const u8) bool {
    const dir = log_dir orelse return false;

    const link_path = std.fmt.allocPrint(alloc, "{s}/by-name/{s}.jsonl", .{ dir, name }) catch return false;
    defer alloc.free(link_path);
    return fileExistsAbsolute(link_path);
}

/// One-time startup reconciliation for logs written by hty versions that
/// predate the by-name symlink: scan the log dir once and, for every
/// `.jsonl` whose spawn header carries a name but whose
/// `by-name/<name>.jsonl` link is missing (or dangling), create the link.
/// This keeps the O(1) `nameInUse` check authoritative across upgrades from
/// older on-disk state. Best-effort and silent on per-file failures, like
/// all log-dir maintenance. Runs before the server accepts requests, so it
/// never races spawn/delete.
pub fn reconcileByNameLinks(alloc: Allocator, log_dir: []const u8) void {
    var root = std.fs.openDirAbsolute(log_dir, .{ .iterate = true }) catch return;
    defer root.close();

    var it = root.iterate();
    while (it.next() catch return) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".jsonl")) continue;

        var arena_state = std.heap.ArenaAllocator.init(alloc);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        const name = spawnHeaderName(arena, log_dir, entry.name) orelse continue;

        // A resolvable link (or plain file) already reserves the name —
        // leave it alone; first claimant wins. A missing or dangling link
        // gets (re)created pointing at this log.
        const link_path = std.fmt.allocPrint(arena, "{s}/by-name/{s}.jsonl", .{ log_dir, name }) catch continue;
        if (fileExistsAbsolute(link_path)) continue;

        const id = entry.name[0 .. entry.name.len - ".jsonl".len];
        createByNameSymlink(arena, log_dir, name, id) catch |err| {
            std.debug.print("by-name reconcile failed ({s}): {s}\n", .{ name, @errorName(err) });
        };
    }
}

/// Read the first line of `<log_dir>/<file_name>` and return the session
/// name from its spawn header, or null if the header is missing, malformed,
/// or the session is unnamed. Returned slice lives in `arena`.
fn spawnHeaderName(arena: Allocator, log_dir: []const u8, file_name: []const u8) ?[]const u8 {
    const path = std.fmt.allocPrint(arena, "{s}/{s}", .{ log_dir, file_name }) catch return null;
    const file = std.fs.openFileAbsolute(path, .{ .mode = .read_only }) catch return null;
    defer file.close();

    var line_buf = std.array_list.Managed(u8).init(arena);
    var chunk: [4096]u8 = undefined;
    while (true) {
        const n = file.read(&chunk) catch return null;
        if (n == 0) break;
        if (std.mem.indexOfScalar(u8, chunk[0..n], '\n')) |nl| {
            line_buf.appendSlice(chunk[0..nl]) catch return null;
            break;
        }
        line_buf.appendSlice(chunk[0..n]) catch return null;
    }
    if (line_buf.items.len == 0) return null;

    const parsed = std.json.parseFromSlice(std.json.Value, arena, line_buf.items, .{}) catch return null;
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return null,
    };
    const kind = getString(obj, "kind") orelse return null;
    if (!std.mem.eql(u8, kind, "spawn")) return null;
    return getString(obj, "name");
}

fn fileExistsAbsolute(path: []const u8) bool {
    std.fs.accessAbsolute(path, .{}) catch return false;
    return true;
}
