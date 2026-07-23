//! `hty kill` — terminate a session's process (record kept for replay).

const std = @import("std");
const sys = @import("hty").sys;
const Allocator = std.mem.Allocator;

const common = @import("common.zig");

pub fn helpText() []const u8 {
    return
    \\hty kill [--delete] [SESSION]
    \\
    \\Terminate a session's underlying process. The session RECORD stays in
    \\place (same id, same name) so `hty list`, `hty logs` and `hty replay`
    \\keep working on it — use `hty delete` to free the name and remove the
    \\log file permanently.
    \\
    \\If SESSION is omitted and exactly one session is running, that one
    \\is killed.
    \\
    \\Flags:
    \\  --delete   After killing, also delete the session record and log
    \\             file (equivalent to `hty kill` followed by `hty
    \\             delete`). Useful for ad-hoc or test sessions whose
    \\             recording you don't need to keep.
    \\
    ;
}

pub fn run(alloc: Allocator, io: std.Io, args: []const []const u8) !void {
    var delete_after = false;
    var session_ref: ?[]const u8 = null;

    for (args) |a| {
        if (std.mem.eql(u8, a, "--delete")) {
            delete_after = true;
        } else if (std.mem.startsWith(u8, a, "-") and !std.mem.eql(u8, a, "-")) {
            try common.printErrFmt("hty kill: unknown flag: {s}", .{a});
            std.process.exit(common.ExitCode.generic);
        } else {
            if (session_ref != null) {
                try common.printErr("hty kill: too many arguments");
                std.process.exit(common.ExitCode.generic);
            }
            session_ref = a;
        }
    }

    // Kill phase.
    {
        var payload_buf: std.Io.Writer.Allocating = .init(alloc);
        defer payload_buf.deinit();
        try payload_buf.writer.writeAll("{\"op\":\"kill\"");
        if (session_ref) |s| {
            try payload_buf.writer.writeAll(",\"session\":");
            try common.writeJsonString(&payload_buf.writer, s);
        }
        try payload_buf.writer.writeAll("}");

        const response_line = try common.sendRawRequest(alloc, io, payload_buf.writer.buffered());
        defer alloc.free(response_line);

        var parsed = try std.json.parseFromSlice(std.json.Value, alloc, response_line, .{});
        defer parsed.deinit();
        _ = try common.expectOkOrExit(parsed);
    }

    if (!delete_after) {
        const display = session_ref orelse "session";
        const msg = try std.fmt.allocPrint(alloc, "killed {s} (record kept — `hty delete` to remove)", .{display});
        defer alloc.free(msg);
        try common.printLine(msg);
        return;
    }

    // Delete phase. Kill is synchronous on the server (handleKill reaps
    // the child before returning), so sending `delete` next is safe.
    // If delete fails here, its exit code propagates — the user can
    // retry `hty delete <ref>` manually; the process is already dead.
    {
        var payload_buf: std.Io.Writer.Allocating = .init(alloc);
        defer payload_buf.deinit();
        try payload_buf.writer.writeAll("{\"op\":\"delete\"");
        if (session_ref) |s| {
            try payload_buf.writer.writeAll(",\"session\":");
            try common.writeJsonString(&payload_buf.writer, s);
        }
        try payload_buf.writer.writeAll("}");

        const response_line = try common.sendRawRequest(alloc, io, payload_buf.writer.buffered());
        defer alloc.free(response_line);

        var parsed = try std.json.parseFromSlice(std.json.Value, alloc, response_line, .{});
        defer parsed.deinit();
        _ = try common.expectOkOrExit(parsed);
    }

    const display = session_ref orelse "session";
    const msg = try std.fmt.allocPrint(alloc, "killed and deleted {s}", .{display});
    defer alloc.free(msg);
    try common.printLine(msg);
}

test "kill helpText documents --delete flag" {
    const text = helpText();
    try std.testing.expect(std.mem.indexOf(u8, text, "--delete") != null);
}

test "kill then delete removes the session record (end-to-end via ops)" {
    const alloc = std.testing.allocator;
    const SessionRegistry = @import("../registry.zig").SessionRegistry;
    const tests_mod = @import("../tests.zig");

    const io = std.testing.io;
    var log_dir_buf: [256]u8 = undefined;
    const log_dir = try std.fmt.bufPrint(
        &log_dir_buf,
        "/tmp/hty-kill-delete-test-{d}",
        .{sys.nanoTimestamp()},
    );
    try std.Io.Dir.cwd().createDirPath(io, log_dir);
    defer std.Io.Dir.cwd().deleteTree(io, log_dir) catch {};
    const by_name = try std.fmt.allocPrint(alloc, "{s}/by-name", .{log_dir});
    defer alloc.free(by_name);
    try std.Io.Dir.cwd().createDirPath(io, by_name);

    var registry = SessionRegistry.init(alloc);
    defer registry.deinit();
    registry.log_dir = log_dir;

    const uuid = try tests_mod.spawnCatSession(&registry, "kd-happy");
    defer alloc.free(uuid);

    // kill — same call `hty kill --delete` issues first.
    {
        var parsed = try tests_mod.testRequest(&registry, .{ .op = "kill", .session = "kd-happy" });
        defer parsed.deinit();
        _ = try tests_mod.expectTestOk(parsed);
    }
    // delete — chained second call.
    {
        var parsed = try tests_mod.testRequest(&registry, .{ .op = "delete", .session = "kd-happy" });
        defer parsed.deinit();
        _ = try tests_mod.expectTestOk(parsed);
    }

    // Session is gone from the registry.
    var parsed = try tests_mod.testRequest(&registry, .{ .op = "list" });
    defer parsed.deinit();
    const obj = try tests_mod.expectTestOk(parsed);
    const sessions = obj.get("sessions") orelse return error.InvalidResponse;
    if (sessions != .array) return error.InvalidResponse;
    try std.testing.expectEqual(@as(usize, 0), sessions.array.items.len);
}

test "kill+delete on already-exited session still removes the record" {
    const alloc = std.testing.allocator;
    const SessionRegistry = @import("../registry.zig").SessionRegistry;
    const tests_mod = @import("../tests.zig");

    const io = std.testing.io;
    var log_dir_buf: [256]u8 = undefined;
    const log_dir = try std.fmt.bufPrint(
        &log_dir_buf,
        "/tmp/hty-kill-delete-exited-test-{d}",
        .{sys.nanoTimestamp()},
    );
    try std.Io.Dir.cwd().createDirPath(io, log_dir);
    defer std.Io.Dir.cwd().deleteTree(io, log_dir) catch {};
    const by_name = try std.fmt.allocPrint(alloc, "{s}/by-name", .{log_dir});
    defer alloc.free(by_name);
    try std.Io.Dir.cwd().createDirPath(io, by_name);

    var registry = SessionRegistry.init(alloc);
    defer registry.deinit();
    registry.log_dir = log_dir;

    const uuid = try tests_mod.spawnCatSession(&registry, "kd-exited");
    defer alloc.free(uuid);

    // First kill transitions to .killed. Second kill is idempotent (ok).
    {
        var parsed = try tests_mod.testRequest(&registry, .{ .op = "kill", .session = "kd-exited" });
        defer parsed.deinit();
        _ = try tests_mod.expectTestOk(parsed);
    }
    {
        var parsed = try tests_mod.testRequest(&registry, .{ .op = "kill", .session = "kd-exited" });
        defer parsed.deinit();
        _ = try tests_mod.expectTestOk(parsed);
    }
    // delete should still succeed and remove the record.
    {
        var parsed = try tests_mod.testRequest(&registry, .{ .op = "delete", .session = "kd-exited" });
        defer parsed.deinit();
        _ = try tests_mod.expectTestOk(parsed);
    }

    var parsed = try tests_mod.testRequest(&registry, .{ .op = "list" });
    defer parsed.deinit();
    const obj = try tests_mod.expectTestOk(parsed);
    const sessions = obj.get("sessions") orelse return error.InvalidResponse;
    if (sessions != .array) return error.InvalidResponse;
    try std.testing.expectEqual(@as(usize, 0), sessions.array.items.len);
}

test "kill on nonexistent session fails before any delete happens" {
    const alloc = std.testing.allocator;
    const SessionRegistry = @import("../registry.zig").SessionRegistry;
    const tests_mod = @import("../tests.zig");

    var registry = SessionRegistry.init(alloc);
    defer registry.deinit();

    // This is what `hty kill --delete nope` would send first.
    var parsed = try tests_mod.testRequest(&registry, .{ .op = "kill", .session = "nope" });
    defer parsed.deinit();
    try tests_mod.expectTestError(parsed, "session not found");
}
