//! `hty snapshot` — read the current rendered screen of a session.

const std = @import("std");
const Allocator = std.mem.Allocator;

const common = @import("common.zig");
const getString = @import("../json.zig").getString;

pub fn helpText() []const u8 {
    return
    \\hty snapshot [SESSION] [--ansi] [--json] [--diff [--lines N:M]]
    \\
    \\Read the session's current rendered screen. Default output is plain
    \\text. Use --ansi to get the styled ANSI rendering, --json for the full
    \\structured response.
    \\
    \\  --diff       Print only rows changed since the previous --diff
    \\               snapshot of this session (for polling loops): a
    \\               `rows LO-HI, N changed, cursor R,C` header, then one
    \\               `ROW| text` line per changed row — or exactly
    \\               `no change (cursor R,C)`. The first --diff (no
    \\               baseline yet) prints every row. Only --diff calls
    \\               update the baseline; plain/--json snapshots never do.
    \\  --lines N:M  With --diff, bound the compared/reported rows to
    \\               N..M (1-indexed inclusive; either side may be
    \\               omitted, e.g. `:5` or `20:`).
    \\
    ;
}

pub fn run(alloc: Allocator, io: std.Io, args: []const []const u8) !void {
    var session_ref: ?[]const u8 = null;
    var json_output = false;
    var ansi_output = false;
    var diff_output = false;
    var lines_range: ?LinesRange = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--json")) {
            json_output = true;
        } else if (std.mem.eql(u8, arg, "--ansi")) {
            ansi_output = true;
        } else if (std.mem.eql(u8, arg, "--diff")) {
            diff_output = true;
        } else if (std.mem.eql(u8, arg, "--lines")) {
            i += 1;
            if (i >= args.len) common.printUsageAndExit("--lines requires a value (N:M)");
            lines_range = parseLinesRange(args[i]) catch
                common.printUsageAndExit("invalid --lines value; expected N:M with 1-indexed rows");
        } else if (std.mem.startsWith(u8, arg, "--")) {
            try common.printErrFmt("unknown flag: {s}", .{arg});
            std.process.exit(common.ExitCode.generic);
        } else if (session_ref == null) {
            session_ref = arg;
        }
    }

    if (diff_output and (json_output or ansi_output)) {
        try common.printErr("--diff is incompatible with --json and --ansi");
        std.process.exit(common.ExitCode.generic);
    }
    if (lines_range != null and !diff_output) {
        try common.printErr("--lines requires --diff");
        std.process.exit(common.ExitCode.generic);
    }

    var payload_buf: std.Io.Writer.Allocating = .init(alloc);
    defer payload_buf.deinit();
    try payload_buf.writer.writeAll("{\"op\":\"snapshot\"");
    if (session_ref) |s| {
        try payload_buf.writer.writeAll(",\"session\":");
        try common.writeJsonString(&payload_buf.writer, s);
    }
    if (diff_output) {
        try payload_buf.writer.writeAll(",\"diff\":true");
        if (lines_range) |range| {
            if (range.start != 0) try payload_buf.writer.print(",\"line_start\":{d}", .{range.start});
            if (range.end != 0) try payload_buf.writer.print(",\"line_end\":{d}", .{range.end});
        }
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

    if (diff_output) {
        try common.printDiffBody(alloc, object);
        return;
    }

    const snap_val = object.get("snapshot") orelse return;
    const snap_obj = switch (snap_val) {
        .object => |o| o,
        else => return,
    };
    const field = if (ansi_output) "screen_ansi" else "buffer";
    const text = getString(snap_obj, field) orelse "";
    try common.printRaw(text);
    try common.printRaw("\n");
}

/// A `--lines` bound: 1-indexed inclusive, 0 = open on that side.
const LinesRange = struct { start: u64, end: u64 };

/// Parse `N:M` (either side optional) or a bare `N` (that single row).
fn parseLinesRange(text: []const u8) !LinesRange {
    const colon = std.mem.indexOfScalar(u8, text, ':') orelse {
        const n = try std.fmt.parseInt(u64, text, 10);
        if (n == 0) return error.InvalidRange;
        return .{ .start = n, .end = n };
    };
    const start_text = text[0..colon];
    const end_text = text[colon + 1 ..];
    if (start_text.len == 0 and end_text.len == 0) return error.InvalidRange;
    const start: u64 = if (start_text.len == 0) 0 else try std.fmt.parseInt(u64, start_text, 10);
    const end: u64 = if (end_text.len == 0) 0 else try std.fmt.parseInt(u64, end_text, 10);
    if (start_text.len > 0 and start == 0) return error.InvalidRange;
    if (end_text.len > 0 and end == 0) return error.InvalidRange;
    if (start != 0 and end != 0 and end < start) return error.InvalidRange;
    return .{ .start = start, .end = end };
}

test "parseLinesRange accepts N:M, open ends, and bare N" {
    try std.testing.expectEqual(LinesRange{ .start = 2, .end = 5 }, try parseLinesRange("2:5"));
    try std.testing.expectEqual(LinesRange{ .start = 0, .end = 5 }, try parseLinesRange(":5"));
    try std.testing.expectEqual(LinesRange{ .start = 20, .end = 0 }, try parseLinesRange("20:"));
    try std.testing.expectEqual(LinesRange{ .start = 7, .end = 7 }, try parseLinesRange("7"));
    try std.testing.expectError(error.InvalidRange, parseLinesRange(":"));
    try std.testing.expectError(error.InvalidRange, parseLinesRange("5:2"));
    try std.testing.expectError(error.InvalidRange, parseLinesRange("0:3"));
    try std.testing.expectError(error.InvalidCharacter, parseLinesRange("abc"));
}
