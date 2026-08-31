//! `hty snapshot` — read the current rendered screen of a session.

const std = @import("std");
const Allocator = std.mem.Allocator;

const common = @import("common.zig");
const json_mod = @import("../json.zig");
const getString = json_mod.getString;
const getInteger = json_mod.getInteger;

pub fn helpText() []const u8 {
    return
    \\hty snapshot [SESSION] [--ansi] [--json] [--meta]
    \\
    \\Read the session's current rendered screen. Default output is plain
    \\text. Use --ansi to get the styled ANSI rendering, --json for the full
    \\structured response, or --meta for just the metadata (cursor position,
    \\screen size, session status) without the screen buffer. --meta cannot
    \\be combined with --ansi or --json.
    \\
    ;
}

pub fn run(alloc: Allocator, io: std.Io, args: []const []const u8) !void {
    var session_ref: ?[]const u8 = null;
    var json_output = false;
    var ansi_output = false;
    var meta_output = false;

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--json")) {
            json_output = true;
        } else if (std.mem.eql(u8, arg, "--ansi")) {
            ansi_output = true;
        } else if (std.mem.eql(u8, arg, "--meta")) {
            meta_output = true;
        } else if (std.mem.startsWith(u8, arg, "--")) {
            try common.printErrFmt("unknown flag: {s}", .{arg});
            std.process.exit(common.ExitCode.generic);
        } else if (session_ref == null) {
            session_ref = arg;
        }
    }

    if (meta_output and (json_output or ansi_output)) {
        try common.printErr("cannot combine --meta with --json or --ansi");
        std.process.exit(common.ExitCode.generic);
    }

    var payload_buf: std.Io.Writer.Allocating = .init(alloc);
    defer payload_buf.deinit();
    try payload_buf.writer.writeAll("{\"op\":\"snapshot\"");
    if (session_ref) |s| {
        try payload_buf.writer.writeAll(",\"session\":");
        try common.writeJsonString(&payload_buf.writer, s);
    }
    try payload_buf.writer.writeAll("}");

    const response_line = try common.sendRawRequest(alloc, io, payload_buf.writer.buffered());
    defer alloc.free(response_line);

    if (json_output) {
        try common.printRaw(response_line);
        try common.printRaw("\n");
        return;
    }

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, response_line, .{});
    defer parsed.deinit();
    const object = try common.expectOkOrExit(parsed);

    const snap_val = object.get("snapshot") orelse return;
    const snap_obj = switch (snap_val) {
        .object => |o| o,
        else => return,
    };

    if (meta_output) {
        var buf: std.Io.Writer.Allocating = .init(alloc);
        defer buf.deinit();
        try renderMeta(
            &buf.writer,
            getInteger(snap_obj, "rows") orelse 0,
            getInteger(snap_obj, "cols") orelse 0,
            getInteger(snap_obj, "cursor_row") orelse 0,
            getInteger(snap_obj, "cursor_col") orelse 0,
            getString(snap_obj, "status") orelse "",
        );
        try common.printRaw(buf.writer.buffered());
        return;
    }

    const field = if (ansi_output) "screen_ansi" else "buffer";
    const text = getString(snap_obj, field) orelse "";
    try common.printRaw(text);
    try common.printRaw("\n");
}

/// Render the `--meta` block: the metadata the server already tracks for
/// every snapshot, without the screen buffer. Cursor is `row,col`
/// (1-indexed, snapshot convention); size is `colsxrows`.
fn renderMeta(
    w: *std.Io.Writer,
    rows: i64,
    cols: i64,
    cursor_row: i64,
    cursor_col: i64,
    status: []const u8,
) !void {
    try w.print("cursor:  {d},{d}\n", .{ cursor_row, cursor_col });
    try w.print("size:    {d}x{d}\n", .{ cols, rows });
    try w.print("status:  {s}\n", .{status});
}

test "renderMeta formats cursor, size, and status" {
    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    try renderMeta(&buf.writer, 24, 80, 3, 17, "running");
    try std.testing.expectEqualStrings(
        "cursor:  3,17\nsize:    80x24\nstatus:  running\n",
        buf.writer.buffered(),
    );
}
