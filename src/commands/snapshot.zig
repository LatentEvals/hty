//! `hty snapshot` — read the current rendered screen of a session.

const std = @import("std");
const Allocator = std.mem.Allocator;

const common = @import("common.zig");
const json_mod = @import("../json.zig");
const getString = json_mod.getString;
const getInteger = json_mod.getInteger;

pub fn helpText() []const u8 {
    return
    \\hty snapshot [SESSION] [--ansi] [--json] [--meta] [--diff] [--lines N:M]
    \\
    \\Read the session's current rendered screen. Default output is plain
    \\text. Use --ansi to get the styled ANSI rendering, --json for the
    \\structured response (screen content is compacted: trailing spaces are
    \\stripped from every line and runs of fill rows are collapsed into a
    \\`fill_runs` field), or --meta for just the metadata (cursor position,
    \\screen size, session status) without the screen buffer. --meta cannot
    \\be combined with --ansi, --json, or --lines.
    \\
    \\  --diff        Print only rows changed since the previous --diff
    \\                snapshot of this session (for polling loops): a
    \\                `rows LO-HI, N changed, cursor R,C` header, then one
    \\                `ROW| text` line per changed row — or exactly
    \\                `no change (cursor R,C)`. The first --diff (no
    \\                baseline yet) prints every row. Only --diff calls
    \\                update the baseline; plain/--json snapshots never do.
    \\                With --lines, only rows in the range are compared
    \\                and reported.
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
    var lines_range: ?common.LineRange = null;
    var meta_output = false;
    var diff_output = false;

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
        } else if (std.mem.eql(u8, arg, "--meta")) {
            meta_output = true;
        } else if (std.mem.eql(u8, arg, "--diff")) {
            diff_output = true;
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
    if (meta_output and (json_output or ansi_output or lines_range != null)) {
        try common.printErr("cannot combine --meta with --json, --ansi, or --lines");
        std.process.exit(common.ExitCode.generic);
    }
    if (diff_output and (json_output or ansi_output or meta_output)) {
        try common.printErr("--diff is incompatible with --json, --ansi, and --meta");
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
            try payload_buf.writer.print(",\"line_start\":{d}", .{range.start});
            if (range.end) |e| try payload_buf.writer.print(",\"line_end\":{d}", .{e});
        }
    }
    try payload_buf.writer.writeAll("}");

    const response_line = try common.sendRawRequest(alloc, io, payload_buf.writer.buffered());
    defer alloc.free(response_line);

    if (json_output) {
        const compacted = compactJsonResponse(alloc, response_line) catch null;
        defer if (compacted) |c| alloc.free(c);
        try common.printRaw(compacted orelse response_line);
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
    const body = if (lines_range) |r| common.sliceLines(text, r) else text;
    if (ansi_output) {
        try common.printRaw(body);
        try common.printRaw("\n");
    } else {
        try common.printPlainSnapshot(body);
    }
}

test "snapshot helpText documents --lines flag" {
    const text = helpText();
    try std.testing.expect(std.mem.indexOf(u8, text, "--lines N:M") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "1-indexed") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "LAST rows") != null);
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

/// A row is a fill row when its space-stripped content is empty (blank
/// row) or vim's `~` end-of-buffer marker. Only runs of these collapse;
/// repeated *content* rows always stay inline.
fn isFillRow(row: []const u8) bool {
    return row.len == 0 or std.mem.eql(u8, row, "~");
}

/// Rewrite a raw snapshot response so the embedded screen content is
/// compact (issue #101: the padded buffer made `--json` ~8× larger than
/// plain output). Three transformations, all information-preserving:
///
/// * every `buffer` line loses its trailing spaces (`lines` follows);
/// * each run (>= 2) of identical fill rows — vim's `~` region, blank
///   rows — is dropped from `buffer`/`lines`/`cells` and recorded in
///   `snapshot.fill_runs = [{"start_row": N, "row": <content>,
///   "count": M}, ...]`, `start_row` 1-indexed in the full grid like
///   `cursor_row`. Runs collapse anywhere, not just at the bottom: a
///   vim screen keeps its status/command line as the last row, so the
///   `~` region a snapshot mostly consists of sits above it;
/// * each remaining `cells` row loses its trailing blank (`" "`) cells.
///
/// The full grid is recoverable: walk `fill_runs` in order inserting
/// `count` copies of `row` at `start_row`, then pad every line to
/// `cols` with spaces (blank cells for `cells`). `rows`/`cols`/cursor
/// metadata are untouched.
///
/// Returns null (caller prints the response verbatim) when there is no
/// snapshot object to compact — e.g. an `ok:false` error response.
fn compactJsonResponse(alloc: Allocator, response_line: []const u8) !?[]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, response_line, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const snap_val = parsed.value.object.getPtr("snapshot") orelse return null;
    if (snap_val.* != .object) return null;
    try compactSnapshot(parsed.arena.allocator(), &snap_val.object);
    return try std.json.Stringify.valueAlloc(alloc, parsed.value, .{});
}

fn compactSnapshot(arena: Allocator, snap: *std.json.ObjectMap) !void {
    const buffer = switch (snap.get("buffer") orelse return) {
        .string => |s| s,
        else => return,
    };

    var rows: std.ArrayListUnmanaged([]const u8) = .empty;
    var line_iter = std.mem.splitScalar(u8, buffer, '\n');
    while (line_iter.next()) |line| {
        try rows.append(arena, std.mem.trimEnd(u8, line, " "));
    }

    // Partition rows into kept rows and collapsed fill runs. Runs of one
    // stay inline (a run record would be no smaller than the row itself).
    const FillRun = struct { start_row: usize, row: []const u8, count: usize };
    var kept: std.ArrayListUnmanaged([]const u8) = .empty;
    var kept_index: std.ArrayListUnmanaged(usize) = .empty;
    var fill_runs: std.ArrayListUnmanaged(FillRun) = .empty;
    var i: usize = 0;
    while (i < rows.items.len) {
        const row = rows.items[i];
        if (isFillRow(row)) {
            var j = i + 1;
            while (j < rows.items.len and std.mem.eql(u8, rows.items[j], row)) j += 1;
            if (j - i >= 2) {
                try fill_runs.append(arena, .{ .start_row = i + 1, .row = row, .count = j - i });
                i = j;
                continue;
            }
        }
        try kept.append(arena, row);
        try kept_index.append(arena, i);
        i += 1;
    }

    try snap.put(arena, "buffer", .{
        .string = try std.mem.join(arena, "\n", kept.items),
    });

    if (snap.getPtr("lines")) |lines_val| {
        if (lines_val.* == .array) {
            var new_lines = std.json.Array.init(arena);
            for (kept.items) |line| try new_lines.append(.{ .string = line });
            lines_val.* = .{ .array = new_lines };
        }
    }

    if (snap.getPtr("cells")) |cells_val| {
        if (cells_val.* == .array) {
            const cells = &cells_val.array;
            var new_cells = std.json.Array.init(arena);
            for (kept_index.items) |row_index| {
                if (row_index >= cells.items.len) break;
                const row_val = &cells.items[row_index];
                if (row_val.* == .array) {
                    const row = &row_val.array;
                    while (row.items.len > 0) {
                        const last = row.items[row.items.len - 1];
                        if (last != .string or !std.mem.eql(u8, last.string, " ")) break;
                        row.items.len -= 1;
                    }
                }
                try new_cells.append(row_val.*);
            }
            cells_val.* = .{ .array = new_cells };
        }
    }

    if (fill_runs.items.len > 0) {
        var runs_json = std.json.Array.init(arena);
        for (fill_runs.items) |fill_run| {
            var run_obj: std.json.ObjectMap = .empty;
            try run_obj.put(arena, "start_row", .{ .integer = @intCast(fill_run.start_row) });
            try run_obj.put(arena, "row", .{ .string = fill_run.row });
            try run_obj.put(arena, "count", .{ .integer = @intCast(fill_run.count) });
            try runs_json.append(.{ .object = run_obj });
        }
        try snap.put(arena, "fill_runs", .{ .array = runs_json });
    }
}

test "compactJsonResponse strips padding and collapses a vim-shaped screen" {
    const alloc = std.testing.allocator;
    // Content row, ~ fill region, then a status line kept as the last
    // row — the shape a real vim screen has.
    const raw =
        \\{"ok":true,"snapshot":{"rows":6,"cols":4,"cursor_row":1,"cursor_col":1,"buffer":"hi  \n~   \n~   \n~   \n~   \n:q  ","lines":["hi  ","~   ","~   ","~   ","~   ",":q  "],"cells":[["h","i"," "," "],["~"," "," "," "],["~"," "," "," "],["~"," "," "," "],["~"," "," "," "],[":","q"," "," "]]}}
    ;
    const out = (try compactJsonResponse(alloc, raw)) orelse return error.TestUnexpectedResult;
    defer alloc.free(out);

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, out, .{});
    defer parsed.deinit();
    const snap = parsed.value.object.get("snapshot").?.object;

    try std.testing.expectEqualStrings("hi\n:q", snap.get("buffer").?.string);

    const lines = snap.get("lines").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), lines.len);
    try std.testing.expectEqualStrings("hi", lines[0].string);
    try std.testing.expectEqualStrings(":q", lines[1].string);

    const cells = snap.get("cells").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), cells.len);
    try std.testing.expectEqual(@as(usize, 2), cells[0].array.items.len);
    try std.testing.expectEqual(@as(usize, 2), cells[1].array.items.len);

    const runs = snap.get("fill_runs").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), runs.len);
    const fill_run = runs[0].object;
    try std.testing.expectEqual(@as(i64, 2), fill_run.get("start_row").?.integer);
    try std.testing.expectEqualStrings("~", fill_run.get("row").?.string);
    try std.testing.expectEqual(@as(i64, 4), fill_run.get("count").?.integer);

    // Geometry and cursor metadata pass through untouched.
    try std.testing.expectEqual(@as(i64, 6), snap.get("rows").?.integer);
    try std.testing.expectEqual(@as(i64, 4), snap.get("cols").?.integer);
}

test "compactJsonResponse keeps single fill rows and repeated content inline" {
    const alloc = std.testing.allocator;
    // One lone blank row (run of 1) and a repeated *content* row —
    // neither collapses; only the blank run of 2 does.
    const raw =
        \\{"ok":true,"snapshot":{"rows":6,"cols":3,"buffer":"a  \n   \nb  \nb  \n   \n   "}}
    ;
    const out = (try compactJsonResponse(alloc, raw)) orelse return error.TestUnexpectedResult;
    defer alloc.free(out);

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, out, .{});
    defer parsed.deinit();
    const snap = parsed.value.object.get("snapshot").?.object;
    try std.testing.expectEqualStrings("a\n\nb\nb", snap.get("buffer").?.string);

    const runs = snap.get("fill_runs").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), runs.len);
    try std.testing.expectEqual(@as(i64, 5), runs[0].object.get("start_row").?.integer);
    try std.testing.expectEqualStrings("", runs[0].object.get("row").?.string);
    try std.testing.expectEqual(@as(i64, 2), runs[0].object.get("count").?.integer);
}

test "compactJsonResponse passes error responses through verbatim" {
    const alloc = std.testing.allocator;
    const out = try compactJsonResponse(alloc, "{\"ok\":false,\"error\":\"no such session\"}");
    try std.testing.expect(out == null);
}

