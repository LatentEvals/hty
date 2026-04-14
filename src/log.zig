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

const Allocator = std.mem.Allocator;
const Session = session_mod.Session;

/// Append one JSONL line (no trailing newline on input) to the session's log
/// file, followed by '\n'. Silent no-op if the session has no log file.
pub fn writeLogEvent(sess: *Session, line: []const u8) void {
    const log_file = sess.log_file orelse return;
    log_file.writeAll(line) catch return;
    log_file.writeAll("\n") catch return;
}

pub fn closeLogFile(sess: *Session) void {
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

pub fn logInputEvent(arena: Allocator, sess: *Session, bytes: []const u8) void {
    if (sess.log_file == null) return;
    const hex = hex_mod.encodeHex(arena, bytes) catch return;
    const line = std.json.Stringify.valueAlloc(arena, .{
        .t = std.time.milliTimestamp(),
        .kind = "input",
        .bytes_hex = hex,
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
