//! Client-side helpers shared by every `hty <subcommand>` run by the CLI.
//!
//! These used to live at the top of `headless.zig` but each command now
//! lives in its own file under `src/commands/`, so the common pieces
//! (request/response plumbing, stdout/stderr formatting, exit-code
//! mapping, and the canonical `ExitCode` constants) moved here.

const std = @import("std");
const Allocator = std.mem.Allocator;

const paths = @import("../paths.zig");
const ensure = @import("../ensure.zig");

/// Stable CLI exit codes (contract across versions once we ship 0.1).
pub const ExitCode = struct {
    pub const ok: u8 = 0;
    pub const generic: u8 = 1;
    pub const not_found: u8 = 2;
    pub const wait_timeout: u8 = 3;
    pub const ambiguous_prefix: u8 = 4;
    pub const name_exists: u8 = 5;
};

/// Send a structured request value to the server; return the parsed JSON
/// response. The caller owns the Parsed value.
pub fn sendRequest(alloc: Allocator, request_value: anytype) !std.json.Parsed(std.json.Value) {
    const socket_path = try paths.resolveSocketPath(alloc);
    defer alloc.free(socket_path);

    var stream = try ensure.ensureServer(alloc, socket_path, .{});
    defer stream.close();

    const payload = try std.json.Stringify.valueAlloc(alloc, request_value, .{});
    defer alloc.free(payload);

    try stream.writeAll(payload);
    try stream.writeAll("\n");

    var response_buf = std.array_list.Managed(u8).init(alloc);
    defer response_buf.deinit();

    var chunk: [4096]u8 = undefined;
    while (true) {
        const n = try stream.read(&chunk);
        if (n == 0) break;
        try response_buf.appendSlice(chunk[0..n]);
        if (std.mem.indexOfScalar(u8, response_buf.items, '\n') != null) break;
    }

    const newline = std.mem.indexOfScalar(u8, response_buf.items, '\n') orelse response_buf.items.len;
    return std.json.parseFromSlice(std.json.Value, alloc, response_buf.items[0..newline], .{});
}

/// Low-level: send a pre-built JSON string to the server; return raw response.
/// Caller owns the returned slice.
pub fn sendRawRequest(alloc: Allocator, request_json: []const u8) ![]u8 {
    const socket_path = try paths.resolveSocketPath(alloc);
    defer alloc.free(socket_path);

    var stream = try ensure.ensureServer(alloc, socket_path, .{});
    defer stream.close();

    try stream.writeAll(request_json);
    try stream.writeAll("\n");

    var response_buf = std.array_list.Managed(u8).init(alloc);
    defer response_buf.deinit();

    var chunk: [4096]u8 = undefined;
    while (true) {
        const n = try stream.read(&chunk);
        if (n == 0) break;
        try response_buf.appendSlice(chunk[0..n]);
        if (std.mem.indexOfScalar(u8, response_buf.items, '\n') != null) break;
    }

    const newline = std.mem.indexOfScalar(u8, response_buf.items, '\n') orelse response_buf.items.len;
    return alloc.dupe(u8, response_buf.items[0..newline]);
}

pub fn printJsonLine(object: anytype) !void {
    const alloc = std.heap.c_allocator;
    const json = try std.json.Stringify.valueAlloc(alloc, object, .{});
    defer alloc.free(json);
    var stdout = std.fs.File.stdout();
    _ = try stdout.writeAll(json);
    _ = try stdout.writeAll("\n");
}

pub fn printLine(text: []const u8) !void {
    var stdout = std.fs.File.stdout();
    _ = try stdout.writeAll(text);
    _ = try stdout.writeAll("\n");
}

pub fn printRaw(text: []const u8) !void {
    var stdout = std.fs.File.stdout();
    _ = try stdout.writeAll(text);
}

pub fn printErr(text: []const u8) !void {
    var stderr = std.fs.File.stderr();
    _ = try stderr.writeAll(text);
    _ = try stderr.writeAll("\n");
}

pub fn printErrFmt(comptime fmt: []const u8, args: anytype) !void {
    const alloc = std.heap.c_allocator;
    const msg = try std.fmt.allocPrint(alloc, fmt, args);
    defer alloc.free(msg);
    try printErr(msg);
}

/// Check that a response envelope has ok=true; return the response object.
/// Emits an error message to stderr and exits with the appropriate code on failure.
pub fn expectOkOrExit(parsed: std.json.Parsed(std.json.Value)) !std.json.ObjectMap {
    const object = switch (parsed.value) {
        .object => |o| o,
        else => {
            try printErr("invalid response from server");
            std.process.exit(ExitCode.generic);
        },
    };
    const ok = object.get("ok") orelse {
        try printErr("malformed response: missing ok field");
        std.process.exit(ExitCode.generic);
    };
    switch (ok) {
        .bool => |v| if (!v) {
            const msg = if (object.get("error")) |err_val|
                switch (err_val) {
                    .string => |s| s,
                    else => "unknown error",
                }
            else
                "unknown error";
            try printErrFmt("error: {s}", .{msg});
            const code = errorToExitCode(msg);
            std.process.exit(code);
        },
        else => {
            try printErr("malformed response: ok is not a boolean");
            std.process.exit(ExitCode.generic);
        },
    }
    return object;
}

pub fn errorToExitCode(msg: []const u8) u8 {
    if (std.mem.indexOf(u8, msg, "session not found") != null) return ExitCode.not_found;
    if (std.mem.indexOf(u8, msg, "SessionNotFound") != null) return ExitCode.not_found;
    if (std.mem.indexOf(u8, msg, "ambiguous") != null) return ExitCode.ambiguous_prefix;
    if (std.mem.indexOf(u8, msg, "AmbiguousPrefix") != null) return ExitCode.ambiguous_prefix;
    if (std.mem.indexOf(u8, msg, "already exists") != null) return ExitCode.name_exists;
    if (std.mem.indexOf(u8, msg, "NameAlreadyExists") != null) return ExitCode.name_exists;
    return ExitCode.generic;
}

pub fn printUsageAndExit(msg: []const u8) noreturn {
    printErr(msg) catch {};
    std.process.exit(ExitCode.generic);
}

/// Parse a duration like "500ms", "5s", "2m", "1h", or a bare integer
/// (interpreted as seconds). Returns the value in milliseconds.
pub fn parseDurationMs(text: []const u8) !u64 {
    if (text.len == 0) return error.InvalidDuration;
    var digit_end: usize = 0;
    while (digit_end < text.len and text[digit_end] >= '0' and text[digit_end] <= '9') digit_end += 1;
    if (digit_end == 0) return error.InvalidDuration;
    const n = try std.fmt.parseInt(u64, text[0..digit_end], 10);
    const suffix = text[digit_end..];
    if (suffix.len == 0) return n * 1000; // bare integer = seconds
    if (std.mem.eql(u8, suffix, "ms")) return n;
    if (std.mem.eql(u8, suffix, "s")) return n * 1000;
    if (std.mem.eql(u8, suffix, "m")) return n * 60 * 1000;
    if (std.mem.eql(u8, suffix, "h")) return n * 60 * 60 * 1000;
    return error.InvalidDuration;
}

/// Serialize a Zig string as a JSON string, writing to the given writer.
/// Handles the standard escapes plus \uXXXX for other control bytes.
pub fn writeJsonString(writer: std.io.AnyWriter, s: []const u8) !void {
    try writer.writeByte('"');
    for (s) |b| {
        switch (b) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            0...0x08, 0x0b, 0x0c, 0x0e...0x1f => try writer.print("\\u{x:0>4}", .{b}),
            else => try writer.writeByte(b),
        }
    }
    try writer.writeByte('"');
}
