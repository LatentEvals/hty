//! `hty kill` — terminate a session's process (record kept for replay).

const std = @import("std");
const Allocator = std.mem.Allocator;

const common = @import("common.zig");

pub fn helpText() []const u8 {
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

pub fn run(alloc: Allocator, args: []const []const u8) !void {
    const session_ref = if (args.len > 0) args[0] else null;

    var payload_buf = std.array_list.Managed(u8).init(alloc);
    defer payload_buf.deinit();
    try payload_buf.appendSlice("{\"op\":\"kill\"");
    if (session_ref) |s| {
        try payload_buf.appendSlice(",\"session\":");
        try common.writeJsonString(payload_buf.writer().any(), s);
    }
    try payload_buf.appendSlice("}");

    const response_line = try common.sendRawRequest(alloc, payload_buf.items);
    defer alloc.free(response_line);

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, response_line, .{});
    defer parsed.deinit();
    _ = try common.expectOkOrExit(parsed);

    const display = session_ref orelse "session";
    const msg = try std.fmt.allocPrint(alloc, "killed {s} (record kept — `hty delete` to remove)", .{display});
    defer alloc.free(msg);
    try common.printLine(msg);
}
