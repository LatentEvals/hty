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

/// Strip trailing spaces from every line of a rendered plain-text frame.
/// The screen buffer pads each row to the full terminal width; a terminal
/// pads short lines itself, so the padding carries no information and only
/// bloats agent transcripts (LatentEvals/hty#97). Caller owns the slice.
pub fn stripTrailingSpaces(alloc: Allocator, text: []const u8) ![]u8 {
    var out = std.array_list.Managed(u8).init(alloc);
    errdefer out.deinit();
    var lines = std.mem.splitScalar(u8, text, '\n');
    var first = true;
    while (lines.next()) |line| {
        if (!first) try out.append('\n');
        first = false;
        try out.appendSlice(std.mem.trimEnd(u8, line, " "));
    }
    return out.toOwnedSlice();
}

/// Print a plain snapshot `buffer`: trailing spaces stripped per line
/// (#97) and trailing fill-row runs collapsed (#98), plus a final
/// newline. Only for the plain rendering — `--ansi` output keeps trailing
/// cells because they can carry styling (e.g. a painted background).
pub fn printPlainSnapshot(text: []const u8) !void {
    const alloc = std.heap.c_allocator;
    const stripped = try stripTrailingSpaces(alloc, text);
    defer alloc.free(stripped);
    const collapsed = try collapseTrailingFillRows(alloc, stripped);
    defer if (collapsed) |owned| alloc.free(owned);
    try printRaw(collapsed orelse stripped);
    try printRaw("\n");
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

test "stripTrailingSpaces drops per-line padding, keeps inner spaces" {
    const alloc = std.testing.allocator;
    const stripped = try stripTrailingSpaces(alloc, "hello   \n  a b   \n\nend");
    defer alloc.free(stripped);
    try std.testing.expectEqualStrings("hello\n  a b\n\nend", stripped);
}

test "stripTrailingSpaces leaves unpadded text untouched" {
    const alloc = std.testing.allocator;
    const stripped = try stripTrailingSpaces(alloc, "no padding here");
    defer alloc.free(stripped);
    try std.testing.expectEqualStrings("no padding here", stripped);
}

/// Minimum length of a trailing fill-row run before it is collapsed into
/// a marker line; shorter runs read fine as-is and a marker would not
/// save anything.
const collapse_min_run = 3;

/// A trailing run of visually identical fill rows: rows[start..end) all
/// render as `content` (their shared right-trimmed text).
const FillRun = struct {
    start: usize,
    end: usize,
    content: []const u8,
};

/// Collapse trailing runs of identical fill rows in a plain snapshot into
/// single marker lines: `~ ×14` for fourteen `~` rows, `×14` for fourteen
/// blank ones. A fill row is a row that is blank or a single character
/// once trailing spaces (terminal padding) are ignored. Runs of different
/// fill rows never merge into one marker — vim's blank-row-vs-`~`-row
/// distinction at the end of a buffer is how a trailing blank line at EOF
/// is visible at all. Only the tail of the frame is touched; identical
/// rows above a non-fill row are real content and stay as-is. The marker
/// uses `×` (U+00D7), which terminal programs do not emit as a fill
/// character, so it cannot be mistaken for a rendered row. Returns the
/// collapsed text (caller owns) or null when nothing collapses.
pub fn collapseTrailingFillRows(alloc: Allocator, buffer: []const u8) !?[]u8 {
    var rows = std.array_list.Managed([]const u8).init(alloc);
    defer rows.deinit();
    var row_iter = std.mem.splitScalar(u8, buffer, '\n');
    while (row_iter.next()) |row| try rows.append(row);

    // Walk runs of matching fill rows bottom-up; `head` ends up at the
    // first row that belongs to the collapsible tail.
    var runs = std.array_list.Managed(FillRun).init(alloc);
    defer runs.deinit();
    var head = rows.items.len;
    while (head > 0) {
        const content = std.mem.trimEnd(u8, rows.items[head - 1], " ");
        if (content.len > 1) break;
        var start = head - 1;
        while (start > 0) {
            const above = std.mem.trimEnd(u8, rows.items[start - 1], " ");
            if (!std.mem.eql(u8, above, content)) break;
            start -= 1;
        }
        try runs.append(.{ .start = start, .end = head, .content = content });
        head = start;
    }

    var collapses = false;
    for (runs.items) |run| {
        if (run.end - run.start >= collapse_min_run) collapses = true;
    }
    if (!collapses) return null;

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    for (rows.items[0..head]) |row| {
        try out.writer.writeAll(row);
        try out.writer.writeAll("\n");
    }
    // Runs were collected bottom-up; emit them top-down.
    var run_idx = runs.items.len;
    while (run_idx > 0) {
        run_idx -= 1;
        const run = runs.items[run_idx];
        if (run.end - run.start >= collapse_min_run) {
            if (run.content.len == 0) {
                try out.writer.print("×{d}", .{run.end - run.start});
            } else {
                try out.writer.print("{s} ×{d}", .{ run.content, run.end - run.start });
            }
            if (run_idx > 0) try out.writer.writeAll("\n");
        } else {
            for (rows.items[run.start..run.end], run.start..) |row, i| {
                try out.writer.writeAll(row);
                if (run_idx > 0 or i + 1 < run.end) try out.writer.writeAll("\n");
            }
        }
    }
    return try out.toOwnedSlice();
}

test "trailing run of padded ~ fill rows collapses with the count" {
    const buffer = "hello\n" ++
        ("~" ++ " " ** 79 ++ "\n") ** 4 ++
        "~" ++ " " ** 79;
    const collapsed = (try collapseTrailingFillRows(std.testing.allocator, buffer)).?;
    defer std.testing.allocator.free(collapsed);
    try std.testing.expectEqualStrings("hello\n~ ×5", collapsed);
}

test "mixed ~ and blank tail runs collapse separately, never merging" {
    const buffer = "hello\n~\n~\n~\n\n\n";
    const collapsed = (try collapseTrailingFillRows(std.testing.allocator, buffer)).?;
    defer std.testing.allocator.free(collapsed);
    try std.testing.expectEqualStrings("hello\n~ ×3\n×3", collapsed);
}

test "identical rows above a non-fill row stay untouched" {
    const buffer = "~\n~\n~\n~\n\"file\" [New File]";
    try std.testing.expectEqual(
        null,
        try collapseTrailingFillRows(std.testing.allocator, buffer),
    );
}

test "short fill runs stay untouched" {
    const buffer = "hello\n~\n~";
    try std.testing.expectEqual(
        null,
        try collapseTrailingFillRows(std.testing.allocator, buffer),
    );
}

test "a sub-threshold run below a collapsed one is kept verbatim" {
    const buffer = "hello\n\n\n\n\n~";
    const collapsed = (try collapseTrailingFillRows(std.testing.allocator, buffer)).?;
    defer std.testing.allocator.free(collapsed);
    try std.testing.expectEqualStrings("hello\n×4\n~", collapsed);
}

/// Row range for `--lines N:M`. 1-indexed, inclusive. A null `end` means
/// "through the last row" (`N:`).
pub const LineRange = struct {
    start: usize,
    end: ?usize,
};

/// Parse a `--lines` value: `N:M`, `N:` (row N through the last row), or
/// `:M` (first row through row M). Rows are 1-indexed and the range is
/// inclusive, matching snapshot's row conventions.
pub fn parseLineRange(text: []const u8) !LineRange {
    const colon = std.mem.indexOfScalar(u8, text, ':') orelse return error.InvalidLineRange;
    const start_str = text[0..colon];
    const end_str = text[colon + 1 ..];
    if (start_str.len == 0 and end_str.len == 0) return error.InvalidLineRange;
    const start: usize = if (start_str.len == 0)
        1
    else
        std.fmt.parseInt(usize, start_str, 10) catch return error.InvalidLineRange;
    const end: ?usize = if (end_str.len == 0)
        null
    else
        std.fmt.parseInt(usize, end_str, 10) catch return error.InvalidLineRange;
    if (start == 0) return error.InvalidLineRange;
    if (end) |e| {
        if (e == 0 or e < start) return error.InvalidLineRange;
    }
    return .{ .start = start, .end = end };
}

/// Slice rows [start, end] out of a newline-joined frame (both `buffer`
/// and `screen_ansi` join rows with a single '\n' and no trailing
/// newline). An end past the last row is clamped, tmux capture-pane
/// style; a start past the last row yields an empty slice.
pub fn sliceLines(text: []const u8, range: LineRange) []const u8 {
    var start_off: usize = 0;
    var row: usize = 1;
    while (row < range.start) : (row += 1) {
        const nl = std.mem.indexOfScalarPos(u8, text, start_off, '\n') orelse
            return text[text.len..];
        start_off = nl + 1;
    }
    const last = range.end orelse return text[start_off..];
    var end_off: usize = start_off;
    row = range.start;
    while (true) {
        const nl = std.mem.indexOfScalarPos(u8, text, end_off, '\n') orelse {
            end_off = text.len;
            break;
        };
        if (row == last) {
            end_off = nl;
            break;
        }
        end_off = nl + 1;
        row += 1;
    }
    return text[start_off..end_off];
}

test "parseLineRange accepts N:M, N:, and :M" {
    const closed = try parseLineRange("22:24");
    try std.testing.expectEqual(@as(usize, 22), closed.start);
    try std.testing.expectEqual(@as(?usize, 24), closed.end);

    const open_end = try parseLineRange("20:");
    try std.testing.expectEqual(@as(usize, 20), open_end.start);
    try std.testing.expectEqual(@as(?usize, null), open_end.end);

    const open_start = try parseLineRange(":5");
    try std.testing.expectEqual(@as(usize, 1), open_start.start);
    try std.testing.expectEqual(@as(?usize, 5), open_start.end);

    const single = try parseLineRange("3:3");
    try std.testing.expectEqual(@as(usize, 3), single.start);
    try std.testing.expectEqual(@as(?usize, 3), single.end);
}

test "parseLineRange rejects malformed and inverted ranges" {
    try std.testing.expectError(error.InvalidLineRange, parseLineRange(""));
    try std.testing.expectError(error.InvalidLineRange, parseLineRange(":"));
    try std.testing.expectError(error.InvalidLineRange, parseLineRange("5"));
    try std.testing.expectError(error.InvalidLineRange, parseLineRange("a:b"));
    try std.testing.expectError(error.InvalidLineRange, parseLineRange("1:x"));
    try std.testing.expectError(error.InvalidLineRange, parseLineRange("0:3"));
    try std.testing.expectError(error.InvalidLineRange, parseLineRange("3:0"));
    try std.testing.expectError(error.InvalidLineRange, parseLineRange("4:2"));
    try std.testing.expectError(error.InvalidLineRange, parseLineRange("-1:2"));
}

test "sliceLines extracts closed, open-ended, and open-start ranges" {
    const frame = "row1\nrow2\nrow3\nrow4\nrow5";
    try std.testing.expectEqualStrings("row2\nrow3", sliceLines(frame, .{ .start = 2, .end = 3 }));
    try std.testing.expectEqualStrings("row4\nrow5", sliceLines(frame, .{ .start = 4, .end = null }));
    try std.testing.expectEqualStrings("row1\nrow2", sliceLines(frame, .{ .start = 1, .end = 2 }));
    try std.testing.expectEqualStrings("row3", sliceLines(frame, .{ .start = 3, .end = 3 }));
    try std.testing.expectEqualStrings(frame, sliceLines(frame, .{ .start = 1, .end = null }));
}

test "sliceLines clamps out-of-range rows" {
    const frame = "row1\nrow2\nrow3";
    // End past the last row: clamp to the last row.
    try std.testing.expectEqualStrings("row2\nrow3", sliceLines(frame, .{ .start = 2, .end = 99 }));
    try std.testing.expectEqualStrings(frame, sliceLines(frame, .{ .start = 1, .end = 99 }));
    // Start past the last row: empty output.
    try std.testing.expectEqualStrings("", sliceLines(frame, .{ .start = 4, .end = null }));
    try std.testing.expectEqualStrings("", sliceLines(frame, .{ .start = 10, .end = 12 }));
}
