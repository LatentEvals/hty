//! Real-program fixture tests for the bundled `ghostty-vt` engine.
//!
//! Unlike `vt_golden_test.zig` (which feeds hand-authored escape sequences),
//! this suite replays session logs captured from real TUI programs via
//! `hty run`. It catches regressions in the *combinations* of sequences real
//! programs emit — patterns we'd never hand-author.
//!
//! Logs live in `testdata/sessions/*.jsonl` and are replayed through
//! `replayToTerminal`. The final grid (ansi + plain) is compared against
//! committed goldens in the same directory. Replay is pure byte-feeding into
//! a fresh VT, so results are deterministic across OSes.
//!
//! ## Adding a fixture
//!
//! Capture a session with `scripts/record-fixture.sh`, then:
//!
//!     UPDATE_GOLDENS=1 zig build test
//!
//! to materialize `{name}.ansi.golden` and `{name}.plain.golden`.
//!
//! ## Updating goldens after a ghostty-vt bump
//!
//!     UPDATE_GOLDENS=1 zig build test
//!
//! Review the diff in `testdata/sessions/` before committing.

const std = @import("std");
const sys = @import("hty").sys;
const hty = @import("hty");
const replayToTerminal = @import("commands/replay.zig").replayToTerminal;

const fixtures_dir = "testdata/sessions";

test "fixture suite: real-program replay goldens" {
    const alloc = std.testing.allocator;

    // Open the fixtures dir. If it doesn't exist, the suite is a no-op — a
    // fresh clone should pass before any fixtures have been added.
    var dir = std.Io.Dir.cwd().openDir(fixtures_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer dir.close();

    var it = dir.iterate();
    var any_failed = false;
    while (try it.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".jsonl")) continue;

        runFixture(alloc, entry.name) catch |err| {
            std.debug.print("fixture {s} failed: {s}\n", .{ entry.name, @errorName(err) });
            any_failed = true;
        };
    }

    if (any_failed) return error.FixtureFailed;
}

fn runFixture(alloc: std.mem.Allocator, filename: []const u8) !void {
    const path = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ fixtures_dir, filename });
    defer alloc.free(path);

    const file = try std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_only });
    defer file.close();
    const bytes = try file.readToEndAlloc(alloc, 64 * 1024 * 1024);
    defer alloc.free(bytes);

    // The spawn line (line 1) carries the initial rows/cols. Parse just that
    // header — `replayToTerminal` skips the spawn line itself.
    const nl = std.mem.indexOfScalar(u8, bytes, '\n') orelse return error.EmptyLog;
    const header = bytes[0..nl];
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, header, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.BadSpawnLine;
    const obj = parsed.value.object;
    const rows_v = obj.get("rows") orelse return error.BadSpawnLine;
    const cols_v = obj.get("cols") orelse return error.BadSpawnLine;
    if (rows_v != .integer or cols_v != .integer) return error.BadSpawnLine;
    const rows: u16 = @intCast(rows_v.integer);
    const cols: u16 = @intCast(cols_v.integer);

    var result = try replayToTerminal(io, alloc, bytes, rows, cols);
    defer result.deinit(alloc);

    const ansi = try hty.renderScreenAnsi(alloc, &result.terminal, result.rows, result.cols);
    defer alloc.free(ansi);
    const plain = try result.terminal.plainString(alloc);
    defer alloc.free(plain);

    // vim-edit-quit.jsonl → vim-edit-quit.ansi.golden / .plain.golden
    const stem = filename[0 .. filename.len - ".jsonl".len];

    const ansi_name = try std.fmt.allocPrint(alloc, "{s}.ansi.golden", .{stem});
    defer alloc.free(ansi_name);
    const plain_name = try std.fmt.allocPrint(alloc, "{s}.plain.golden", .{stem});
    defer alloc.free(plain_name);

    try compareOrUpdateGolden(alloc, ansi_name, ansi);
    try compareOrUpdateGolden(alloc, plain_name, plain);
}

fn compareOrUpdateGolden(
    alloc: std.mem.Allocator,
    basename: []const u8,
    actual: []const u8,
) !void {
    const path = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ fixtures_dir, basename });
    defer alloc.free(path);

    if (sys.getenv("UPDATE_GOLDENS") != null) {
        try std.Io.Dir.cwd().createDirPath(io, fixtures_dir);
        const file = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
        defer file.close();
        try file.writeAll(actual);
        return;
    }

    const file = std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_only }) catch |err| switch (err) {
        error.FileNotFound => {
            std.debug.print(
                \\
                \\  golden not found: {s}
                \\  run `UPDATE_GOLDENS=1 zig build test` to create it
                \\
                \\
            , .{path});
            return error.GoldenMissing;
        },
        else => return err,
    };
    defer file.close();
    const expected = try file.readToEndAlloc(alloc, 4 * 1024 * 1024);
    defer alloc.free(expected);

    if (!std.mem.eql(u8, expected, actual)) {
        std.debug.print(
            \\
            \\  golden mismatch: {s}
            \\  (expected {d} bytes, actual {d} bytes)
            \\
            \\  if this change is intentional, run:
            \\    UPDATE_GOLDENS=1 zig build test
            \\
            \\
        , .{ path, expected.len, actual.len });
        return error.GoldenMismatch;
    }
}
