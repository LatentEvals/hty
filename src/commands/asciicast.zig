//! Convert a recorded hty session log into the asciinema v2 `.cast` format.
//!
//! An asciicast v2 file is a JSONL stream:
//!
//!     {"version":2,"width":W,"height":H,"timestamp":UNIX,"env":{"TERM":"..."}}
//!     [elapsed_seconds, "o", "decoded bytes as JSON string"]
//!     [elapsed_seconds, "r", "COLSxROWS"]
//!     ...
//!
//! The first element of each event array is *elapsed seconds since the
//! session started*, not an absolute timestamp. We derive it from the `t`
//! field on the spawn event (ms since unix epoch).
//!
//! `output`, `resize`, and `input` events become cast events. Input bursts are
//! *coalesced*: consecutive `input` events less than `INPUT_COALESCE_MS` apart
//! collapse to a single `"i"` event with the concatenated payload, timestamped
//! at the first event in the burst. Rationale: `hty send --text "hello"` lands
//! as five `input` records microseconds apart; users think of that as one
//! `hello` keystroke, not five.
//!
//! A non-input event (output, resize) between two inputs flushes the pending
//! input buffer first so we never reorder relative to the rest of the stream.
//!
//! Note: asciinema-player, agg, and vhs all ignore `"i"` events during
//! playback today, but they're valid per the v2 spec and any future renderer
//! that wants to surface agent keystrokes has the data.
//!
//! Pure — no I/O; the caller is responsible for writing `stdout`-bound bytes.

const std = @import("std");
const Allocator = std.mem.Allocator;

const json_mod = @import("../json.zig");
const getString = json_mod.getString;
const getInteger = json_mod.getInteger;
const decodeHex = @import("../hex.zig").decodeHex;

/// Input events closer than this in wall-clock time are merged into one
/// asciicast `"i"` event. 10ms is enough to fuse a multi-byte keystroke
/// burst (`send --text "hello"`) without swallowing a human typing pauses.
pub const INPUT_COALESCE_MS: i64 = 10;

/// Serialize `log_bytes` (the raw JSONL contents of a session log) as an
/// asciicast v2 document written to `writer`. Malformed lines are tolerated
/// and skipped, matching the rest of the log-reading code.
pub fn writeCast(
    alloc: Allocator,
    writer: *std.Io.Writer,
    log_bytes: []const u8,
) !void {
    // Parse the spawn line for initial geometry + session start timestamp.
    var lines = std.mem.splitScalar(u8, log_bytes, '\n');
    const spawn_line = lines.next() orelse return error.EmptyLog;
    if (spawn_line.len == 0) return error.EmptyLog;

    var spawn_parsed = std.json.parseFromSlice(std.json.Value, alloc, spawn_line, .{}) catch {
        return error.BadSpawnLine;
    };
    defer spawn_parsed.deinit();
    if (spawn_parsed.value != .object) return error.BadSpawnLine;
    const spawn_obj = spawn_parsed.value.object;

    const start_ms = getInteger(spawn_obj, "t") orelse return error.BadSpawnLine;
    const rows: u32 = blk: {
        const r = getInteger(spawn_obj, "rows") orelse 24;
        if (r < 0) break :blk 24;
        break :blk @intCast(r);
    };
    const cols: u32 = blk: {
        const c_ = getInteger(spawn_obj, "cols") orelse 80;
        if (c_ < 0) break :blk 80;
        break :blk @intCast(c_);
    };

    // Header. Timestamp is unix seconds (integer), matching the asciicast
    // convention. We always include `env.TERM` — hty's standard env uses
    // xterm-256color and the spawn record doesn't carry the child's TERM,
    // so hard-coding the baseline is the least-surprising option.
    try writer.print(
        "{{\"version\":2,\"width\":{d},\"height\":{d},\"timestamp\":{d},\"env\":{{\"TERM\":\"xterm-256color\"}}}}\n",
        .{ cols, rows, @divTrunc(start_ms, 1000) },
    );

    // Event loop with a pending-input buffer for coalescing. The buffer
    // holds the decoded bytes of consecutive `input` events; we flush it
    // whenever (a) the next input is further than INPUT_COALESCE_MS from
    // the last one, (b) a non-input event arrives, or (c) the log ends.
    var pending = std.array_list.Managed(u8).init(alloc);
    defer pending.deinit();
    var pending_start_ms: i64 = 0;
    var pending_last_ms: i64 = 0;

    while (lines.next()) |line| {
        if (line.len == 0) continue;
        processLine(alloc, writer, line, start_ms, &pending, &pending_start_ms, &pending_last_ms) catch continue;
    }

    // Drain any trailing input burst.
    if (pending.items.len > 0) {
        try emitInput(writer, pending.items, pending_start_ms - start_ms);
        pending.clearRetainingCapacity();
    }
}

fn processLine(
    alloc: Allocator,
    writer: *std.Io.Writer,
    line: []const u8,
    start_ms: i64,
    pending: *std.array_list.Managed(u8),
    pending_start_ms: *i64,
    pending_last_ms: *i64,
) !void {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, line, .{}) catch return error.BadLine;
    defer parsed.deinit();
    if (parsed.value != .object) return error.BadLine;
    const obj = parsed.value.object;

    const kind = getString(obj, "kind") orelse return error.BadLine;
    const t = getInteger(obj, "t") orelse return error.BadLine;

    if (std.mem.eql(u8, kind, "input")) {
        const hex = getString(obj, "bytes_hex") orelse return error.BadLine;
        const decoded = decodeHex(alloc, hex) catch return error.BadLine;
        defer alloc.free(decoded);

        if (pending.items.len == 0) {
            // Start a new burst.
            pending_start_ms.* = t;
            pending_last_ms.* = t;
            try pending.appendSlice(decoded);
        } else if (t - pending_last_ms.* < INPUT_COALESCE_MS) {
            // Still within the coalesce window — append.
            pending_last_ms.* = t;
            try pending.appendSlice(decoded);
        } else {
            // Gap too large: flush the previous burst and start a new one.
            try emitInput(writer, pending.items, pending_start_ms.* - start_ms);
            pending.clearRetainingCapacity();
            pending_start_ms.* = t;
            pending_last_ms.* = t;
            try pending.appendSlice(decoded);
        }
        return;
    }

    // Non-input event: flush any pending input before emitting so the
    // output stream stays in chronological order.
    if (pending.items.len > 0) {
        try emitInput(writer, pending.items, pending_start_ms.* - start_ms);
        pending.clearRetainingCapacity();
    }

    // Elapsed can end up very slightly negative if the first post-spawn event
    // was recorded at the same millisecond as spawn but ordered differently;
    // clamp to zero so downstream parsers don't choke.
    const delta_ms: i64 = if (t > start_ms) t - start_ms else 0;
    const elapsed: f64 = @as(f64, @floatFromInt(delta_ms)) / 1000.0;

    if (std.mem.eql(u8, kind, "output")) {
        const hex = getString(obj, "bytes_hex") orelse return error.BadLine;
        const decoded = decodeHex(alloc, hex) catch return error.BadLine;
        defer alloc.free(decoded);

        try writer.print("[{d:.6}, \"o\", ", .{elapsed});
        try writeSanitizedJsonString(writer, decoded);
        try writer.writeAll("]\n");
    } else if (std.mem.eql(u8, kind, "resize")) {
        const rr = getInteger(obj, "rows") orelse return error.BadLine;
        const cc = getInteger(obj, "cols") orelse return error.BadLine;
        try writer.print("[{d:.6}, \"r\", \"{d}x{d}\"]\n", .{ elapsed, cc, rr });
    }
    // Everything else (title, bell, exited, failure, killed, spawn)
    // has no cast-v2 equivalent we want to emit.
}

fn emitInput(writer: *std.Io.Writer, bytes: []const u8, delta_ms: i64) !void {
    const clamped: i64 = if (delta_ms > 0) delta_ms else 0;
    const elapsed: f64 = @as(f64, @floatFromInt(clamped)) / 1000.0;
    try writer.print("[{d:.6}, \"i\", ", .{elapsed});
    try writeSanitizedJsonString(writer, bytes);
    try writer.writeAll("]\n");
}

/// Write `bytes` as a JSON string, replacing invalid UTF-8 sequences with
/// U+FFFD so the downstream parser never sees bare high bytes that aren't
/// part of a valid UTF-8 codepoint. Control characters get `\uXXXX` escapes.
fn writeSanitizedJsonString(writer: *std.Io.Writer, bytes: []const u8) !void {
    try writer.writeByte('"');
    var i: usize = 0;
    while (i < bytes.len) {
        const b = bytes[i];
        if (b < 0x80) {
            // ASCII fast path.
            switch (b) {
                '"' => try writer.writeAll("\\\""),
                '\\' => try writer.writeAll("\\\\"),
                '\n' => try writer.writeAll("\\n"),
                '\r' => try writer.writeAll("\\r"),
                '\t' => try writer.writeAll("\\t"),
                0x08 => try writer.writeAll("\\b"),
                0x0c => try writer.writeAll("\\f"),
                0...0x07, 0x0b, 0x0e...0x1f, 0x7f => try writer.print("\\u{x:0>4}", .{b}),
                else => try writer.writeByte(b),
            }
            i += 1;
            continue;
        }

        // Multi-byte UTF-8. Validate the sequence length and body; on any
        // failure emit U+FFFD and advance by one byte so we can resync.
        const seq_len = std.unicode.utf8ByteSequenceLength(b) catch {
            try writer.writeAll("\u{FFFD}");
            i += 1;
            continue;
        };
        if (i + seq_len > bytes.len) {
            try writer.writeAll("\u{FFFD}");
            i += 1;
            continue;
        }
        const seq = bytes[i .. i + seq_len];
        _ = std.unicode.utf8Decode(seq) catch {
            try writer.writeAll("\u{FFFD}");
            i += 1;
            continue;
        };
        try writer.writeAll(seq);
        i += seq_len;
    }
    try writer.writeByte('"');
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

fn runWriteCast(alloc: Allocator, log: []const u8) ![]u8 {
    var out = std.array_list.Managed(u8).init(alloc);
    errdefer out.deinit();
    const w = out.writer().any();
    try writeCast(alloc, w, log);
    return out.toOwnedSlice();
}

fn parseJsonOwned(alloc: Allocator, bytes: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, alloc, bytes, .{});
}

test "cast header carries version, width, height, timestamp" {
    const alloc = testing.allocator;
    const log =
        \\{"t":1700000000000,"kind":"spawn","program":"cat","args":[],"rows":24,"cols":80}
        \\{"t":1700000000100,"kind":"output","bytes_hex":"68690a"}
    ;
    const cast = try runWriteCast(alloc, log);
    defer alloc.free(cast);

    const nl = std.mem.indexOfScalar(u8, cast, '\n').?;
    const header = cast[0..nl];

    var parsed = try parseJsonOwned(alloc, header);
    defer parsed.deinit();
    try testing.expect(parsed.value == .object);
    const obj = parsed.value.object;

    try testing.expectEqual(@as(i64, 2), obj.get("version").?.integer);
    try testing.expectEqual(@as(i64, 80), obj.get("width").?.integer);
    try testing.expectEqual(@as(i64, 24), obj.get("height").?.integer);
    try testing.expectEqual(@as(i64, 1_700_000_000), obj.get("timestamp").?.integer);

    const env = obj.get("env").?;
    try testing.expect(env == .object);
    const term = env.object.get("TERM").?;
    try testing.expectEqualStrings("xterm-256color", term.string);
}

test "output events are emitted as 3-tuples with non-decreasing non-negative timestamps" {
    const alloc = testing.allocator;
    const log =
        \\{"t":1700000000000,"kind":"spawn","program":"cat","args":[],"rows":10,"cols":40}
        \\{"t":1700000000000,"kind":"output","bytes_hex":"68"}
        \\{"t":1700000000500,"kind":"output","bytes_hex":"69"}
        \\{"t":1700000001250,"kind":"output","bytes_hex":"0a"}
    ;
    const cast = try runWriteCast(alloc, log);
    defer alloc.free(cast);

    // Concatenate the payloads and make sure we round-tripped every byte.
    var concat = std.array_list.Managed(u8).init(alloc);
    defer concat.deinit();

    var prev_t: f64 = -1.0;
    var count: usize = 0;
    var it = std.mem.splitScalar(u8, cast, '\n');
    _ = it.next(); // skip header
    while (it.next()) |line| {
        if (line.len == 0) continue;
        var parsed = try parseJsonOwned(alloc, line);
        defer parsed.deinit();
        try testing.expect(parsed.value == .array);
        const arr = parsed.value.array.items;
        try testing.expectEqual(@as(usize, 3), arr.len);
        try testing.expect(arr[0] == .float or arr[0] == .integer);
        const t: f64 = switch (arr[0]) {
            .float => |f| f,
            .integer => |n| @floatFromInt(n),
            else => unreachable,
        };
        try testing.expect(t >= 0.0);
        try testing.expect(t >= prev_t);
        prev_t = t;

        try testing.expect(arr[1] == .string);
        try testing.expectEqualStrings("o", arr[1].string);

        try testing.expect(arr[2] == .string);
        try concat.appendSlice(arr[2].string);
        count += 1;
    }

    try testing.expectEqual(@as(usize, 3), count);
    try testing.expectEqualStrings("hi\n", concat.items);
}

test "first output at spawn time has elapsed ~ 0.0" {
    const alloc = testing.allocator;
    const log =
        \\{"t":1700000000000,"kind":"spawn","program":"cat","args":[],"rows":10,"cols":40}
        \\{"t":1700000000000,"kind":"output","bytes_hex":"61"}
        \\{"t":1700000002000,"kind":"output","bytes_hex":"62"}
    ;
    const cast = try runWriteCast(alloc, log);
    defer alloc.free(cast);

    var it = std.mem.splitScalar(u8, cast, '\n');
    _ = it.next();
    const first = it.next().?;
    var parsed = try parseJsonOwned(alloc, first);
    defer parsed.deinit();
    const first_t: f64 = switch (parsed.value.array.items[0]) {
        .float => |f| f,
        .integer => |n| @floatFromInt(n),
        else => return error.UnexpectedType,
    };
    try testing.expect(first_t >= 0.0 and first_t < 0.001);

    const second = it.next().?;
    var parsed2 = try parseJsonOwned(alloc, second);
    defer parsed2.deinit();
    const second_t: f64 = switch (parsed2.value.array.items[0]) {
        .float => |f| f,
        .integer => |n| @floatFromInt(n),
        else => return error.UnexpectedType,
    };
    try testing.expect(second_t > 1.99 and second_t < 2.01);
}

test "resize events become r-events with WxH payload at correct timestamp" {
    const alloc = testing.allocator;
    const log =
        \\{"t":1700000000000,"kind":"spawn","program":"cat","args":[],"rows":24,"cols":80}
        \\{"t":1700000000500,"kind":"output","bytes_hex":"61"}
        \\{"t":1700000001000,"kind":"resize","rows":40,"cols":120}
        \\{"t":1700000001500,"kind":"output","bytes_hex":"62"}
    ;
    const cast = try runWriteCast(alloc, log);
    defer alloc.free(cast);

    var saw_resize = false;
    var it = std.mem.splitScalar(u8, cast, '\n');
    _ = it.next();
    while (it.next()) |line| {
        if (line.len == 0) continue;
        var parsed = try parseJsonOwned(alloc, line);
        defer parsed.deinit();
        const arr = parsed.value.array.items;
        if (arr[1] == .string and std.mem.eql(u8, arr[1].string, "r")) {
            saw_resize = true;
            try testing.expectEqualStrings("120x40", arr[2].string);
            const t: f64 = switch (arr[0]) {
                .float => |f| f,
                .integer => |n| @floatFromInt(n),
                else => return error.UnexpectedType,
            };
            try testing.expect(t > 0.99 and t < 1.01);
        }
    }
    try testing.expect(saw_resize);
}

test "title, bell, exit are skipped (input is kept)" {
    const alloc = testing.allocator;
    const log =
        \\{"t":1700000000000,"kind":"spawn","program":"cat","args":[],"rows":24,"cols":80}
        \\{"t":1700000000200,"kind":"title","title":"hello"}
        \\{"t":1700000000300,"kind":"bell"}
        \\{"t":1700000000400,"kind":"output","bytes_hex":"62"}
        \\{"t":1700000000500,"kind":"exited","code":0}
    ;
    const cast = try runWriteCast(alloc, log);
    defer alloc.free(cast);

    var output_count: usize = 0;
    var event_count: usize = 0;
    var it = std.mem.splitScalar(u8, cast, '\n');
    _ = it.next();
    while (it.next()) |line| {
        if (line.len == 0) continue;
        event_count += 1;
        var parsed = try parseJsonOwned(alloc, line);
        defer parsed.deinit();
        if (parsed.value.array.items[1].string[0] == 'o') output_count += 1;
    }
    try testing.expectEqual(@as(usize, 1), output_count);
    try testing.expectEqual(@as(usize, 1), event_count);
}

test "input bursts coalesce into a single i-event keyed at the first keystroke" {
    const alloc = testing.allocator;
    // Five inputs 1ms apart — well under the 10ms threshold — form 'hello'.
    const log =
        \\{"t":1700000000000,"kind":"spawn","program":"cat","args":[],"rows":24,"cols":80}
        \\{"t":1700000000500,"kind":"input","bytes_hex":"68"}
        \\{"t":1700000000501,"kind":"input","bytes_hex":"65"}
        \\{"t":1700000000502,"kind":"input","bytes_hex":"6c"}
        \\{"t":1700000000503,"kind":"input","bytes_hex":"6c"}
        \\{"t":1700000000504,"kind":"input","bytes_hex":"6f"}
    ;
    const cast = try runWriteCast(alloc, log);
    defer alloc.free(cast);

    var input_events: usize = 0;
    var it = std.mem.splitScalar(u8, cast, '\n');
    _ = it.next();
    while (it.next()) |line| {
        if (line.len == 0) continue;
        var parsed = try parseJsonOwned(alloc, line);
        defer parsed.deinit();
        const arr = parsed.value.array.items;
        try testing.expectEqual(@as(usize, 3), arr.len);
        try testing.expect(arr[1] == .string);
        try testing.expectEqualStrings("i", arr[1].string);
        try testing.expectEqualStrings("hello", arr[2].string);
        const t: f64 = switch (arr[0]) {
            .float => |f| f,
            .integer => |n| @floatFromInt(n),
            else => return error.UnexpectedType,
        };
        try testing.expect(t > 0.499 and t < 0.501);
        input_events += 1;
    }
    try testing.expectEqual(@as(usize, 1), input_events);
}

test "input bursts separated by a gap produce two i-events" {
    const alloc = testing.allocator;
    const log =
        \\{"t":1700000000000,"kind":"spawn","program":"cat","args":[],"rows":24,"cols":80}
        \\{"t":1700000000500,"kind":"input","bytes_hex":"68"}
        \\{"t":1700000000501,"kind":"input","bytes_hex":"69"}
        \\{"t":1700000001000,"kind":"input","bytes_hex":"62"}
        \\{"t":1700000001001,"kind":"input","bytes_hex":"79"}
    ;
    const cast = try runWriteCast(alloc, log);
    defer alloc.free(cast);

    var payloads = std.array_list.Managed([]const u8).init(alloc);
    defer payloads.deinit();

    var it = std.mem.splitScalar(u8, cast, '\n');
    _ = it.next();
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const aalloc = arena.allocator();
    while (it.next()) |line| {
        if (line.len == 0) continue;
        var parsed = try parseJsonOwned(alloc, line);
        defer parsed.deinit();
        const arr = parsed.value.array.items;
        try testing.expectEqualStrings("i", arr[1].string);
        const dup = try aalloc.dupe(u8, arr[2].string);
        try payloads.append(dup);
    }
    try testing.expectEqual(@as(usize, 2), payloads.items.len);
    try testing.expectEqualStrings("hi", payloads.items[0]);
    try testing.expectEqualStrings("by", payloads.items[1]);
}

test "output between two input bursts flushes the first burst immediately" {
    const alloc = testing.allocator;
    // Input 'a', then output, then input 'b'. Even though the two inputs are
    // 2ms apart (< 10ms coalesce window), the output between them forces
    // the first one to flush — we must not merge across non-input events.
    const log =
        \\{"t":1700000000000,"kind":"spawn","program":"cat","args":[],"rows":24,"cols":80}
        \\{"t":1700000000100,"kind":"input","bytes_hex":"61"}
        \\{"t":1700000000101,"kind":"output","bytes_hex":"58"}
        \\{"t":1700000000102,"kind":"input","bytes_hex":"62"}
    ;
    const cast = try runWriteCast(alloc, log);
    defer alloc.free(cast);

    var kinds = std.array_list.Managed(u8).init(alloc);
    defer kinds.deinit();
    var it = std.mem.splitScalar(u8, cast, '\n');
    _ = it.next();
    while (it.next()) |line| {
        if (line.len == 0) continue;
        var parsed = try parseJsonOwned(alloc, line);
        defer parsed.deinit();
        const arr = parsed.value.array.items;
        try kinds.append(arr[1].string[0]);
    }
    // Expect: i (a), o (X), i (b) — three separate events in order.
    try testing.expectEqualSlices(u8, "ioi", kinds.items);
}

test "zero-output log just emits the header" {
    const alloc = testing.allocator;
    const log =
        \\{"t":1700000000000,"kind":"spawn","program":"cat","args":[],"rows":24,"cols":80}
    ;
    const cast = try runWriteCast(alloc, log);
    defer alloc.free(cast);

    // Exactly one newline-terminated line: the header.
    try testing.expect(std.mem.endsWith(u8, cast, "\n"));
    const body = cast[0 .. cast.len - 1];
    try testing.expect(std.mem.indexOfScalar(u8, body, '\n') == null);
}

test "output bytes are JSON-escaped (quote, newline, control)" {
    const alloc = testing.allocator;
    // bytes_hex decodes to:  "   (0x22 0x0a 0x01)
    // -> JSON string should contain \" \n \u0001
    const log =
        \\{"t":1700000000000,"kind":"spawn","program":"cat","args":[],"rows":24,"cols":80}
        \\{"t":1700000000100,"kind":"output","bytes_hex":"220a01"}
    ;
    const cast = try runWriteCast(alloc, log);
    defer alloc.free(cast);

    var it = std.mem.splitScalar(u8, cast, '\n');
    _ = it.next();
    const evt_line = it.next().?;
    // Sanity-check the escaping is literal in the cast bytes.
    try testing.expect(std.mem.indexOf(u8, evt_line, "\\\"") != null);
    try testing.expect(std.mem.indexOf(u8, evt_line, "\\n") != null);
    try testing.expect(std.mem.indexOf(u8, evt_line, "\\u0001") != null);

    // Parse the line and round-trip the payload.
    var parsed = try parseJsonOwned(alloc, evt_line);
    defer parsed.deinit();
    const payload = parsed.value.array.items[2].string;
    try testing.expectEqualSlices(u8, &.{ 0x22, 0x0a, 0x01 }, payload);
}

test "invalid utf-8 bytes are replaced with U+FFFD" {
    const alloc = testing.allocator;
    // 0xff is never valid UTF-8 on its own.
    const log =
        \\{"t":1700000000000,"kind":"spawn","program":"cat","args":[],"rows":24,"cols":80}
        \\{"t":1700000000100,"kind":"output","bytes_hex":"61ff62"}
    ;
    const cast = try runWriteCast(alloc, log);
    defer alloc.free(cast);

    var it = std.mem.splitScalar(u8, cast, '\n');
    _ = it.next();
    const evt_line = it.next().?;

    var parsed = try parseJsonOwned(alloc, evt_line);
    defer parsed.deinit();
    const payload = parsed.value.array.items[2].string;
    // Should be: 'a' + U+FFFD (0xef 0xbf 0xbd) + 'b'
    try testing.expectEqualSlices(u8, "a\u{FFFD}b", payload);
}

test "empty log errors cleanly" {
    const alloc = testing.allocator;
    const result = runWriteCast(alloc, "");
    try testing.expectError(error.EmptyLog, result);
}

test "malformed event lines are skipped, not fatal" {
    const alloc = testing.allocator;
    const log =
        \\{"t":1700000000000,"kind":"spawn","program":"cat","args":[],"rows":24,"cols":80}
        \\{not json
        \\{"t":1700000000100,"kind":"output","bytes_hex":"61"}
    ;
    const cast = try runWriteCast(alloc, log);
    defer alloc.free(cast);

    var output_count: usize = 0;
    var it = std.mem.splitScalar(u8, cast, '\n');
    _ = it.next();
    while (it.next()) |line| {
        if (line.len == 0) continue;
        output_count += 1;
    }
    try testing.expectEqual(@as(usize, 1), output_count);
}

test "real fixture round-trips: concatenated output matches decoded hex" {
    const io = std.testing.io;
    const alloc = testing.allocator;
    const path = "testdata/sessions/vim-edit.jsonl";
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(16 * 1024 * 1024)) catch return;
    defer alloc.free(bytes);

    const cast = try runWriteCast(alloc, bytes);
    defer alloc.free(cast);

    // Reconstruct the output stream from both sides and expect equality.
    var expected = std.array_list.Managed(u8).init(alloc);
    defer expected.deinit();
    {
        var log_it = std.mem.splitScalar(u8, bytes, '\n');
        _ = log_it.next();
        while (log_it.next()) |line| {
            if (line.len == 0) continue;
            var parsed = std.json.parseFromSlice(std.json.Value, alloc, line, .{}) catch continue;
            defer parsed.deinit();
            if (parsed.value != .object) continue;
            const obj = parsed.value.object;
            const k = getString(obj, "kind") orelse continue;
            if (!std.mem.eql(u8, k, "output")) continue;
            const hex = getString(obj, "bytes_hex") orelse continue;
            const decoded = try decodeHex(alloc, hex);
            defer alloc.free(decoded);
            try expected.appendSlice(decoded);
        }
    }

    var actual = std.array_list.Managed(u8).init(alloc);
    defer actual.deinit();
    {
        var cast_it = std.mem.splitScalar(u8, cast, '\n');
        _ = cast_it.next(); // header
        while (cast_it.next()) |line| {
            if (line.len == 0) continue;
            var parsed = std.json.parseFromSlice(std.json.Value, alloc, line, .{}) catch continue;
            defer parsed.deinit();
            if (parsed.value != .array) continue;
            const arr = parsed.value.array.items;
            if (arr.len != 3 or arr[1] != .string) continue;
            if (!std.mem.eql(u8, arr[1].string, "o")) continue;
            try actual.appendSlice(arr[2].string);
        }
    }

    try testing.expectEqualSlices(u8, expected.items, actual.items);
}

