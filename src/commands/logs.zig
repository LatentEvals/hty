//! `hty logs` — print the JSONL event log for a session.

const std = @import("std");
const Allocator = std.mem.Allocator;

const common = @import("common.zig");
const paths = @import("../paths.zig");
const json_mod = @import("../json.zig");
const getString = json_mod.getString;
const getInteger = json_mod.getInteger;
const decodeHex = @import("../hex.zig").decodeHex;

const c = @cImport({
    @cInclude("time.h");
});

pub fn helpText() []const u8 {
    return
    \\hty logs [SESSION] [--follow|-f] [--since DURATION] [--json]
    \\
    \\Print the JSONL event log for a session. Logs are read directly from
    \\disk, so this works for sessions that have already exited and even
    \\across server restarts.
    \\
    \\SESSION may be a --name, a full UUID, or any unambiguous prefix. If
    \\omitted and exactly one log file exists, that one is used.
    \\
    \\Flags:
    \\  --follow, -f     Tail the log as new events arrive.
    \\  --since DURATION Only show events within the last DURATION of logged
    \\                   activity. Accepts: 500ms, 5s, 1m, 2h, or a bare
    \\                   integer (seconds).
    \\  --json           Emit raw JSONL lines (one per event) instead of the
    \\                   human-readable table.
    \\
    \\Logs live at \$XDG_STATE_HOME/hty/logs (fallback ~/.local/state/hty/logs).
    \\
    ;
}

const LogsOptions = struct {
    session: ?[]const u8 = null,
    follow: bool = false,
    since_ms: ?u64 = null,
    json: bool = false,
};

pub fn run(alloc: Allocator, args: []const []const u8) !void {
    var opts = LogsOptions{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--follow") or std.mem.eql(u8, arg, "-f")) {
            opts.follow = true;
        } else if (std.mem.eql(u8, arg, "--json")) {
            opts.json = true;
        } else if (std.mem.eql(u8, arg, "--since")) {
            i += 1;
            if (i >= args.len) common.printUsageAndExit("--since requires an argument");
            opts.since_ms = common.parseDurationMs(args[i]) catch {
                common.printUsageAndExit("--since value is not a valid duration (examples: 5s, 1m, 500ms, 30)");
            };
        } else if (std.mem.startsWith(u8, arg, "--")) {
            common.printUsageAndExit("unknown flag for `hty logs`");
        } else {
            if (opts.session != null) common.printUsageAndExit("only one session argument is allowed");
            opts.session = arg;
        }
    }

    const path = resolveLogPath(alloc, opts.session) catch |err| {
        switch (err) {
            error.SessionNotFound => try common.printErr("session log not found"),
            error.AmbiguousPrefix => try common.printErr("ambiguous session prefix"),
            error.AmbiguousSole => try common.printErr("more than one session log exists — name one explicitly"),
            else => try common.printErrFmt("failed to resolve session log: {s}", .{@errorName(err)}),
        }
        std.process.exit(common.ExitCode.not_found);
    };
    defer alloc.free(path);

    const file = std.fs.openFileAbsolute(path, .{ .mode = .read_only }) catch |err| {
        try common.printErrFmt("cannot open {s}: {s}", .{ path, @errorName(err) });
        std.process.exit(common.ExitCode.generic);
    };
    defer file.close();

    var buffered = std.array_list.Managed(u8).init(alloc);
    defer buffered.deinit();

    // Initial pass: read the whole file into memory. This keeps the filter
    // logic simple — we can't know the "last event timestamp" without seeing
    // every line, and even multi-megabyte logs are fine to load wholesale.
    const initial = file.readToEndAlloc(alloc, 64 * 1024 * 1024) catch |err| {
        try common.printErrFmt("read failed: {s}", .{@errorName(err)});
        std.process.exit(common.ExitCode.generic);
    };
    defer alloc.free(initial);

    const cutoff_ms: ?i64 = blk: {
        if (opts.since_ms) |since| {
            const last = lastTimestampInJsonl(initial) orelse break :blk null;
            break :blk last - @as(i64, @intCast(since));
        }
        break :blk null;
    };

    if (!opts.json) {
        try common.printLine("TIMESTAMP               KIND     DETAIL");
    }

    var file_pos: u64 = initial.len;
    try printJsonlLines(alloc, initial, cutoff_ms, opts.json);

    if (!opts.follow) return;

    // Follow loop: poll the file size and print new appended lines as they
    // appear. No inotify — append-only logs make size-watching sufficient.
    var leftover = std.array_list.Managed(u8).init(alloc);
    defer leftover.deinit();

    while (true) {
        const stat = file.stat() catch break;
        if (stat.size > file_pos) {
            try file.seekTo(file_pos);
            const remaining = stat.size - file_pos;
            const bytes = try alloc.alloc(u8, @intCast(remaining));
            defer alloc.free(bytes);
            const n = file.readAll(bytes) catch break;
            file_pos += @intCast(n);

            try leftover.appendSlice(bytes[0..n]);
            // Split on '\n' and print whole lines. Any trailing partial line
            // stays in `leftover` for the next iteration.
            var start: usize = 0;
            var idx: usize = 0;
            while (idx < leftover.items.len) : (idx += 1) {
                if (leftover.items[idx] == '\n') {
                    try printJsonlLine(alloc, leftover.items[start..idx], null, opts.json);
                    start = idx + 1;
                }
            }
            if (start > 0) {
                std.mem.copyForwards(u8, leftover.items[0..], leftover.items[start..]);
                leftover.shrinkRetainingCapacity(leftover.items.len - start);
            }
        }
        std.Thread.sleep(50 * std.time.ns_per_ms);
    }
}

fn printJsonlLines(alloc: Allocator, bytes: []const u8, cutoff_ms: ?i64, json_mode: bool) !void {
    var it = std.mem.splitScalar(u8, bytes, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        try printJsonlLine(alloc, line, cutoff_ms, json_mode);
    }
}

fn printJsonlLine(alloc: Allocator, line: []const u8, cutoff_ms: ?i64, json_mode: bool) !void {
    if (line.len == 0) return;

    var parsed = std.json.parseFromSlice(std.json.Value, alloc, line, .{}) catch {
        // Corrupt line — skip silently.
        return;
    };
    defer parsed.deinit();

    if (parsed.value != .object) return;
    const obj = parsed.value.object;
    const t = switch (obj.get("t") orelse return) {
        .integer => |v| v,
        else => return,
    };
    if (cutoff_ms) |cut| {
        if (t < cut) return;
    }

    if (json_mode) {
        try common.printLine(line);
        return;
    }

    try printFormattedEvent(alloc, obj, t);
}

fn printFormattedEvent(alloc: Allocator, obj: std.json.ObjectMap, t: i64) !void {
    var ts_buf: [32]u8 = undefined;
    const ts = formatLocalIsoMs(&ts_buf, t);

    const kind_val = obj.get("kind") orelse return;
    if (kind_val != .string) return;
    const kind = kind_val.string;

    const detail = try buildEventDetail(alloc, kind, obj);
    defer alloc.free(detail);

    const line = try std.fmt.allocPrint(alloc, "{s}  {s: <7}  {s}", .{ ts, kind, detail });
    defer alloc.free(line);
    try common.printLine(line);
}

fn buildEventDetail(alloc: Allocator, kind: []const u8, obj: std.json.ObjectMap) ![]u8 {
    if (std.mem.eql(u8, kind, "spawn")) {
        const program = getString(obj, "program") orelse "";
        const rows = getInteger(obj, "rows") orelse 0;
        const cols = getInteger(obj, "cols") orelse 0;
        var args_text = std.array_list.Managed(u8).init(alloc);
        defer args_text.deinit();
        if (obj.get("args")) |args_val| {
            if (args_val == .array) {
                for (args_val.array.items) |item| {
                    if (item == .string) {
                        try args_text.append(' ');
                        try args_text.appendSlice(item.string);
                    }
                }
            }
        }
        return try std.fmt.allocPrint(alloc, "{s}{s} ({d}x{d})", .{ program, args_text.items, rows, cols });
    }
    if (std.mem.eql(u8, kind, "input") or std.mem.eql(u8, kind, "output")) {
        const hex = getString(obj, "bytes_hex") orelse "";
        const nbytes = hex.len / 2;
        // For printable ASCII input, show the quoted string; else show hex.
        if (std.mem.eql(u8, kind, "input") and nbytes > 0 and nbytes <= 32) {
            var arena_state = std.heap.ArenaAllocator.init(alloc);
            defer arena_state.deinit();
            if (decodeHex(arena_state.allocator(), hex) catch null) |decoded| {
                if (isMostlyPrintable(decoded)) {
                    return try std.fmt.allocPrint(alloc, "{s} ({d} byte{s})", .{
                        try quoteForDisplay(alloc, decoded),
                        nbytes,
                        if (nbytes == 1) "" else "s",
                    });
                }
            }
        }
        const preview_len = @min(hex.len, 16);
        const preview = hex[0..preview_len];
        const ellipsis: []const u8 = if (hex.len > preview_len) "..." else "";
        return try std.fmt.allocPrint(alloc, "{s}{s} ({d} bytes)", .{ preview, ellipsis, nbytes });
    }
    if (std.mem.eql(u8, kind, "title")) {
        const title = getString(obj, "title") orelse "";
        return try std.fmt.allocPrint(alloc, "\"{s}\"", .{title});
    }
    if (std.mem.eql(u8, kind, "exited")) {
        const code = getInteger(obj, "code") orelse 0;
        return try std.fmt.allocPrint(alloc, "code={d}", .{code});
    }
    if (std.mem.eql(u8, kind, "failure")) {
        const message = getString(obj, "message") orelse "";
        return try std.fmt.allocPrint(alloc, "{s}", .{message});
    }
    // bell, killed, anything else: no detail.
    return try alloc.dupe(u8, "");
}

fn isMostlyPrintable(bytes: []const u8) bool {
    var printable: usize = 0;
    for (bytes) |b| {
        if ((b >= 0x20 and b < 0x7f) or b == '\n' or b == '\r' or b == '\t') printable += 1;
    }
    return printable * 4 >= bytes.len * 3;
}

fn quoteForDisplay(alloc: Allocator, bytes: []const u8) ![]u8 {
    var out = std.array_list.Managed(u8).init(alloc);
    errdefer out.deinit();
    try out.append('"');
    for (bytes) |b| {
        switch (b) {
            '\n' => try out.appendSlice("\\n"),
            '\r' => try out.appendSlice("\\r"),
            '\t' => try out.appendSlice("\\t"),
            '"' => try out.appendSlice("\\\""),
            '\\' => try out.appendSlice("\\\\"),
            else => if (b >= 0x20 and b < 0x7f) try out.append(b) else {
                var hex_buf: [4]u8 = undefined;
                const formatted = try std.fmt.bufPrint(&hex_buf, "\\x{x:0>2}", .{b});
                try out.appendSlice(formatted);
            },
        }
    }
    try out.append('"');
    return out.toOwnedSlice();
}

pub fn lastTimestampInJsonl(bytes: []const u8) ?i64 {
    // Walk backwards to find the last non-empty line, parse its `t`.
    var end = bytes.len;
    while (end > 0 and bytes[end - 1] == '\n') end -= 1;
    if (end == 0) return null;
    var start = end;
    while (start > 0 and bytes[start - 1] != '\n') start -= 1;
    const line = bytes[start..end];
    // Minimal extraction: look for "t":N
    const needle = "\"t\":";
    const pos = std.mem.indexOf(u8, line, needle) orelse return null;
    var i = pos + needle.len;
    while (i < line.len and line[i] == ' ') i += 1;
    const num_start = i;
    while (i < line.len and (line[i] == '-' or (line[i] >= '0' and line[i] <= '9'))) i += 1;
    if (i == num_start) return null;
    return std.fmt.parseInt(i64, line[num_start..i], 10) catch null;
}

fn formatLocalIsoMs(buf: []u8, ms: i64) []const u8 {
    var t: c.time_t = @intCast(@divTrunc(ms, 1000));
    const tm_opt = c.localtime(&t);
    const millis: u32 = @intCast(@mod(ms, 1000));
    if (tm_opt) |tm_ptr| {
        const tm = tm_ptr.*;
        return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}", .{
            @as(u16, @intCast(tm.tm_year + 1900)),
            @as(u8, @intCast(tm.tm_mon + 1)),
            @as(u8, @intCast(tm.tm_mday)),
            @as(u8, @intCast(tm.tm_hour)),
            @as(u8, @intCast(tm.tm_min)),
            @as(u8, @intCast(tm.tm_sec)),
            millis,
        }) catch "????-??-??T??:??:??.???";
    }
    return std.fmt.bufPrint(buf, "{d}", .{ms}) catch "?";
}

pub fn resolveLogPath(alloc: Allocator, reference: ?[]const u8) ![]u8 {
    const log_dir = try paths.resolveLogDir(alloc);
    defer alloc.free(log_dir);

    if (reference) |ref| {
        // 1. by-name symlink
        const name_path = try std.fmt.allocPrint(alloc, "{s}/by-name/{s}.jsonl", .{ log_dir, ref });
        if (fileExistsAbsolute(name_path)) return name_path;
        alloc.free(name_path);

        // 2. exact UUID
        const uuid_path = try std.fmt.allocPrint(alloc, "{s}/{s}.jsonl", .{ log_dir, ref });
        if (fileExistsAbsolute(uuid_path)) return uuid_path;
        alloc.free(uuid_path);

        // 3. prefix match
        var dir = try std.fs.openDirAbsolute(log_dir, .{ .iterate = true });
        defer dir.close();
        var it = dir.iterate();
        var match: ?[]u8 = null;
        errdefer if (match) |m| alloc.free(m);
        while (try it.next()) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".jsonl")) continue;
            const stem = entry.name[0 .. entry.name.len - ".jsonl".len];
            if (!std.mem.startsWith(u8, stem, ref)) continue;
            if (match != null) {
                alloc.free(match.?);
                match = null;
                return error.AmbiguousPrefix;
            }
            match = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ log_dir, entry.name });
        }
        if (match) |m| return m;
        return error.SessionNotFound;
    }

    // No reference: if exactly one .jsonl file exists, use it.
    var dir = try std.fs.openDirAbsolute(log_dir, .{ .iterate = true });
    defer dir.close();
    var it = dir.iterate();
    var sole: ?[]u8 = null;
    errdefer if (sole) |s| alloc.free(s);
    while (try it.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".jsonl")) continue;
        if (sole != null) {
            alloc.free(sole.?);
            sole = null;
            return error.AmbiguousSole;
        }
        sole = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ log_dir, entry.name });
    }
    if (sole) |s| return s;
    return error.SessionNotFound;
}

pub fn fileExistsAbsolute(path: []const u8) bool {
    std.fs.accessAbsolute(path, .{}) catch return false;
    return true;
}

// ============================================================================
// Tests
// ============================================================================

test "parseDurationMs accepts bare integers, ms, s, m, h" {
    try std.testing.expectEqual(@as(u64, 5_000), try common.parseDurationMs("5"));
    try std.testing.expectEqual(@as(u64, 500), try common.parseDurationMs("500ms"));
    try std.testing.expectEqual(@as(u64, 10_000), try common.parseDurationMs("10s"));
    try std.testing.expectEqual(@as(u64, 60_000), try common.parseDurationMs("1m"));
    try std.testing.expectEqual(@as(u64, 2 * 60 * 60 * 1000), try common.parseDurationMs("2h"));
    try std.testing.expectError(error.InvalidDuration, common.parseDurationMs(""));
    try std.testing.expectError(error.InvalidDuration, common.parseDurationMs("abc"));
    try std.testing.expectError(error.InvalidDuration, common.parseDurationMs("5d"));
}

test "lastTimestampInJsonl finds the last t field" {
    const log =
        \\{"t":100,"kind":"spawn"}
        \\{"t":250,"kind":"output"}
        \\{"t":999,"kind":"exited"}
        \\
    ;
    try std.testing.expectEqual(@as(i64, 999), lastTimestampInJsonl(log).?);
}

test "lastTimestampInJsonl tolerates a trailing partial line" {
    const log =
        \\{"t":100,"kind":"spawn"}
        \\{"t":200,"kind":"output"}
    ;
    try std.testing.expectEqual(@as(i64, 200), lastTimestampInJsonl(log).?);
}

test "lastTimestampInJsonl returns null on empty input" {
    try std.testing.expect(lastTimestampInJsonl("") == null);
    try std.testing.expect(lastTimestampInJsonl("\n") == null);
}

test "isMostlyPrintable recognizes ascii" {
    try std.testing.expect(isMostlyPrintable("hello"));
    try std.testing.expect(isMostlyPrintable("hi there\n"));
    try std.testing.expect(!isMostlyPrintable("\x00\x01\x02"));
}

test "quoteForDisplay escapes unusual bytes" {
    const out = try quoteForDisplay(std.testing.allocator, "hi\n\ta");
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("\"hi\\n\\ta\"", out);
}
