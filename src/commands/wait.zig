//! `hty wait` — block until a session matches text/regex/idle/exit.

const std = @import("std");
const Allocator = std.mem.Allocator;

const common = @import("common.zig");

pub fn helpText() []const u8 {
    return
    \\hty wait [SESSION] --text "..." | --regex "..." | --idle MS | --exit [--timeout MS] [--json]
    \\
    \\Block until the session matches a condition. Exactly one mode flag is
    \\required. Exit 0 on match, 3 on timeout.
    \\
    \\Modes:
    \\  --text STRING    Wait until the rendered screen contains STRING.
    \\  --regex PATTERN  Wait until the rendered screen matches PATTERN
    \\                   (POSIX extended regex).
    \\  --idle MS        Wait until the screen has been unchanged for MS
    \\                   milliseconds.
    \\  --exit           Wait until the child process exits.
    \\
    \\  --timeout MS     Max time to wait in milliseconds (default 10000).
    \\  --json           Emit a structured {matched, elapsed_ms, ...} object
    \\                   describing the match (or the timeout) to stdout.
    \\
    ;
}

pub fn run(alloc: Allocator, io: std.Io, args: []const []const u8) !void {
    var session_ref: ?[]const u8 = null;
    var wait_text: ?[]const u8 = null;
    var use_regex = false;
    var idle_ms: ?u64 = null;
    var wait_exit = false;
    var timeout_ms: u64 = 10_000;
    var json_output = false;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--text")) {
            i += 1;
            if (i >= args.len) return common.printUsageAndExit("--text requires a value");
            wait_text = args[i];
        } else if (std.mem.eql(u8, arg, "--regex")) {
            i += 1;
            if (i >= args.len) return common.printUsageAndExit("--regex requires a value");
            wait_text = args[i];
            use_regex = true;
        } else if (std.mem.eql(u8, arg, "--idle")) {
            i += 1;
            if (i >= args.len) return common.printUsageAndExit("--idle requires a value");
            idle_ms = try std.fmt.parseInt(u64, args[i], 10);
        } else if (std.mem.eql(u8, arg, "--exit")) {
            wait_exit = true;
        } else if (std.mem.eql(u8, arg, "--timeout")) {
            i += 1;
            if (i >= args.len) return common.printUsageAndExit("--timeout requires a value");
            timeout_ms = try std.fmt.parseInt(u64, args[i], 10);
        } else if (std.mem.eql(u8, arg, "--json")) {
            json_output = true;
        } else if (std.mem.startsWith(u8, arg, "--")) {
            try common.printErrFmt("unknown flag: {s}", .{arg});
            std.process.exit(common.ExitCode.generic);
        } else if (session_ref == null) {
            session_ref = arg;
        }
    }

    var modes: u8 = 0;
    if (wait_text != null) modes += 1;
    if (idle_ms != null) modes += 1;
    if (wait_exit) modes += 1;
    if (modes != 1) {
        try common.printErr("hty wait requires exactly one of --text, --regex, --idle, --exit");
        std.process.exit(common.ExitCode.generic);
    }

    var payload_buf: std.Io.Writer.Allocating = .init(alloc);
    defer payload_buf.deinit();
    const writer = &payload_buf.writer;

    if (wait_text) |t| {
        try writer.print("{{\"op\":\"wait_for_text\",\"text\":", .{});
        try common.writeJsonString(writer, t);
        if (use_regex) try writer.writeAll(",\"regex\":true");
        try writer.print(",\"timeout_ms\":{d}", .{timeout_ms});
    } else if (idle_ms) |ms| {
        try writer.print("{{\"op\":\"wait_for_idle\",\"idle_ms\":{d},\"timeout_ms\":{d}", .{ ms, timeout_ms });
    } else {
        try writer.print("{{\"op\":\"wait_for_exit\",\"timeout_ms\":{d}", .{timeout_ms});
    }

    if (session_ref) |s| {
        try writer.writeAll(",\"session\":");
        try common.writeJsonString(writer, s);
    }
    try writer.writeAll("}");

    const response_line = try common.sendRawRequest(alloc, io, payload_buf.writer.buffered());
    defer alloc.free(response_line);

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, response_line, .{});
    defer parsed.deinit();
    const object = try common.expectOkOrExit(parsed);

    const timed_out = blk: {
        if (object.get("timed_out")) |to_val| {
            if (to_val == .bool and to_val.bool) break :blk true;
        }
        break :blk false;
    };

    if (json_output) {
        try emitWaitJson(alloc, object, timed_out);
        if (timed_out) std.process.exit(common.ExitCode.wait_timeout);
        return;
    }

    if (timed_out) {
        try common.printErr("timed out");
        std.process.exit(common.ExitCode.wait_timeout);
    }
}

/// Emit the `wait` sub-object from the server's response. If the server
/// didn't include one (older build), synthesize a minimal payload so the
/// client contract holds regardless.
fn emitWaitJson(alloc: Allocator, object: std.json.ObjectMap, timed_out: bool) !void {
    if (object.get("wait")) |wait_val| {
        if (wait_val == .object) {
            const inner = try std.json.Stringify.valueAlloc(alloc, wait_val, .{});
            defer alloc.free(inner);
            try common.printLine(inner);
            return;
        }
    }

    // Fallback: synthesize a minimal object so --json consumers aren't
    // left parsing nothing. This path shouldn't trigger against a server
    // built from this same tree.
    var buf = std.array_list.Managed(u8).init(alloc);
    defer buf.deinit();
    if (timed_out) {
        try buf.appendSlice("{\"matched\":null,\"timeout\":true,\"elapsed_ms\":0}");
    } else {
        try buf.appendSlice("{\"matched\":null,\"timeout\":false,\"elapsed_ms\":0}");
    }
    try common.printLine(buf.items);
}
