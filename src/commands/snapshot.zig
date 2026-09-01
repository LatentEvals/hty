//! `hty snapshot` — read the current rendered screen of a session.

const std = @import("std");
const Allocator = std.mem.Allocator;

const common = @import("common.zig");
const getString = @import("../json.zig").getString;

pub fn helpText() []const u8 {
    return
    \\hty snapshot [SESSION] [--ansi] [--json] [--lines N:M]
    \\
    \\Read the session's current rendered screen. Default output is plain
    \\text. Use --ansi to get the styled ANSI rendering, --json for the full
    \\structured response.
    \\
    \\  --lines N:M   Print only rows N through M (1-indexed, inclusive).
    \\                Open ends are allowed: `N:` reads from row N to the
    \\                last row, `:M` from the first row through M. Rows past
    \\                the end of the screen are clamped. Not valid with
    \\                --json (which always carries the full snapshot).
    \\                Tip: editors show status lines and prompts on the
    \\                LAST rows — `--lines 1:12` misses a prompt on row
    \\                24. Prefer open `N:` ranges, or read the full
    \\                frame when state is unclear.
    \\
    ;
}

pub fn run(alloc: Allocator, io: std.Io, args: []const []const u8) !void {
    var session_ref: ?[]const u8 = null;
    var json_output = false;
    var ansi_output = false;
    var lines_range: ?common.LineRange = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--json")) {
            json_output = true;
        } else if (std.mem.eql(u8, arg, "--ansi")) {
            ansi_output = true;
        } else if (std.mem.eql(u8, arg, "--lines")) {
            i += 1;
            if (i >= args.len) return common.printUsageAndExit("--lines requires a value (N:M, N:, or :M)");
            lines_range = common.parseLineRange(args[i]) catch
                return common.printUsageAndExit("invalid --lines range: expected N:M, N:, or :M with 1-indexed rows and N <= M");
        } else if (std.mem.startsWith(u8, arg, "--")) {
            try common.printErrFmt("unknown flag: {s}", .{arg});
            std.process.exit(common.ExitCode.generic);
        } else if (session_ref == null) {
            session_ref = arg;
        }
    }

    if (lines_range != null and json_output) {
        try common.printErr("--lines is incompatible with --json (the JSON response always carries the full snapshot)");
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
    const field = if (ansi_output) "screen_ansi" else "buffer";
    const text = getString(snap_obj, field) orelse "";
    const body = if (lines_range) |r| common.sliceLines(text, r) else text;
    try common.printRaw(body);
    try common.printRaw("\n");
}

test "snapshot helpText documents --lines flag" {
    const text = helpText();
    try std.testing.expect(std.mem.indexOf(u8, text, "--lines N:M") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "1-indexed") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "LAST rows") != null);
}
