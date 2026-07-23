//! `hty delete` — permanently remove a session's record and log file.

const std = @import("std");
const Allocator = std.mem.Allocator;

const common = @import("common.zig");
const logs = @import("logs.zig");

pub fn helpText() []const u8 {
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

pub fn run(alloc: Allocator, io: std.Io, args: []const []const u8) !void {
    const session_ref = if (args.len > 0) args[0] else null;

    // First try the server — it owns any live or zombie sessions in the
    // current registry and will cleanly kill + unlink them.
    var payload_buf: std.Io.Writer.Allocating = .init(alloc);
    defer payload_buf.deinit();
    try payload_buf.writer.writeAll("{\"op\":\"delete\"");
    if (session_ref) |s| {
        try payload_buf.writer.writeAll(",\"session\":");
        try common.writeJsonString(&payload_buf.writer, s);
    }
    try payload_buf.writer.writeAll("}");

    var server_ok = false;
    if (common.sendRawRequest(alloc, io, payload_buf.writer.buffered())) |response_line| {
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
        try common.printLine(msg);
        return;
    }

    // Server didn't know about it (orphan from a prior server instance,
    // or server unreachable). Unlink the log file and symlink directly.
    const ref = session_ref orelse {
        try common.printErr("hty delete: session not found");
        std.process.exit(common.ExitCode.not_found);
    };

    const path = logs.resolveLogPath(alloc, io, ref) catch |err| {
        switch (err) {
            error.SessionNotFound => try common.printErr("hty delete: session not found"),
            error.AmbiguousPrefix => try common.printErr("hty delete: ambiguous session prefix"),
            error.AmbiguousSole => try common.printErr("hty delete: more than one session exists — name one explicitly"),
            else => try common.printErrFmt("hty delete: {s}", .{@errorName(err)}),
        }
        std.process.exit(common.ExitCode.not_found);
    };
    defer alloc.free(path);

    // `path` may be the by-name symlink or a direct UUID file. Resolve
    // it to the canonical UUID file so we can delete both it and the
    // symlink (if any) cleanly.
    const real_path = std.Io.Dir.cwd().realPathFileAlloc(io, path, alloc) catch try alloc.dupe(u8, path);
    defer alloc.free(real_path);

    std.Io.Dir.deleteFileAbsolute(io, real_path) catch |err| {
        try common.printErrFmt("hty delete: failed to unlink {s}: {s}", .{ real_path, @errorName(err) });
        std.process.exit(common.ExitCode.generic);
    };
    // Also remove the name symlink if the reference was a name.
    if (!std.mem.eql(u8, path, real_path)) {
        std.Io.Dir.deleteFileAbsolute(io, path) catch {};
    }

    const msg = try std.fmt.allocPrint(alloc, "deleted {s} (log file unlinked)", .{ref});
    defer alloc.free(msg);
    try common.printLine(msg);
}
