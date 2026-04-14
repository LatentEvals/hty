//! `hty wait` — block until a session matches text/regex/idle/exit.

const std = @import("std");
const Allocator = std.mem.Allocator;

const common = @import("common.zig");

pub fn helpText() []const u8 {
    return
    \\hty wait [SESSION] --text "..." | --regex "..." | --idle MS | --exit [--timeout MS]
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
    \\
    ;
}

pub fn run(alloc: Allocator, args: []const []const u8) !void {
    var session_ref: ?[]const u8 = null;
    var wait_text: ?[]const u8 = null;
    var use_regex = false;
    var idle_ms: ?u64 = null;
    var wait_exit = false;
    var timeout_ms: u64 = 10_000;

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

    var payload_buf = std.array_list.Managed(u8).init(alloc);
    defer payload_buf.deinit();
    var writer = payload_buf.writer();

    if (wait_text) |t| {
        try writer.print("{{\"op\":\"wait_for_text\",\"text\":", .{});
        try common.writeJsonString(writer.any(), t);
        if (use_regex) try writer.writeAll(",\"regex\":true");
        try writer.print(",\"timeout_ms\":{d}", .{timeout_ms});
    } else if (idle_ms) |ms| {
        try writer.print("{{\"op\":\"wait_for_idle\",\"idle_ms\":{d},\"timeout_ms\":{d}", .{ ms, timeout_ms });
    } else {
        try writer.print("{{\"op\":\"wait_for_exit\",\"timeout_ms\":{d}", .{timeout_ms});
    }

    if (session_ref) |s| {
        try writer.writeAll(",\"session\":");
        try common.writeJsonString(writer.any(), s);
    }
    try writer.writeAll("}");

    const response_line = try common.sendRawRequest(alloc, payload_buf.items);
    defer alloc.free(response_line);

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, response_line, .{});
    defer parsed.deinit();
    const object = try common.expectOkOrExit(parsed);

    if (object.get("timed_out")) |to_val| {
        if (to_val == .bool and to_val.bool) {
            try common.printErr("timed out");
            std.process.exit(common.ExitCode.wait_timeout);
        }
    }
}
