//! Client-side helpers shared by every `hty <subcommand>` run by the CLI.
//!
//! These used to live at the top of `headless.zig` but each command now
//! lives in its own file under `src/commands/`, so the common pieces
//! (request/response plumbing, stdout/stderr formatting, exit-code
//! mapping, and the canonical `ExitCode` constants) moved here.

const std = @import("std");
const sys = @import("hty").sys;
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

/// Resolve the socket path, exiting with a one-line message when the state
/// directory cannot be prepared (read-only $HOME, sandboxed shell, ...).
/// Without this the raw error unwinds out of main() as a Zig stack trace.
pub fn resolveSocketPathOrExit(alloc: Allocator) []u8 {
    return paths.resolveSocketPath(alloc) catch |err| {
        const dir: []const u8 = paths.resolveRuntimeDir(alloc) catch "<unresolved>";
        printErrFmt("error: cannot prepare hty state dir {s} ({s})\n" ++
            "Fix its permissions or set XDG_STATE_HOME to a writable location.", .{ dir, @errorName(err) }) catch {};
        std.process.exit(ExitCode.generic);
    };
}

/// Connect via ensureServer, exiting cleanly on the failures it has already
/// diagnosed on stderr; anything unexpected still propagates.
pub fn connectOrExit(alloc: Allocator, io: std.Io, socket_path: []const u8) !sys.Stream {
    return ensure.ensureServer(alloc, io, socket_path, .{}) catch |err| switch (err) {
        error.ServerUnreachable,
        error.ServerStartupFailed,
        error.StateDirNotWritable,
        error.SocketPathTooLong,
        => std.process.exit(ExitCode.generic),
        else => return err,
    };
}

/// Send a structured request value to the server; return the parsed JSON
/// response. The caller owns the Parsed value.
pub fn sendRequest(alloc: Allocator, io: std.Io, request_value: anytype) !std.json.Parsed(std.json.Value) {
    const socket_path = resolveSocketPathOrExit(alloc);
    defer alloc.free(socket_path);

    var stream = try connectOrExit(alloc, io, socket_path);
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
pub fn sendRawRequest(alloc: Allocator, io: std.Io, request_json: []const u8) ![]u8 {
    const socket_path = resolveSocketPathOrExit(alloc);
    defer alloc.free(socket_path);

    var stream = try connectOrExit(alloc, io, socket_path);
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
    try sys.writeAll(std.posix.STDOUT_FILENO, json);
    try sys.writeAll(std.posix.STDOUT_FILENO, "\n");
}

pub fn printLine(text: []const u8) !void {
    try sys.writeAll(std.posix.STDOUT_FILENO, text);
    try sys.writeAll(std.posix.STDOUT_FILENO, "\n");
}

pub fn printRaw(text: []const u8) !void {
    try sys.writeAll(std.posix.STDOUT_FILENO, text);
}

pub fn printErr(text: []const u8) !void {
    try sys.writeAll(std.posix.STDERR_FILENO, text);
    try sys.writeAll(std.posix.STDERR_FILENO, "\n");
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
pub fn writeJsonString(writer: *std.Io.Writer, s: []const u8) !void {
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

/// Number of decimal digits in `n` (n >= 0).
fn decimalWidth(n: i64) usize {
    var width: usize = 1;
    var value = n;
    while (value >= 10) : (value = @divTrunc(value, 10)) width += 1;
    return width;
}

/// Render the plain output for a `snapshot --diff` response's `diff`
/// payload: a `rows LO-HI, N changed, cursor R,C` header followed by one
/// `ROW| text` line per changed row (row numbers right-aligned to the
/// grid's widest row number), or exactly `no change (cursor R,C)` when
/// nothing changed. Caller owns the returned slice.
pub fn formatDiffBody(alloc: Allocator, diff: std.json.ObjectMap) ![]u8 {
    const json_mod = @import("../json.zig");
    const rows = json_mod.getInteger(diff, "rows") orelse 0;
    const cursor_row = json_mod.getInteger(diff, "cursor_row") orelse 0;
    const cursor_col = json_mod.getInteger(diff, "cursor_col") orelse 0;
    const range_start = json_mod.getInteger(diff, "range_start") orelse 1;
    const range_end = json_mod.getInteger(diff, "range_end") orelse rows;

    const changed: []const std.json.Value = blk: {
        const value = diff.get("changed") orelse break :blk &.{};
        break :blk switch (value) {
            .array => |array| array.items,
            else => &.{},
        };
    };

    var buf: std.Io.Writer.Allocating = .init(alloc);
    defer buf.deinit();
    const writer = &buf.writer;

    if (changed.len == 0) {
        try writer.print("no change (cursor {d},{d})\n", .{ cursor_row, cursor_col });
        return buf.toOwnedSlice();
    }

    try writer.print("rows {d}-{d}, {d} changed, cursor {d},{d}\n", .{
        range_start, range_end, changed.len, cursor_row, cursor_col,
    });

    const width = decimalWidth(@max(rows, 1));
    for (changed) |entry| {
        if (entry != .object) continue;
        const row = json_mod.getInteger(entry.object, "row") orelse continue;
        const text = json_mod.getString(entry.object, "text") orelse "";
        var pad = width -| decimalWidth(row);
        while (pad > 0) : (pad -= 1) try writer.writeByte(' ');
        try writer.print("{d}| {s}\n", .{ row, text });
    }

    return buf.toOwnedSlice();
}

/// Print the plain diff rendering from a response envelope carrying a
/// `diff` payload. No-op when the payload is absent.
pub fn printDiffBody(alloc: Allocator, object: std.json.ObjectMap) !void {
    const diff_val = object.get("diff") orelse return;
    if (diff_val != .object) return;
    const text = try formatDiffBody(alloc, diff_val.object);
    defer alloc.free(text);
    try printRaw(text);
}

test "formatDiffBody: changed rows with aligned numbers" {
    const alloc = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc,
        \\{"rows":24,"cols":80,"cursor_row":4,"cursor_col":17,
        \\ "range_start":1,"range_end":24,"full":false,
        \\ "changed":[{"row":4,"text":"def parse_duration(value):"},
        \\            {"row":12,"text":"    return ms"}]}
    , .{});
    defer parsed.deinit();
    const out = try formatDiffBody(alloc, parsed.value.object);
    defer alloc.free(out);
    try std.testing.expectEqualStrings(
        "rows 1-24, 2 changed, cursor 4,17\n" ++
            " 4| def parse_duration(value):\n" ++
            "12|     return ms\n",
        out,
    );
}

test "formatDiffBody: no change is a single cursor line" {
    const alloc = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc,
        \\{"rows":24,"cols":80,"cursor_row":4,"cursor_col":17,
        \\ "range_start":1,"range_end":24,"full":false,"changed":[]}
    , .{});
    defer parsed.deinit();
    const out = try formatDiffBody(alloc, parsed.value.object);
    defer alloc.free(out);
    try std.testing.expectEqualStrings("no change (cursor 4,17)\n", out);
}
