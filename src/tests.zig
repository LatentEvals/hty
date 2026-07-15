//! Integration tests that drive the in-process request dispatcher
//! (`processRequestLine`) directly — no sockets, no spawned server process —
//! so we can assert on the full RPC surface from a regular unit-test harness.
//!
//! These tests outgrew `headless.zig` once the per-subcommand split landed,
//! and they don't naturally belong inside `server.zig` because they also
//! exercise `replayToTerminal` and various registry/log behaviors. Keep them
//! here as a dedicated integration-test aggregate.

const std = @import("std");
const hty = @import("hty");

const list_cmd = @import("commands/list.zig");
const info_cmd = @import("commands/info.zig");
const SessionRegistry = @import("registry.zig").SessionRegistry;
const processRequestLine = @import("server.zig").processRequestLine;
const replayToTerminal = @import("commands/replay.zig").replayToTerminal;

// ============================================================================
// Integration test helpers (drive the in-process dispatch without sockets)
// ============================================================================

pub fn testRequest(
    registry: *SessionRegistry,
    value: anytype,
) !std.json.Parsed(std.json.Value) {
    const alloc = std.testing.allocator;
    const request_line = try std.json.Stringify.valueAlloc(alloc, value, .{});
    defer alloc.free(request_line);

    const response_line = try processRequestLine(alloc, registry, request_line);
    defer alloc.free(response_line);

    const newline = std.mem.indexOfScalar(u8, response_line, '\n') orelse response_line.len;
    return std.json.parseFromSlice(std.json.Value, alloc, response_line[0..newline], .{});
}

pub fn expectTestOk(parsed: std.json.Parsed(std.json.Value)) !std.json.ObjectMap {
    const object = switch (parsed.value) {
        .object => |o| o,
        else => return error.InvalidResponse,
    };

    const ok = object.get("ok") orelse return error.InvalidResponse;
    switch (ok) {
        .bool => |v| if (!v) {
            if (object.get("error")) |err_val| {
                if (err_val == .string) {
                    std.debug.print("request failed: {s}\n", .{err_val.string});
                }
            }
            return error.ResponseNotOk;
        },
        else => return error.InvalidResponse,
    }
    return object;
}

/// Search PATH for a command and return its absolute path, or null.
fn findCommand(alloc: std.mem.Allocator, name: []const u8) ?[]const u8 {
    const path_env = std.process.getEnvVarOwned(alloc, "PATH") catch return null;
    defer alloc.free(path_env);

    var it = std.mem.splitScalar(u8, path_env, ':');
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        const full = std.fmt.allocPrint(alloc, "{s}/{s}", .{ dir, name }) catch continue;
        std.fs.accessAbsolute(full, .{}) catch {
            alloc.free(full);
            continue;
        };
        return full;
    }
    return null;
}

test "unknown operation returns actionable error" {
    var registry = SessionRegistry.init(std.testing.allocator);
    defer registry.deinit();

    var parsed = try testRequest(&registry, .{ .op = "bogus" });
    defer parsed.deinit();

    const object = switch (parsed.value) {
        .object => |o| o,
        else => return error.InvalidResponse,
    };
    const ok = object.get("ok") orelse return error.InvalidResponse;
    try std.testing.expectEqual(false, ok.bool);
    const message = object.get("error") orelse return error.InvalidResponse;
    try std.testing.expect(message == .string);
    try std.testing.expect(std.mem.indexOf(u8, message.string, "unknown op") != null);
}

test "list op returns empty array on a fresh registry" {
    var registry = SessionRegistry.init(std.testing.allocator);
    defer registry.deinit();

    var parsed = try testRequest(&registry, .{ .op = "list" });
    defer parsed.deinit();
    const object = try expectTestOk(parsed);

    const sessions = object.get("sessions") orelse return error.InvalidResponse;
    try std.testing.expect(sessions == .array);
    try std.testing.expectEqual(@as(usize, 0), sessions.array.items.len);
}

test "name collision is rejected" {
    var registry = SessionRegistry.init(std.testing.allocator);
    defer registry.deinit();

    {
        var parsed = try testRequest(&registry, .{
            .op = "spawn",
            .name = "dup",
            .program = "/bin/cat",
            .rows = 10,
            .cols = 40,
            .emit_raw_bytes = false,
        });
        defer parsed.deinit();
        _ = try expectTestOk(parsed);
    }
    {
        var parsed = try testRequest(&registry, .{
            .op = "spawn",
            .name = "dup",
            .program = "/bin/cat",
            .rows = 10,
            .cols = 40,
            .emit_raw_bytes = false,
        });
        defer parsed.deinit();
        const object = switch (parsed.value) {
            .object => |o| o,
            else => return error.InvalidResponse,
        };
        const ok = object.get("ok") orelse return error.InvalidResponse;
        try std.testing.expectEqual(false, ok.bool);
    }
    {
        var parsed = try testRequest(&registry, .{
            .op = "kill",
            .session = "dup",
        });
        defer parsed.deinit();
        _ = try expectTestOk(parsed);
    }
}

test "headless protocol can drive cat and snapshot echoed text" {
    var registry = SessionRegistry.init(std.testing.allocator);
    defer registry.deinit();

    {
        var parsed = try testRequest(&registry, .{
            .op = "spawn",
            .name = "cat",
            .program = "/bin/cat",
            .rows = 12,
            .cols = 50,
            .emit_raw_bytes = false,
        });
        defer parsed.deinit();
        _ = try expectTestOk(parsed);
    }

    {
        var parsed = try testRequest(&registry, .{
            .op = "send_text",
            .session = "cat",
            .text = "hello from headless\n",
        });
        defer parsed.deinit();
        _ = try expectTestOk(parsed);
    }

    {
        var parsed = try testRequest(&registry, .{
            .op = "wait_for_text",
            .session = "cat",
            .text = "hello from headless",
            .timeout_ms = 2_000,
        });
        defer parsed.deinit();
        const object = try expectTestOk(parsed);
        const snapshot = object.get("snapshot") orelse return error.InvalidResponse;
        const snapshot_object = switch (snapshot) {
            .object => |o| o,
            else => return error.InvalidResponse,
        };
        const buffer = snapshot_object.get("buffer") orelse return error.InvalidResponse;
        try std.testing.expect(buffer == .string);
        try std.testing.expect(std.mem.indexOf(u8, buffer.string, "hello from headless") != null);

        const screen_ansi = snapshot_object.get("screen_ansi") orelse return error.InvalidResponse;
        try std.testing.expect(screen_ansi == .string);
        try std.testing.expect(std.mem.indexOf(u8, screen_ansi.string, "hello from headless") != null);
        try std.testing.expect(std.mem.indexOf(u8, screen_ansi.string, "\x1b[") != null);

        // `cells` is a rows-length array of cols-length arrays. For a 12x50
        // session with "hello from headless" echoed on row 0, we expect
        // cells[0][0..19] to match the visible characters and every other
        // cell to be a single-space string.
        const cells = snapshot_object.get("cells") orelse return error.InvalidResponse;
        try std.testing.expect(cells == .array);
        try std.testing.expectEqual(@as(usize, 12), cells.array.items.len);
        for (cells.array.items) |row| {
            try std.testing.expect(row == .array);
            try std.testing.expectEqual(@as(usize, 50), row.array.items.len);
            for (row.array.items) |cell| try std.testing.expect(cell == .string);
        }
        const first_row = cells.array.items[0].array.items;
        const expected = "hello from headless";
        for (expected, 0..) |ch, i| {
            try std.testing.expectEqual(@as(usize, 1), first_row[i].string.len);
            try std.testing.expectEqual(ch, first_row[i].string[0]);
        }
    }

    {
        var parsed = try testRequest(&registry, .{ .op = "kill", .session = "cat" });
        defer parsed.deinit();
        _ = try expectTestOk(parsed);
    }
}

test "snapshot cells field exposes wide-char spacer tails over the RPC" {
    var registry = SessionRegistry.init(std.testing.allocator);
    defer registry.deinit();

    {
        var parsed = try testRequest(&registry, .{
            .op = "spawn",
            .name = "wide",
            .program = "/bin/cat",
            .rows = 6,
            .cols = 20,
            .emit_raw_bytes = false,
        });
        defer parsed.deinit();
        _ = try expectTestOk(parsed);
    }

    {
        var parsed = try testRequest(&registry, .{
            .op = "send_text",
            .session = "wide",
            .text = "日本語\n",
        });
        defer parsed.deinit();
        _ = try expectTestOk(parsed);
    }

    {
        var parsed = try testRequest(&registry, .{
            .op = "wait_for_text",
            .session = "wide",
            .text = "日本語",
            .timeout_ms = 2_000,
        });
        defer parsed.deinit();
        const object = try expectTestOk(parsed);
        const snapshot = object.get("snapshot") orelse return error.InvalidResponse;
        const snapshot_object = switch (snapshot) {
            .object => |o| o,
            else => return error.InvalidResponse,
        };
        const cells = snapshot_object.get("cells") orelse return error.InvalidResponse;
        try std.testing.expect(cells == .array);
        try std.testing.expectEqual(@as(usize, 6), cells.array.items.len);
        const row0 = cells.array.items[0].array.items;
        try std.testing.expectEqual(@as(usize, 20), row0.len);
        try std.testing.expectEqualStrings("日", row0[0].string);
        try std.testing.expectEqualStrings("", row0[1].string);
        try std.testing.expectEqualStrings("本", row0[2].string);
        try std.testing.expectEqualStrings("", row0[3].string);
        try std.testing.expectEqualStrings("語", row0[4].string);
        try std.testing.expectEqualStrings("", row0[5].string);
        for (6..20) |c| try std.testing.expectEqualStrings(" ", row0[c].string);
    }

    {
        var parsed = try testRequest(&registry, .{ .op = "kill", .session = "wide" });
        defer parsed.deinit();
        _ = try expectTestOk(parsed);
    }
}

test "wait_for_text with regex matches a pattern" {
    var registry = SessionRegistry.init(std.testing.allocator);
    defer registry.deinit();

    {
        var parsed = try testRequest(&registry, .{
            .op = "spawn",
            .name = "rcat",
            .program = "/bin/cat",
            .rows = 12,
            .cols = 50,
            .emit_raw_bytes = false,
        });
        defer parsed.deinit();
        _ = try expectTestOk(parsed);
    }

    {
        var parsed = try testRequest(&registry, .{
            .op = "send_text",
            .session = "rcat",
            .text = "order 42 confirmed\n",
        });
        defer parsed.deinit();
        _ = try expectTestOk(parsed);
    }

    // Regex match: "order" followed by one or more digits.
    {
        var parsed = try testRequest(&registry, .{
            .op = "wait_for_text",
            .session = "rcat",
            .text = "order [0-9]+ confirmed",
            .regex = true,
            .timeout_ms = 2_000,
        });
        defer parsed.deinit();
        const object = try expectTestOk(parsed);
        const snapshot = object.get("snapshot") orelse return error.InvalidResponse;
        const snapshot_object = switch (snapshot) {
            .object => |o| o,
            else => return error.InvalidResponse,
        };
        const buffer = snapshot_object.get("buffer") orelse return error.InvalidResponse;
        try std.testing.expect(buffer == .string);
        try std.testing.expect(std.mem.indexOf(u8, buffer.string, "order 42 confirmed") != null);
    }

    // Regex that does NOT match should time out.
    {
        var parsed = try testRequest(&registry, .{
            .op = "wait_for_text",
            .session = "rcat",
            .text = "^nothing here$",
            .regex = true,
            .timeout_ms = 200,
        });
        defer parsed.deinit();
        const object = try expectTestOk(parsed);
        const to_val = object.get("timed_out") orelse return error.InvalidResponse;
        try std.testing.expectEqual(true, to_val.bool);
    }

    {
        var parsed = try testRequest(&registry, .{ .op = "kill", .session = "rcat" });
        defer parsed.deinit();
        _ = try expectTestOk(parsed);
    }
}

test "session event log records spawn, input, output, killed" {
    const alloc = std.testing.allocator;

    // Make a temp log dir under /tmp so the test is self-contained and doesn't
    // pollute ~/.local/state/hty/logs.
    var log_dir_buf: [256]u8 = undefined;
    const log_dir = try std.fmt.bufPrint(
        &log_dir_buf,
        "/tmp/hty-log-test-{d}",
        .{std.time.nanoTimestamp()},
    );
    try std.fs.cwd().makePath(log_dir);
    defer std.fs.cwd().deleteTree(log_dir) catch {};
    const by_name = try std.fmt.allocPrint(alloc, "{s}/by-name", .{log_dir});
    defer alloc.free(by_name);
    try std.fs.cwd().makePath(by_name);

    var registry = SessionRegistry.init(alloc);
    defer registry.deinit();
    registry.log_dir = log_dir;

    {
        var parsed = try testRequest(&registry, .{
            .op = "spawn",
            .name = "logcat",
            .program = "/bin/cat",
            .rows = 8,
            .cols = 24,
        });
        defer parsed.deinit();
        _ = try expectTestOk(parsed);
    }
    {
        var parsed = try testRequest(&registry, .{
            .op = "send_text",
            .session = "logcat",
            .text = "hi\n",
        });
        defer parsed.deinit();
        _ = try expectTestOk(parsed);
    }
    {
        var parsed = try testRequest(&registry, .{
            .op = "wait_for_text",
            .session = "logcat",
            .text = "hi",
            .timeout_ms = 2_000,
        });
        defer parsed.deinit();
        _ = try expectTestOk(parsed);
    }
    {
        var parsed = try testRequest(&registry, .{ .op = "kill", .session = "logcat" });
        defer parsed.deinit();
        _ = try expectTestOk(parsed);
    }

    // Read the log file via the by-name symlink.
    const link_path = try std.fmt.allocPrint(alloc, "{s}/logcat.jsonl", .{by_name});
    defer alloc.free(link_path);

    const file = try std.fs.openFileAbsolute(link_path, .{});
    defer file.close();
    const contents = try file.readToEndAlloc(alloc, 1024 * 1024);
    defer alloc.free(contents);

    try std.testing.expect(std.mem.indexOf(u8, contents, "\"kind\":\"spawn\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "\"kind\":\"input\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "\"kind\":\"output\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "\"kind\":\"killed\"") != null);

    // Timestamps should be monotonically non-decreasing.
    var line_it = std.mem.splitScalar(u8, contents, '\n');
    var prev: i64 = 0;
    while (line_it.next()) |line| {
        if (line.len == 0) continue;
        const pos = std.mem.indexOf(u8, line, "\"t\":") orelse continue;
        var i = pos + 4;
        const num_start = i;
        while (i < line.len and line[i] >= '0' and line[i] <= '9') i += 1;
        if (i == num_start) continue;
        const t = try std.fmt.parseInt(i64, line[num_start..i], 10);
        try std.testing.expect(t >= prev);
        prev = t;
    }
}

test "headless protocol can use nano to write a file" {
    const nano_path = findCommand(std.testing.allocator, "nano") orelse return error.SkipZigTest;
    defer std.testing.allocator.free(nano_path);

    var registry = SessionRegistry.init(std.testing.allocator);
    defer registry.deinit();

    const path = try std.fmt.allocPrint(std.testing.allocator, "/tmp/hty-nano-{d}.txt", .{std.time.nanoTimestamp()});
    defer std.testing.allocator.free(path);
    std.fs.deleteFileAbsolute(path) catch {};
    defer std.fs.deleteFileAbsolute(path) catch {};

    {
        var parsed = try testRequest(&registry, .{
            .op = "spawn",
            .name = "nano",
            .program = nano_path,
            .args = [_][]const u8{path},
            .rows = 24,
            .cols = 80,
            .emit_raw_bytes = false,
        });
        defer parsed.deinit();
        _ = try expectTestOk(parsed);
    }

    // Wait for nano's UI to draw.
    {
        var parsed = try testRequest(&registry, .{
            .op = "wait_for_idle",
            .session = "nano",
            .idle_ms = 300,
            .timeout_ms = 5_000,
        });
        defer parsed.deinit();
        _ = try expectTestOk(parsed);
    }

    {
        var parsed = try testRequest(&registry, .{
            .op = "send_text",
            .session = "nano",
            .text = "hello from hty",
        });
        defer parsed.deinit();
        _ = try expectTestOk(parsed);
    }
    {
        var parsed = try testRequest(&registry, .{
            .op = "send_key",
            .session = "nano",
            .key = "enter",
        });
        defer parsed.deinit();
        _ = try expectTestOk(parsed);
    }
    {
        var parsed = try testRequest(&registry, .{
            .op = "send_text",
            .session = "nano",
            .text = "written through nano",
        });
        defer parsed.deinit();
        _ = try expectTestOk(parsed);
    }
    {
        var parsed = try testRequest(&registry, .{
            .op = "send_key",
            .session = "nano",
            .key = "ctrl-o",
        });
        defer parsed.deinit();
        _ = try expectTestOk(parsed);
    }
    {
        var parsed = try testRequest(&registry, .{
            .op = "send_key",
            .session = "nano",
            .key = "enter",
        });
        defer parsed.deinit();
        _ = try expectTestOk(parsed);
    }
    {
        var parsed = try testRequest(&registry, .{
            .op = "send_key",
            .session = "nano",
            .key = "ctrl-x",
        });
        defer parsed.deinit();
        _ = try expectTestOk(parsed);
    }

    // Wait for nano to exit.
    {
        var parsed = try testRequest(&registry, .{
            .op = "wait_for_exit",
            .session = "nano",
            .timeout_ms = 5_000,
        });
        defer parsed.deinit();
        _ = try expectTestOk(parsed);
    }

    const file = try std.fs.openFileAbsolute(path, .{});
    defer file.close();
    const contents = try file.readToEndAlloc(std.testing.allocator, 4096);
    defer std.testing.allocator.free(contents);
    try std.testing.expect(std.mem.indexOf(u8, contents, "hello from hty") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "written through nano") != null);
}

test "headless protocol can launch top and quit" {
    const top_path = findCommand(std.testing.allocator, "top") orelse return error.SkipZigTest;
    defer std.testing.allocator.free(top_path);

    var registry = SessionRegistry.init(std.testing.allocator);
    defer registry.deinit();

    {
        var parsed = try testRequest(&registry, .{
            .op = "spawn",
            .name = "top",
            .program = top_path,
            .rows = 20,
            .cols = 80,
            .emit_raw_bytes = false,
        });
        defer parsed.deinit();
        _ = try expectTestOk(parsed);
    }

    // Let top draw its initial UI.
    {
        var parsed = try testRequest(&registry, .{
            .op = "wait_for_idle",
            .session = "top",
            .idle_ms = 500,
            .timeout_ms = 5_000,
        });
        defer parsed.deinit();
        _ = try expectTestOk(parsed);
    }

    {
        var parsed = try testRequest(&registry, .{
            .op = "send_text",
            .session = "top",
            .text = "q",
        });
        defer parsed.deinit();
        _ = try expectTestOk(parsed);
    }

    {
        var parsed = try testRequest(&registry, .{
            .op = "wait_for_exit",
            .session = "top",
            .timeout_ms = 5_000,
        });
        defer parsed.deinit();
        _ = try expectTestOk(parsed);
    }
}

test "headless protocol can use emacs to write an org file" {
    const emacs_path = findCommand(std.testing.allocator, "emacs") orelse return error.SkipZigTest;
    defer std.testing.allocator.free(emacs_path);

    var registry = SessionRegistry.init(std.testing.allocator);
    defer registry.deinit();

    const path = try std.fmt.allocPrint(std.testing.allocator, "/tmp/hty-emacs-{d}.org", .{std.time.nanoTimestamp()});
    defer std.testing.allocator.free(path);
    std.fs.deleteFileAbsolute(path) catch {};
    defer std.fs.deleteFileAbsolute(path) catch {};

    // Spawn emacs in terminal mode with no init file.
    {
        var parsed = try testRequest(&registry, .{
            .op = "spawn",
            .name = "emacs",
            .program = emacs_path,
            .args = [_][]const u8{ "-nw", "-q", "--no-splash", path },
            .rows = 24,
            .cols = 80,
            .emit_raw_bytes = false,
        });
        defer parsed.deinit();
        _ = try expectTestOk(parsed);
    }

    // Wait for emacs to start.
    {
        var parsed = try testRequest(&registry, .{
            .op = "wait_for_idle",
            .session = "emacs",
            .idle_ms = 500,
            .timeout_ms = 10_000,
        });
        defer parsed.deinit();
        _ = try expectTestOk(parsed);
    }

    // Type org-mode content.
    {
        var parsed = try testRequest(&registry, .{
            .op = "send_text",
            .session = "emacs",
            .text = "* Hello from hty",
        });
        defer parsed.deinit();
        _ = try expectTestOk(parsed);
    }
    {
        var parsed = try testRequest(&registry, .{
            .op = "send_key",
            .session = "emacs",
            .key = "enter",
        });
        defer parsed.deinit();
        _ = try expectTestOk(parsed);
    }
    {
        var parsed = try testRequest(&registry, .{
            .op = "send_text",
            .session = "emacs",
            .text = "** TODO Write tests",
        });
        defer parsed.deinit();
        _ = try expectTestOk(parsed);
    }

    // Save: C-x C-s
    {
        var parsed = try testRequest(&registry, .{
            .op = "send_key",
            .session = "emacs",
            .key = "ctrl-x",
        });
        defer parsed.deinit();
        _ = try expectTestOk(parsed);
    }
    {
        var parsed = try testRequest(&registry, .{
            .op = "send_key",
            .session = "emacs",
            .key = "ctrl-s",
        });
        defer parsed.deinit();
        _ = try expectTestOk(parsed);
    }

    // Wait for save to complete.
    {
        var parsed = try testRequest(&registry, .{
            .op = "wait_for_idle",
            .session = "emacs",
            .idle_ms = 500,
            .timeout_ms = 5_000,
        });
        defer parsed.deinit();
        _ = try expectTestOk(parsed);
    }

    // Quit: C-x C-c
    {
        var parsed = try testRequest(&registry, .{
            .op = "send_key",
            .session = "emacs",
            .key = "ctrl-x",
        });
        defer parsed.deinit();
        _ = try expectTestOk(parsed);
    }
    {
        var parsed = try testRequest(&registry, .{
            .op = "send_key",
            .session = "emacs",
            .key = "ctrl-c",
        });
        defer parsed.deinit();
        _ = try expectTestOk(parsed);
    }

    // Wait for emacs to exit.
    {
        var parsed = try testRequest(&registry, .{
            .op = "wait_for_exit",
            .session = "emacs",
            .timeout_ms = 5_000,
        });
        defer parsed.deinit();
        _ = try expectTestOk(parsed);
    }

    // Verify file contents.
    const file = try std.fs.openFileAbsolute(path, .{});
    defer file.close();
    const contents = try file.readToEndAlloc(std.testing.allocator, 4096);
    defer std.testing.allocator.free(contents);
    try std.testing.expect(std.mem.indexOf(u8, contents, "* Hello from hty") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "** TODO Write tests") != null);
}

// ===========================================================================
// Replay parity tests
// ===========================================================================
//
// These prove that `replayToTerminal` produces the same grid as the live
// session that recorded the log. If this ever breaks, `hty replay` is lying —
// which would defeat the entire point of per-session logging. Also exercises
// the `resize` event path in `applyLogEvent`, which isn't reachable from any
// of the golden-frame tests.

/// Shared helper: set up a self-contained log dir under /tmp and return it
/// along with the `by-name` subdir path. Caller owns neither (the returned
/// paths live in the provided buffers / allocator).
fn setupReplayLogDir(
    alloc: std.mem.Allocator,
    tag: []const u8,
    log_dir_buf: []u8,
) !struct { log_dir: []const u8, by_name: []const u8 } {
    const log_dir = try std.fmt.bufPrint(
        log_dir_buf,
        "/tmp/hty-replay-{s}-{d}",
        .{ tag, std.time.nanoTimestamp() },
    );
    try std.fs.cwd().makePath(log_dir);
    const by_name = try std.fmt.allocPrint(alloc, "{s}/by-name", .{log_dir});
    try std.fs.cwd().makePath(by_name);
    return .{ .log_dir = log_dir, .by_name = by_name };
}

/// Read `<by_name>/<name>.jsonl` in full. Caller frees.
fn readSessionLog(alloc: std.mem.Allocator, by_name: []const u8, name: []const u8) ![]u8 {
    const link_path = try std.fmt.allocPrint(alloc, "{s}/{s}.jsonl", .{ by_name, name });
    defer alloc.free(link_path);
    const file = try std.fs.openFileAbsolute(link_path, .{});
    defer file.close();
    return try file.readToEndAlloc(alloc, 4 * 1024 * 1024);
}

test "replay reproduces the live grid for a colored cat session" {
    const alloc = std.testing.allocator;

    var log_dir_buf: [256]u8 = undefined;
    const dirs = try setupReplayLogDir(alloc, "cat", &log_dir_buf);
    defer std.fs.cwd().deleteTree(dirs.log_dir) catch {};
    defer alloc.free(dirs.by_name);

    var registry = SessionRegistry.init(alloc);
    defer registry.deinit();
    registry.log_dir = dirs.log_dir;

    const rows: u16 = 12;
    const cols: u16 = 50;

    // 1. Spawn cat.
    {
        var parsed = try testRequest(&registry, .{
            .op = "spawn",
            .name = "pcat",
            .program = "/bin/cat",
            .rows = rows,
            .cols = cols,
            .emit_raw_bytes = false,
        });
        defer parsed.deinit();
        _ = try expectTestOk(parsed);
    }

    // 2. Send something non-trivial: colors + cursor positioning. The grid
    //    should have fg changes on a prefix and cursor pokes elsewhere.
    {
        var parsed = try testRequest(&registry, .{
            .op = "send_text",
            .session = "pcat",
            .text = "\x1b[31mred\x1b[32mgreen\x1b[0mplain line one\n\x1b[3;10Hpoke\n",
        });
        defer parsed.deinit();
        _ = try expectTestOk(parsed);
    }

    // 3. Wait for the text to land, then idle to ensure no more output is
    //    racing us. Without the idle we occasionally snapshot mid-flush and
    //    replay sees *more* bytes than the live snapshot.
    {
        var parsed = try testRequest(&registry, .{
            .op = "wait_for_text",
            .session = "pcat",
            .text = "plain line one",
            .timeout_ms = 2_000,
        });
        defer parsed.deinit();
        _ = try expectTestOk(parsed);
    }
    {
        var parsed = try testRequest(&registry, .{
            .op = "wait_for_idle",
            .session = "pcat",
            .idle_ms = 150,
            .timeout_ms = 2_000,
        });
        defer parsed.deinit();
        _ = try expectTestOk(parsed);
    }

    // 4. Capture the live screen_ansi via a dedicated snapshot op so we're
    //    not tied to the waiter's return payload.
    const live_ansi = blk: {
        var parsed = try testRequest(&registry, .{ .op = "snapshot", .session = "pcat" });
        defer parsed.deinit();
        const obj = try expectTestOk(parsed);
        const snap = obj.get("snapshot") orelse return error.InvalidResponse;
        const snap_obj = switch (snap) {
            .object => |o| o,
            else => return error.InvalidResponse,
        };
        const ansi_val = snap_obj.get("screen_ansi") orelse return error.InvalidResponse;
        if (ansi_val != .string) return error.InvalidResponse;
        break :blk try alloc.dupe(u8, ansi_val.string);
    };
    defer alloc.free(live_ansi);

    // 5. Kill and read the log.
    {
        var parsed = try testRequest(&registry, .{ .op = "kill", .session = "pcat" });
        defer parsed.deinit();
        _ = try expectTestOk(parsed);
    }
    const log_bytes = try readSessionLog(alloc, dirs.by_name, "pcat");
    defer alloc.free(log_bytes);

    // 6. Replay into a fresh VT.
    var result = try replayToTerminal(alloc, log_bytes, rows, cols);
    defer result.deinit(alloc);

    // 7. Render with the same dims and compare byte-for-byte.
    const replayed_ansi = try hty.renderScreenAnsi(alloc, &result.terminal, result.rows, result.cols);
    defer alloc.free(replayed_ansi);

    try std.testing.expectEqualStrings(live_ansi, replayed_ansi);
}

test "replay reproduces the live grid across a mid-session resize" {
    const alloc = std.testing.allocator;

    var log_dir_buf: [256]u8 = undefined;
    const dirs = try setupReplayLogDir(alloc, "resize", &log_dir_buf);
    defer std.fs.cwd().deleteTree(dirs.log_dir) catch {};
    defer alloc.free(dirs.by_name);

    var registry = SessionRegistry.init(alloc);
    defer registry.deinit();
    registry.log_dir = dirs.log_dir;

    const start_rows: u16 = 10;
    const start_cols: u16 = 40;
    const new_rows: u16 = 14;
    const new_cols: u16 = 60;

    // 1. Spawn at the smaller size.
    {
        var parsed = try testRequest(&registry, .{
            .op = "spawn",
            .name = "rcat",
            .program = "/bin/cat",
            .rows = start_rows,
            .cols = start_cols,
            .emit_raw_bytes = false,
        });
        defer parsed.deinit();
        _ = try expectTestOk(parsed);
    }

    // 2. Some content before the resize.
    {
        var parsed = try testRequest(&registry, .{
            .op = "send_text",
            .session = "rcat",
            .text = "first round\n",
        });
        defer parsed.deinit();
        _ = try expectTestOk(parsed);
    }
    {
        var parsed = try testRequest(&registry, .{
            .op = "wait_for_text",
            .session = "rcat",
            .text = "first round",
            .timeout_ms = 2_000,
        });
        defer parsed.deinit();
        _ = try expectTestOk(parsed);
    }

    // 3. Resize — this is the event we specifically want `replayToTerminal`
    //    to replay correctly.
    {
        var parsed = try testRequest(&registry, .{
            .op = "resize",
            .session = "rcat",
            .rows = new_rows,
            .cols = new_cols,
        });
        defer parsed.deinit();
        _ = try expectTestOk(parsed);
    }

    // 4. More content post-resize.
    {
        var parsed = try testRequest(&registry, .{
            .op = "send_text",
            .session = "rcat",
            .text = "second round at the wider size\n",
        });
        defer parsed.deinit();
        _ = try expectTestOk(parsed);
    }
    {
        var parsed = try testRequest(&registry, .{
            .op = "wait_for_text",
            .session = "rcat",
            .text = "second round",
            .timeout_ms = 2_000,
        });
        defer parsed.deinit();
        _ = try expectTestOk(parsed);
    }
    {
        var parsed = try testRequest(&registry, .{
            .op = "wait_for_idle",
            .session = "rcat",
            .idle_ms = 150,
            .timeout_ms = 2_000,
        });
        defer parsed.deinit();
        _ = try expectTestOk(parsed);
    }

    const live_ansi = blk: {
        var parsed = try testRequest(&registry, .{ .op = "snapshot", .session = "rcat" });
        defer parsed.deinit();
        const obj = try expectTestOk(parsed);
        const snap = obj.get("snapshot") orelse return error.InvalidResponse;
        const snap_obj = switch (snap) {
            .object => |o| o,
            else => return error.InvalidResponse,
        };
        const ansi_val = snap_obj.get("screen_ansi") orelse return error.InvalidResponse;
        if (ansi_val != .string) return error.InvalidResponse;
        break :blk try alloc.dupe(u8, ansi_val.string);
    };
    defer alloc.free(live_ansi);

    {
        var parsed = try testRequest(&registry, .{ .op = "kill", .session = "rcat" });
        defer parsed.deinit();
        _ = try expectTestOk(parsed);
    }
    const log_bytes = try readSessionLog(alloc, dirs.by_name, "rcat");
    defer alloc.free(log_bytes);

    // 5. Sanity check: the log must contain a resize event, otherwise this
    //    test isn't actually exercising the path it claims to.
    try std.testing.expect(std.mem.indexOf(u8, log_bytes, "\"kind\":\"resize\"") != null);

    // 6. Replay and compare. `result.rows`/`.cols` should reflect the new
    //    (post-resize) dimensions, proving the resize applied.
    var result = try replayToTerminal(alloc, log_bytes, start_rows, start_cols);
    defer result.deinit(alloc);
    try std.testing.expectEqual(new_rows, result.rows);
    try std.testing.expectEqual(new_cols, result.cols);

    const replayed_ansi = try hty.renderScreenAnsi(alloc, &result.terminal, result.rows, result.cols);
    defer alloc.free(replayed_ansi);

    try std.testing.expectEqualStrings(live_ansi, replayed_ansi);
}

// ===========================================================================
// Protocol error shape
// ===========================================================================
//
// These pin down the dispatcher's contract: every failed request returns a
// well-formed `{ok: false, error: "..."}` envelope. If a future refactor
// accidentally lets an error escape the response wrapper — say, by forgetting
// a `catch` at a new file boundary — these tests fail loudly. The happy-path
// tests assume the envelope shape; these tests prove it.

/// Send a raw (pre-stringified) request line straight to processRequestLine.
/// Used for malformed-input tests where we need bytes stringify wouldn't
/// produce (e.g. not-JSON, non-object root).
fn testRequestRaw(registry: *SessionRegistry, request_line: []const u8) !std.json.Parsed(std.json.Value) {
    const alloc = std.testing.allocator;
    const response_line = try processRequestLine(alloc, registry, request_line);
    defer alloc.free(response_line);
    const newline = std.mem.indexOfScalar(u8, response_line, '\n') orelse response_line.len;
    return std.json.parseFromSlice(std.json.Value, alloc, response_line[0..newline], .{});
}

/// Assert the response envelope is `{ok: false, error: "..."}` and that the
/// error string contains `needle`. Prints the actual message on mismatch so
/// test output is useful. Pass an empty needle to accept any error.
pub fn expectTestError(parsed: std.json.Parsed(std.json.Value), needle: []const u8) !void {
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return error.InvalidResponse,
    };
    const ok = obj.get("ok") orelse return error.InvalidResponse;
    if (ok != .bool or ok.bool) {
        std.debug.print("\nexpected ok:false, got ok:{any}\n", .{ok});
        return error.ExpectedError;
    }
    const err_val = obj.get("error") orelse return error.InvalidResponse;
    if (err_val != .string) return error.InvalidResponse;
    if (needle.len > 0 and std.mem.indexOf(u8, err_val.string, needle) == null) {
        std.debug.print("\nexpected error to contain '{s}', got: '{s}'\n", .{ needle, err_val.string });
        return error.ErrorMessageMismatch;
    }
}

test "invalid JSON returns a structured error" {
    var registry = SessionRegistry.init(std.testing.allocator);
    defer registry.deinit();

    var parsed = try testRequestRaw(&registry, "not valid json {{{");
    defer parsed.deinit();
    try expectTestError(parsed, "");
}

test "non-object JSON root returns a structured error" {
    var registry = SessionRegistry.init(std.testing.allocator);
    defer registry.deinit();

    var parsed = try testRequestRaw(&registry, "[1,2,3]");
    defer parsed.deinit();
    try expectTestError(parsed, "JSON object");
}

test "request missing the op field returns a structured error" {
    var registry = SessionRegistry.init(std.testing.allocator);
    defer registry.deinit();

    var parsed = try testRequestRaw(&registry, "{}");
    defer parsed.deinit();
    // Error comes through as the raw error name because the op-dispatch path
    // reports @errorName directly rather than going through requestErrorMessage.
    try expectTestError(parsed, "MissingField");
}

test "op with missing required subfield returns a structured error" {
    var registry = SessionRegistry.init(std.testing.allocator);
    defer registry.deinit();

    // spawn without `program` — handleSpawn calls readRequiredString("program").
    var parsed = try testRequest(&registry, .{ .op = "spawn" });
    defer parsed.deinit();
    try expectTestError(parsed, "missing required field");
}

test "op with wrong-type field returns a structured error" {
    var registry = SessionRegistry.init(std.testing.allocator);
    defer registry.deinit();

    // `program` should be a string; send an integer.
    var parsed = try testRequest(&registry, .{ .op = "spawn", .program = 42 });
    defer parsed.deinit();
    try expectTestError(parsed, "invalid field type");
}

// ===========================================================================
// Session resolution
// ===========================================================================
//
// The dispatcher accepts a `session` reference as a full UUID, a unique
// prefix, or a human-readable name — and picks the sole session implicitly
// when omitted. This is the single most error-prone part of the protocol
// because it silently resolves; a refactor that breaks resolution would
// surface as "wrong session got the op" rather than a hard error. Pin down
// every resolution path.

/// Spawn a single cat session and return its UUID (duped with
/// `std.testing.allocator`). Caller must free.
pub fn spawnCatSession(registry: *SessionRegistry, name: ?[]const u8) ![]u8 {
    const alloc = std.testing.allocator;
    var parsed = if (name) |n|
        try testRequest(registry, .{
            .op = "spawn",
            .name = n,
            .program = "/bin/cat",
            .rows = 8,
            .cols = 24,
            .emit_raw_bytes = false,
        })
    else
        try testRequest(registry, .{
            .op = "spawn",
            .program = "/bin/cat",
            .rows = 8,
            .cols = 24,
            .emit_raw_bytes = false,
        });
    defer parsed.deinit();
    const obj = try expectTestOk(parsed);
    const session = obj.get("session") orelse return error.InvalidResponse;
    const session_obj = switch (session) {
        .object => |o| o,
        else => return error.InvalidResponse,
    };
    const id_val = session_obj.get("id") orelse return error.InvalidResponse;
    if (id_val != .string) return error.InvalidResponse;
    return try alloc.dupe(u8, id_val.string);
}

test "resolve session by full UUID" {
    const alloc = std.testing.allocator;
    var registry = SessionRegistry.init(alloc);
    defer registry.deinit();

    const uuid = try spawnCatSession(&registry, null);
    defer alloc.free(uuid);

    var parsed = try testRequest(&registry, .{ .op = "snapshot", .session = uuid });
    defer parsed.deinit();
    _ = try expectTestOk(parsed);

    var k = try testRequest(&registry, .{ .op = "kill", .session = uuid });
    defer k.deinit();
    _ = try expectTestOk(k);
}

test "resolve session by short UUID prefix" {
    const alloc = std.testing.allocator;
    var registry = SessionRegistry.init(alloc);
    defer registry.deinit();

    const uuid = try spawnCatSession(&registry, null);
    defer alloc.free(uuid);

    // UUIDs are 36 chars; the first 8 are plenty unique with one session.
    const prefix = uuid[0..8];
    var parsed = try testRequest(&registry, .{ .op = "snapshot", .session = prefix });
    defer parsed.deinit();
    _ = try expectTestOk(parsed);

    var k = try testRequest(&registry, .{ .op = "kill", .session = uuid });
    defer k.deinit();
    _ = try expectTestOk(k);
}

test "ambiguous prefix is rejected" {
    const alloc = std.testing.allocator;
    var registry = SessionRegistry.init(alloc);
    defer registry.deinit();

    const uuid_a = try spawnCatSession(&registry, "a");
    defer alloc.free(uuid_a);
    const uuid_b = try spawnCatSession(&registry, "b");
    defer alloc.free(uuid_b);

    // UUIDv7 encodes a millisecond timestamp in the high bits, so two sessions
    // created back-to-back always share at least the first few hex chars.
    var shared_len: usize = 0;
    while (shared_len < uuid_a.len and shared_len < uuid_b.len and uuid_a[shared_len] == uuid_b[shared_len]) shared_len += 1;
    try std.testing.expect(shared_len > 0);
    const shared = uuid_a[0..shared_len];

    var parsed = try testRequest(&registry, .{ .op = "snapshot", .session = shared });
    defer parsed.deinit();
    try expectTestError(parsed, "ambiguous");

    var ka = try testRequest(&registry, .{ .op = "kill", .session = uuid_a });
    defer ka.deinit();
    _ = try expectTestOk(ka);
    var kb = try testRequest(&registry, .{ .op = "kill", .session = uuid_b });
    defer kb.deinit();
    _ = try expectTestOk(kb);
}

test "sole-session implicit resolution" {
    const alloc = std.testing.allocator;
    var registry = SessionRegistry.init(alloc);
    defer registry.deinit();

    const uuid = try spawnCatSession(&registry, "solo");
    defer alloc.free(uuid);

    // No session field — should resolve to the only session.
    var parsed = try testRequest(&registry, .{ .op = "snapshot" });
    defer parsed.deinit();
    _ = try expectTestOk(parsed);

    var k = try testRequest(&registry, .{ .op = "kill", .session = "solo" });
    defer k.deinit();
    _ = try expectTestOk(k);
}

test "sole-session implicit errors when multiple sessions exist" {
    const alloc = std.testing.allocator;
    var registry = SessionRegistry.init(alloc);
    defer registry.deinit();

    const uuid_a = try spawnCatSession(&registry, "aa");
    defer alloc.free(uuid_a);
    const uuid_b = try spawnCatSession(&registry, "bb");
    defer alloc.free(uuid_b);

    var parsed = try testRequest(&registry, .{ .op = "snapshot" });
    defer parsed.deinit();
    try expectTestError(parsed, "ambiguous");

    var ka = try testRequest(&registry, .{ .op = "kill", .session = "aa" });
    defer ka.deinit();
    _ = try expectTestOk(ka);
    var kb = try testRequest(&registry, .{ .op = "kill", .session = "bb" });
    defer kb.deinit();
    _ = try expectTestOk(kb);
}

test "session-not-found returns a structured error" {
    const alloc = std.testing.allocator;
    var registry = SessionRegistry.init(alloc);
    defer registry.deinit();

    // Spawn one session so the "no sessions at all" branch doesn't shadow
    // the named-resolve path we actually want to exercise.
    const uuid = try spawnCatSession(&registry, "real");
    defer alloc.free(uuid);

    var parsed = try testRequest(&registry, .{ .op = "snapshot", .session = "does-not-exist" });
    defer parsed.deinit();
    try expectTestError(parsed, "session not found");

    var k = try testRequest(&registry, .{ .op = "kill", .session = "real" });
    defer k.deinit();
    _ = try expectTestOk(k);
}

// ===========================================================================
// Untested op happy-paths
// ===========================================================================
//
// Every RPC op gets at least one assertion beyond "didn't panic". These are
// the behaviors a refactor could silently break by moving the wrong slice of
// code between files.

test "send_bytes_hex op sends decoded bytes to the pty" {
    var registry = SessionRegistry.init(std.testing.allocator);
    defer registry.deinit();

    const uuid = try spawnCatSession(&registry, "hexcat");
    defer std.testing.allocator.free(uuid);

    // "ping\n" = 70 69 6e 67 0a
    {
        var parsed = try testRequest(&registry, .{
            .op = "send_bytes_hex",
            .session = "hexcat",
            .bytes_hex = "70696e670a",
        });
        defer parsed.deinit();
        _ = try expectTestOk(parsed);
    }
    {
        var parsed = try testRequest(&registry, .{
            .op = "wait_for_text",
            .session = "hexcat",
            .text = "ping",
            .timeout_ms = 2_000,
        });
        defer parsed.deinit();
        _ = try expectTestOk(parsed);
    }

    var k = try testRequest(&registry, .{ .op = "kill", .session = "hexcat" });
    defer k.deinit();
    _ = try expectTestOk(k);
}

test "send_bytes_hex op rejects malformed hex" {
    var registry = SessionRegistry.init(std.testing.allocator);
    defer registry.deinit();

    const uuid = try spawnCatSession(&registry, "badhex");
    defer std.testing.allocator.free(uuid);

    var parsed = try testRequest(&registry, .{
        .op = "send_bytes_hex",
        .session = "badhex",
        .bytes_hex = "not-hex-at-all",
    });
    defer parsed.deinit();
    try expectTestError(parsed, "invalid hex");

    var k = try testRequest(&registry, .{ .op = "kill", .session = "badhex" });
    defer k.deinit();
    _ = try expectTestOk(k);
}

// Round-trip for `hty send --raw-text`: the client skips its C-style escape
// decoder and hands the argument bytes through unchanged. Exercising that
// here means issuing `send_text` with the literal 7-byte string `hello\n`
// (backslash + n, no LF) — which is exactly what the client produces for
// `--raw-text 'hello\n'`. We assert the echo contains those two literal
// bytes and no real newline snuck in.
test "send_text with literal backslash-n preserves bytes verbatim (--raw-text round trip)" {
    var registry = SessionRegistry.init(std.testing.allocator);
    defer registry.deinit();

    const uuid = try spawnCatSession(&registry, "rawcat");
    defer std.testing.allocator.free(uuid);

    // 7 bytes: h e l l o \ n — no real LF.
    const literal: []const u8 = "hello\\n";
    try std.testing.expectEqual(@as(usize, 7), literal.len);

    {
        var parsed = try testRequest(&registry, .{
            .op = "send_text",
            .session = "rawcat",
            .text = literal,
        });
        defer parsed.deinit();
        _ = try expectTestOk(parsed);
    }

    {
        // Wait for the literal substring to appear in the echoed buffer.
        // `wait_for_text.text` is a literal substring match so searching for
        // "hello\\n" (backslash + n) is a direct check.
        var parsed = try testRequest(&registry, .{
            .op = "wait_for_text",
            .session = "rawcat",
            .text = literal,
            .timeout_ms = 2_000,
        });
        defer parsed.deinit();
        const object = try expectTestOk(parsed);
        const snapshot = object.get("snapshot") orelse return error.InvalidResponse;
        const snapshot_object = switch (snapshot) {
            .object => |o| o,
            else => return error.InvalidResponse,
        };
        const buffer = snapshot_object.get("buffer") orelse return error.InvalidResponse;
        try std.testing.expect(buffer == .string);
        // The literal 7 bytes must appear contiguously (no LF splitting).
        try std.testing.expect(std.mem.indexOf(u8, buffer.string, literal) != null);
        // And confirm there's no "hello\n" (real LF) anywhere — if the
        // client had unescaped, the buffer would contain h,e,l,l,o,0x0A.
        try std.testing.expect(std.mem.indexOf(u8, buffer.string, "hello\n") == null);
    }

    var k = try testRequest(&registry, .{ .op = "kill", .session = "rawcat" });
    defer k.deinit();
    _ = try expectTestOk(k);
}

test "send_key op accepts a symbolic key name" {
    var registry = SessionRegistry.init(std.testing.allocator);
    defer registry.deinit();

    const uuid = try spawnCatSession(&registry, "keycat");
    defer std.testing.allocator.free(uuid);

    // "enter" is one of the always-supported symbolic keys (used by the
    // existing nano/emacs tests).
    var parsed = try testRequest(&registry, .{
        .op = "send_key",
        .session = "keycat",
        .key = "enter",
    });
    defer parsed.deinit();
    _ = try expectTestOk(parsed);

    var k = try testRequest(&registry, .{ .op = "kill", .session = "keycat" });
    defer k.deinit();
    _ = try expectTestOk(k);
}

test "send_key op rejects an unknown key name" {
    var registry = SessionRegistry.init(std.testing.allocator);
    defer registry.deinit();

    const uuid = try spawnCatSession(&registry, "badkey");
    defer std.testing.allocator.free(uuid);

    var parsed = try testRequest(&registry, .{
        .op = "send_key",
        .session = "badkey",
        .key = "definitely-not-a-key",
    });
    defer parsed.deinit();
    try expectTestError(parsed, "invalid key");

    var k = try testRequest(&registry, .{ .op = "kill", .session = "badkey" });
    defer k.deinit();
    _ = try expectTestOk(k);
}

test "resize op changes dimensions visible in the next snapshot" {
    var registry = SessionRegistry.init(std.testing.allocator);
    defer registry.deinit();

    const uuid = try spawnCatSession(&registry, "rcat");
    defer std.testing.allocator.free(uuid);

    // spawnCatSession uses 8 rows / 24 cols. Resize and confirm via snapshot.
    {
        var parsed = try testRequest(&registry, .{
            .op = "resize",
            .session = "rcat",
            .rows = 20,
            .cols = 90,
        });
        defer parsed.deinit();
        _ = try expectTestOk(parsed);
    }

    {
        var parsed = try testRequest(&registry, .{ .op = "snapshot", .session = "rcat" });
        defer parsed.deinit();
        const obj = try expectTestOk(parsed);
        const snap = obj.get("snapshot") orelse return error.InvalidResponse;
        const snap_obj = switch (snap) {
            .object => |o| o,
            else => return error.InvalidResponse,
        };
        const rows_val = snap_obj.get("rows") orelse return error.InvalidResponse;
        const cols_val = snap_obj.get("cols") orelse return error.InvalidResponse;
        try std.testing.expectEqual(@as(i64, 20), rows_val.integer);
        try std.testing.expectEqual(@as(i64, 90), cols_val.integer);
    }

    var k = try testRequest(&registry, .{ .op = "kill", .session = "rcat" });
    defer k.deinit();
    _ = try expectTestOk(k);
}

test "wait_for_exit returns after the child terminates" {
    var registry = SessionRegistry.init(std.testing.allocator);
    defer registry.deinit();

    // /usr/bin/true exits immediately — perfect for wait_for_exit.
    {
        var parsed = try testRequest(&registry, .{
            .op = "spawn",
            .name = "quickexit",
            .program = "/usr/bin/true",
            .rows = 8,
            .cols = 24,
            .emit_raw_bytes = false,
        });
        defer parsed.deinit();
        _ = try expectTestOk(parsed);
    }

    var parsed = try testRequest(&registry, .{
        .op = "wait_for_exit",
        .session = "quickexit",
        .timeout_ms = 3_000,
    });
    defer parsed.deinit();
    _ = try expectTestOk(parsed);
}

test "list op returns one entry per session" {
    const alloc = std.testing.allocator;
    var registry = SessionRegistry.init(alloc);
    defer registry.deinit();

    const uuid_one = try spawnCatSession(&registry, "one");
    defer alloc.free(uuid_one);
    const uuid_two = try spawnCatSession(&registry, "two");
    defer alloc.free(uuid_two);

    {
        var parsed = try testRequest(&registry, .{ .op = "list" });
        defer parsed.deinit();
        const obj = try expectTestOk(parsed);
        const sessions = obj.get("sessions") orelse return error.InvalidResponse;
        if (sessions != .array) return error.InvalidResponse;
        try std.testing.expectEqual(@as(usize, 2), sessions.array.items.len);

        // Each entry must carry id, name, program, status — the shape the CLI
        // and any external consumer relies on.
        for (sessions.array.items) |entry| {
            if (entry != .object) return error.InvalidResponse;
            const e = entry.object;
            try std.testing.expect(e.get("id") != null);
            try std.testing.expect(e.get("name") != null);
            try std.testing.expect(e.get("program") != null);
            try std.testing.expect(e.get("status") != null);
        }
    }

    var k1 = try testRequest(&registry, .{ .op = "kill", .session = "one" });
    defer k1.deinit();
    _ = try expectTestOk(k1);
    var k2 = try testRequest(&registry, .{ .op = "kill", .session = "two" });
    defer k2.deinit();
    _ = try expectTestOk(k2);
}

test "list json stays structured with no live server and no sessions" {
    const alloc = std.testing.allocator;
    var merged = try list_cmd.collectMergedSessions(alloc, null, null);
    defer merged.deinit();

    const response = try list_cmd.buildJsonResponse(merged.arena(), merged.entries.items);
    try std.testing.expect(response.ok);
    try std.testing.expect(response.sessions != null);
    try std.testing.expectEqual(@as(usize, 0), response.sessions.?.len);
}

test "list json includes disk-backed sessions with no live server" {
    const alloc = std.testing.allocator;

    var log_dir_buf: [256]u8 = undefined;
    const dirs = try setupReplayLogDir(alloc, "list-json", &log_dir_buf);
    defer std.fs.cwd().deleteTree(dirs.log_dir) catch {};
    defer alloc.free(dirs.by_name);

    {
        var registry = SessionRegistry.init(alloc);
        defer registry.deinit();
        registry.log_dir = dirs.log_dir;

        const uuid = try spawnCatSession(&registry, "diskonly");
        defer alloc.free(uuid);
    }

    var merged = try list_cmd.collectMergedSessions(alloc, dirs.log_dir, null);
    defer merged.deinit();

    try std.testing.expectEqual(@as(usize, 1), merged.entries.items.len);

    const response = try list_cmd.buildJsonResponse(merged.arena(), merged.entries.items);
    try std.testing.expect(response.ok);
    try std.testing.expect(response.sessions != null);
    const sessions = response.sessions.?;
    try std.testing.expectEqual(@as(usize, 1), sessions.len);
    try std.testing.expectEqualStrings("diskonly", sessions[0].name.?);
    try std.testing.expectEqualStrings("/bin/cat", sessions[0].program);
}

test "list json preserves null names for unnamed disk-backed sessions" {
    const alloc = std.testing.allocator;

    var log_dir_buf: [256]u8 = undefined;
    const dirs = try setupReplayLogDir(alloc, "list-json-null-name", &log_dir_buf);
    defer std.fs.cwd().deleteTree(dirs.log_dir) catch {};
    defer alloc.free(dirs.by_name);

    {
        var registry = SessionRegistry.init(alloc);
        defer registry.deinit();
        registry.log_dir = dirs.log_dir;

        var parsed = try testRequest(&registry, .{
            .op = "spawn",
            .program = "/bin/cat",
            .rows = 8,
            .cols = 24,
        });
        defer parsed.deinit();
        _ = try expectTestOk(parsed);
    }

    var merged = try list_cmd.collectMergedSessions(alloc, dirs.log_dir, null);
    defer merged.deinit();

    try std.testing.expectEqual(@as(usize, 1), merged.entries.items.len);

    const response = try list_cmd.buildJsonResponse(merged.arena(), merged.entries.items);
    try std.testing.expect(response.ok);
    const sessions = response.sessions orelse return error.InvalidResponse;
    try std.testing.expectEqual(@as(usize, 1), sessions.len);
    try std.testing.expect(sessions[0].name == null);
    try std.testing.expectEqualStrings("/bin/cat", sessions[0].program);
}

test "delete op removes the session record and its log files" {
    const alloc = std.testing.allocator;

    var log_dir_buf: [256]u8 = undefined;
    const log_dir = try std.fmt.bufPrint(
        &log_dir_buf,
        "/tmp/hty-delete-test-{d}",
        .{std.time.nanoTimestamp()},
    );
    try std.fs.cwd().makePath(log_dir);
    defer std.fs.cwd().deleteTree(log_dir) catch {};
    const by_name = try std.fmt.allocPrint(alloc, "{s}/by-name", .{log_dir});
    defer alloc.free(by_name);
    try std.fs.cwd().makePath(by_name);

    var registry = SessionRegistry.init(alloc);
    defer registry.deinit();
    registry.log_dir = log_dir;

    const uuid = try spawnCatSession(&registry, "todelete");
    defer alloc.free(uuid);

    // Send something so the log file is non-trivially on disk.
    {
        var parsed = try testRequest(&registry, .{
            .op = "send_text",
            .session = "todelete",
            .text = "hi\n",
        });
        defer parsed.deinit();
        _ = try expectTestOk(parsed);
    }

    const uuid_path = try std.fmt.allocPrint(alloc, "{s}/{s}.jsonl", .{ log_dir, uuid });
    defer alloc.free(uuid_path);
    const name_path = try std.fmt.allocPrint(alloc, "{s}/todelete.jsonl", .{by_name});
    defer alloc.free(name_path);

    // Files must exist before delete.
    try std.fs.accessAbsolute(uuid_path, .{});
    try std.fs.accessAbsolute(name_path, .{});

    {
        var parsed = try testRequest(&registry, .{ .op = "delete", .session = "todelete" });
        defer parsed.deinit();
        _ = try expectTestOk(parsed);
    }

    // Log files are gone.
    try std.testing.expectError(error.FileNotFound, std.fs.accessAbsolute(uuid_path, .{}));
    try std.testing.expectError(error.FileNotFound, std.fs.accessAbsolute(name_path, .{}));

    // Session is gone from the registry — list returns empty.
    {
        var parsed = try testRequest(&registry, .{ .op = "list" });
        defer parsed.deinit();
        const obj = try expectTestOk(parsed);
        const sessions = obj.get("sessions") orelse return error.InvalidResponse;
        if (sessions != .array) return error.InvalidResponse;
        try std.testing.expectEqual(@as(usize, 0), sessions.array.items.len);
    }

    // Resolving the deleted name errors — proves the registry actually
    // unhooked it, not just removed the log.
    var find_parsed = try testRequest(&registry, .{ .op = "snapshot", .session = "todelete" });
    defer find_parsed.deinit();
    try expectTestError(find_parsed, "session not found");

    // The name is free again after delete.
    {
        var parsed = try testRequest(&registry, .{
            .op = "spawn",
            .name = "todelete",
            .program = "/bin/cat",
            .rows = 8,
            .cols = 24,
        });
        defer parsed.deinit();
        _ = try expectTestOk(parsed);
    }
}

test "named sessions stay reserved across registry restarts until delete" {
    const alloc = std.testing.allocator;

    var log_dir_buf: [256]u8 = undefined;
    const log_dir = try std.fmt.bufPrint(
        &log_dir_buf,
        "/tmp/hty-name-reservation-test-{d}",
        .{std.time.nanoTimestamp()},
    );
    try std.fs.cwd().makePath(log_dir);
    defer std.fs.cwd().deleteTree(log_dir) catch {};
    const by_name = try std.fmt.allocPrint(alloc, "{s}/by-name", .{log_dir});
    defer alloc.free(by_name);
    try std.fs.cwd().makePath(by_name);

    {
        var registry = SessionRegistry.init(alloc);
        defer registry.deinit();
        registry.log_dir = log_dir;

        const uuid = try spawnCatSession(&registry, "reserved");
        defer alloc.free(uuid);

        var parsed = try testRequest(&registry, .{
            .op = "send_text",
            .session = "reserved",
            .text = "hello\n",
        });
        defer parsed.deinit();
        _ = try expectTestOk(parsed);
    }

    {
        var registry = SessionRegistry.init(alloc);
        defer registry.deinit();
        registry.log_dir = log_dir;

        var parsed = try testRequest(&registry, .{
            .op = "spawn",
            .name = "reserved",
            .program = "/bin/cat",
            .rows = 8,
            .cols = 24,
        });
        defer parsed.deinit();
        try expectTestError(parsed, "already exists");
    }
}

// ===========================================================================
// Concurrency tests (LatentEvals/hty#14)
// ===========================================================================
//
// The server is a single-threaded event loop, so "concurrency" here means
// concurrent *clients*: every test in this section runs the real server
// loop in a background thread on a temporary Unix socket and races client
// threads against it through the wire protocol.
//
// 1. Parallel clients: two client threads hammer snapshot/list against
//    the same session. Proves interleaved socket traffic produces
//    coherent responses.
//
// 2. Parked waits: `wait_for_text` handlers park in the loop's waiter
//    table instead of occupying a thread — a fresh `list` must complete
//    within budget while waits are pending (the #14 regression, plus the
//    N=8 event-loop variant).
//
// 3. Shutdown-while-busy: ensures `runServerWithOpts` unwinds cleanly
//    while a wait is parked.

const runServerWithOpts = @import("server.zig").runServerWithOpts;

test "concurrency: parallel socket clients drive the same server without crashing" {
    const alloc = std.testing.allocator;

    const harness = try startServerHarness(alloc, "concpar");
    defer {
        harness.deinit(alloc);
        alloc.destroy(harness);
    }

    // Spawn a session we can poke at from both clients.
    {
        var parsed = try socketRequest(alloc, harness.socket_path, .{
            .op = "spawn",
            .program = "/bin/cat",
            .name = "concurrent",
        });
        defer parsed.deinit();
        _ = try expectTestOk(parsed);
    }

    const ClientCtx = struct {
        alloc: std.mem.Allocator,
        socket_path: []const u8,
        op: []const u8,
        success: std.atomic.Value(bool) = .init(false),

        fn run(self: *@This()) void {
            var i: usize = 0;
            while (i < 20) : (i += 1) {
                // Each request is its own connection, exactly like a real
                // `hty` CLI invocation.
                var parsed = socketRequest(self.alloc, self.socket_path, .{
                    .op = self.op,
                    .session = "concurrent",
                }) catch return;
                defer parsed.deinit();
                _ = expectTestOk(parsed) catch return;
            }
            self.success.store(true, .release);
        }
    };

    var ctx_a = ClientCtx{ .alloc = alloc, .socket_path = harness.socket_path, .op = "snapshot" };
    var ctx_b = ClientCtx{ .alloc = alloc, .socket_path = harness.socket_path, .op = "list" };

    const ta = try std.Thread.spawn(.{}, ClientCtx.run, .{&ctx_a});
    const tb = try std.Thread.spawn(.{}, ClientCtx.run, .{&ctx_b});
    ta.join();
    tb.join();

    try std.testing.expect(ctx_a.success.load(.acquire));
    try std.testing.expect(ctx_b.success.load(.acquire));

    var del_parsed = try socketRequest(alloc, harness.socket_path, .{
        .op = "delete",
        .session = "concurrent",
    });
    defer del_parsed.deinit();
    _ = try expectTestOk(del_parsed);
}

// Shared harness for the socket-level concurrency tests: spins up a real
// `runServerWithOpts` in a background thread on a tmp Unix socket and
// returns the paths / signals needed to drive it + tear it down cleanly.
const ServerHarness = struct {
    socket_path: []u8,
    log_dir: []u8,
    stop: std.atomic.Value(bool),
    thread: std.Thread,
    server_err: std.atomic.Value(bool),
    /// Heap-allocated context owned by the server thread. Freed here on
    /// teardown after the thread has been joined so its storage outlives
    /// any possible last access.
    ctx: *ServerEntryCtx,

    fn deinit(self: *ServerHarness, alloc: std.mem.Allocator) void {
        self.stop.store(true, .release);
        self.thread.join();
        std.fs.cwd().deleteTree(self.log_dir) catch {};
        alloc.destroy(self.ctx);
        alloc.free(self.socket_path);
        alloc.free(self.log_dir);
    }
};

const ServerEntryCtx = struct {
    alloc: std.mem.Allocator,
    socket_path: []const u8,
    log_dir: []const u8,
    stop: *std.atomic.Value(bool),
    err_flag: *std.atomic.Value(bool),

    fn run(self: *ServerEntryCtx) void {
        runServerWithOpts(self.alloc, self.socket_path, .{
            .empty_grace_ms = 30_000, // let stop_signal control exit
            .stop_signal = self.stop,
            .log_dir = self.log_dir,
        }) catch {
            self.err_flag.store(true, .release);
        };
    }
};

fn startServerHarness(alloc: std.mem.Allocator, tag: []const u8) !*ServerHarness {
    const harness = try alloc.create(ServerHarness);
    errdefer alloc.destroy(harness);

    const stamp = std.time.nanoTimestamp();
    const log_dir = try std.fmt.allocPrint(alloc, "/tmp/hty-{s}-log-{d}", .{ tag, stamp });
    errdefer alloc.free(log_dir);
    try std.fs.cwd().makePath(log_dir);
    const by_name = try std.fmt.allocPrint(alloc, "{s}/by-name", .{log_dir});
    defer alloc.free(by_name);
    try std.fs.cwd().makePath(by_name);

    // Unix-socket paths are capped at ~104 bytes on macOS / ~108 on
    // Linux. Keep the path short and predictable; uniqueness comes from
    // the nanosecond timestamp plus the per-test `tag`.
    const socket_path = try std.fmt.allocPrint(alloc, "/tmp/hty-{s}-{d}.sock", .{ tag, stamp });
    errdefer alloc.free(socket_path);
    // Clear any stale path from a previous run — the server unlinks on
    // its own, but this keeps the test hermetic if a prior run crashed.
    std.fs.cwd().deleteFile(socket_path) catch {};

    const ctx = try alloc.create(ServerEntryCtx);
    errdefer alloc.destroy(ctx);

    harness.* = .{
        .socket_path = socket_path,
        .log_dir = log_dir,
        .stop = .init(false),
        .server_err = .init(false),
        .thread = undefined,
        .ctx = ctx,
    };

    ctx.* = .{
        .alloc = alloc,
        .socket_path = harness.socket_path,
        .log_dir = harness.log_dir,
        .stop = &harness.stop,
        .err_flag = &harness.server_err,
    };

    harness.thread = try std.Thread.spawn(.{}, ServerEntryCtx.run, .{ctx});

    // Give the server a moment to create the socket file.
    var tries: usize = 0;
    while (tries < 50) : (tries += 1) {
        std.fs.accessAbsolute(harness.socket_path, .{}) catch {
            std.Thread.sleep(20 * std.time.ns_per_ms);
            continue;
        };
        return harness;
    }
    return error.ServerSocketNotReady;
}

fn socketRequest(
    alloc: std.mem.Allocator,
    socket_path: []const u8,
    value: anytype,
) !std.json.Parsed(std.json.Value) {
    const request_line = try std.json.Stringify.valueAlloc(alloc, value, .{});
    defer alloc.free(request_line);

    const stream = try std.net.connectUnixSocket(socket_path);
    defer stream.close();

    try stream.writeAll(request_line);
    try stream.writeAll("\n");

    var buf = std.array_list.Managed(u8).init(alloc);
    defer buf.deinit();
    var chunk: [4096]u8 = undefined;
    while (true) {
        const n = stream.read(&chunk) catch break;
        if (n == 0) break;
        try buf.appendSlice(chunk[0..n]);
        if (std.mem.indexOfScalar(u8, buf.items, '\n') != null) break;
    }
    const newline = std.mem.indexOfScalar(u8, buf.items, '\n') orelse buf.items.len;
    return std.json.parseFromSlice(std.json.Value, alloc, buf.items[0..newline], .{});
}

test "concurrency: long wait_for_text does not block concurrent list (LatentEvals/hty#14)" {
    const alloc = std.testing.allocator;

    const harness = try startServerHarness(alloc, "conc14");
    defer {
        harness.deinit(alloc);
        alloc.destroy(harness);
    }

    // 1. Spawn a session via the server.
    {
        var parsed = try socketRequest(alloc, harness.socket_path, .{
            .op = "spawn",
            .program = "/bin/cat",
            .name = "sleepy",
        });
        defer parsed.deinit();
        const obj = try expectTestOk(parsed);
        _ = obj;
    }

    // 2. In a background thread, kick off a wait_for_text for a needle
    //    that will never appear, with a bounded timeout. This is the
    //    handler that blocked everyone else in the pre-fix server.
    const WaitCtx = struct {
        alloc: std.mem.Allocator,
        socket_path: []const u8,
        done: std.atomic.Value(bool) = .init(false),

        fn run(self: *@This()) void {
            var parsed = socketRequest(self.alloc, self.socket_path, .{
                .op = "wait_for_text",
                .session = "sleepy",
                .text = "impossible-needle-that-will-never-match",
                .timeout_ms = 1500,
            }) catch {
                self.done.store(true, .release);
                return;
            };
            parsed.deinit();
            self.done.store(true, .release);
        }
    };

    var wait_ctx = WaitCtx{ .alloc = alloc, .socket_path = harness.socket_path };
    const wait_thread = try std.Thread.spawn(.{}, WaitCtx.run, .{&wait_ctx});

    // Small delay so the wait handler is definitely mid-poll when we
    // issue the competing list call. The wait does its first drainAll
    // and then sleeps 25ms; 100ms is plenty of wiggle room.
    std.Thread.sleep(100 * std.time.ns_per_ms);

    // 3. Issue a `list` request and time it. In the pre-fix server this
    //    would queue behind the wait and return after ~1.5 seconds.
    //    After the fix it should return within a drain tick plus a bit
    //    of socket round-trip — well under 500ms on any CI runner.
    const start = std.time.milliTimestamp();
    {
        var parsed = try socketRequest(alloc, harness.socket_path, .{ .op = "list" });
        defer parsed.deinit();
        _ = try expectTestOk(parsed);
    }
    const elapsed = std.time.milliTimestamp() - start;

    // Generous budget: the pre-fix behavior would be ~1500ms (the wait's
    // full timeout). 500ms gives plenty of slack for slow CI runners
    // without risking a false positive if the bug returns.
    try std.testing.expect(elapsed < 500);

    wait_thread.join();
    try std.testing.expect(wait_ctx.done.load(.acquire));

    // 4. Clean up the session so the server's empty-grace timer would
    //    eventually fire (though we stop via the signal first).
    var kill_parsed = try socketRequest(alloc, harness.socket_path, .{
        .op = "delete",
        .session = "sleepy",
    });
    defer kill_parsed.deinit();
    _ = try expectTestOk(kill_parsed);
}

test "concurrency: eight parked waits do not stall a fresh list (event loop)" {
    const alloc = std.testing.allocator;

    const harness = try startServerHarness(alloc, "parked8");
    defer {
        harness.deinit(alloc);
        alloc.destroy(harness);
    }

    {
        var parsed = try socketRequest(alloc, harness.socket_path, .{
            .op = "spawn",
            .program = "/bin/cat",
            .name = "parked",
        });
        defer parsed.deinit();
        _ = try expectTestOk(parsed);
    }

    // Eight clients park long waits for a needle that never appears. On
    // the event loop each one is a waiter-table entry, not an occupied
    // thread — the server must stay fully responsive underneath them.
    const WaitCtx = struct {
        alloc: std.mem.Allocator,
        socket_path: []const u8,
        timed_out: std.atomic.Value(bool) = .init(false),

        fn run(self: *@This()) void {
            var parsed = socketRequest(self.alloc, self.socket_path, .{
                .op = "wait_for_text",
                .session = "parked",
                .text = "impossible-needle-that-will-never-match",
                .timeout_ms = 2000,
            }) catch return;
            defer parsed.deinit();
            const object = expectTestOk(parsed) catch return;
            const to_val = object.get("timed_out") orelse return;
            if (to_val == .bool and to_val.bool) self.timed_out.store(true, .release);
        }
    };

    var ctxs: [8]WaitCtx = undefined;
    var threads: [8]std.Thread = undefined;
    for (&ctxs, 0..) |*ctx, i| {
        ctx.* = .{ .alloc = alloc, .socket_path = harness.socket_path };
        threads[i] = try std.Thread.spawn(.{}, WaitCtx.run, .{ctx});
    }

    // Let all eight waits reach the server and park.
    std.Thread.sleep(200 * std.time.ns_per_ms);

    // A fresh connection's `list` must complete within its usual budget —
    // with thread-per-connection this held because threads are cheap;
    // with the loop it holds because parked waits don't run at all.
    const start = std.time.milliTimestamp();
    {
        var parsed = try socketRequest(alloc, harness.socket_path, .{ .op = "list" });
        defer parsed.deinit();
        _ = try expectTestOk(parsed);
    }
    const elapsed = std.time.milliTimestamp() - start;
    try std.testing.expect(elapsed < 500);

    // Every wait must still resolve with its own timeout response.
    for (&threads) |t| t.join();
    for (&ctxs) |*ctx| try std.testing.expect(ctx.timed_out.load(.acquire));

    var del_parsed = try socketRequest(alloc, harness.socket_path, .{
        .op = "delete",
        .session = "parked",
    });
    defer del_parsed.deinit();
    _ = try expectTestOk(del_parsed);
}

test "oversized request line gets a structured error and the server keeps serving" {
    const alloc = std.testing.allocator;
    const max_request_line_bytes = @import("server.zig").max_request_line_bytes;

    const harness = try startServerHarness(alloc, "bigreq");
    defer {
        harness.deinit(alloc);
        alloc.destroy(harness);
    }

    // 1. Open a raw connection and pour in more than the cap with no
    //    newline. The server must reply with a structured error instead
    //    of buffering the flood until it OOMs.
    {
        const stream = try std.net.connectUnixSocket(harness.socket_path);
        defer stream.close();

        const filler = try alloc.alloc(u8, 64 * 1024);
        defer alloc.free(filler);
        @memset(filler, 'a');

        var sent: usize = 0;
        while (sent <= max_request_line_bytes + filler.len) : (sent += filler.len) {
            // The server may respond and close mid-flood once it crosses
            // the cap; a broken pipe here means the error response is
            // already on its way, so stop writing and go read it.
            stream.writeAll(filler) catch break;
        }

        var buf = std.array_list.Managed(u8).init(alloc);
        defer buf.deinit();
        var chunk: [4096]u8 = undefined;
        while (true) {
            const n = stream.read(&chunk) catch break;
            if (n == 0) break;
            try buf.appendSlice(chunk[0..n]);
            if (std.mem.indexOfScalar(u8, buf.items, '\n') != null) break;
        }
        const newline = std.mem.indexOfScalar(u8, buf.items, '\n') orelse buf.items.len;
        var parsed = try std.json.parseFromSlice(std.json.Value, alloc, buf.items[0..newline], .{});
        defer parsed.deinit();

        const obj = parsed.value.object;
        try std.testing.expectEqual(false, obj.get("ok").?.bool);
        try std.testing.expectEqualStrings("request too large", obj.get("error").?.string);
    }

    // 2. A fresh connection must still get normal service.
    var parsed = try socketRequest(alloc, harness.socket_path, .{ .op = "list" });
    defer parsed.deinit();
    _ = try expectTestOk(parsed);
}

test "concurrency: server shuts down cleanly while a wait handler is in flight" {
    const alloc = std.testing.allocator;

    const harness = try startServerHarness(alloc, "concshut");
    defer {
        // deinit signals stop + joins the server thread. If the server
        // can't unwind because a worker is stuck, this test would hang;
        // that's the assertion — the wait_for_exit handler must observe
        // the session's status transition and return promptly.
        harness.deinit(alloc);
        alloc.destroy(harness);
    }

    {
        var parsed = try socketRequest(alloc, harness.socket_path, .{
            .op = "spawn",
            .program = "/bin/cat",
            .name = "shutdowner",
        });
        defer parsed.deinit();
        _ = try expectTestOk(parsed);
    }

    // Kick off a wait_for_exit with a timeout well past the test's own
    // deadline. The only way this returns quickly is via status change.
    const WaitCtx = struct {
        alloc: std.mem.Allocator,
        socket_path: []const u8,
        done: std.atomic.Value(bool) = .init(false),

        fn run(self: *@This()) void {
            var parsed = socketRequest(self.alloc, self.socket_path, .{
                .op = "wait_for_exit",
                .session = "shutdowner",
                .timeout_ms = 30_000,
            }) catch {
                self.done.store(true, .release);
                return;
            };
            parsed.deinit();
            self.done.store(true, .release);
        }
    };

    var wait_ctx = WaitCtx{ .alloc = alloc, .socket_path = harness.socket_path };
    const wait_thread = try std.Thread.spawn(.{}, WaitCtx.run, .{&wait_ctx});

    std.Thread.sleep(50 * std.time.ns_per_ms);

    // Kill the session — handleKill transitions status to .killed, which
    // handleWaitForExit observes on its next poll (25ms).
    var kill_parsed = try socketRequest(alloc, harness.socket_path, .{
        .op = "kill",
        .session = "shutdowner",
    });
    defer kill_parsed.deinit();
    _ = try expectTestOk(kill_parsed);

    wait_thread.join();
    try std.testing.expect(wait_ctx.done.load(.acquire));

    // Clean up session record so the server's post-test shutdown is tidy.
    var del_parsed = try socketRequest(alloc, harness.socket_path, .{
        .op = "delete",
        .session = "shutdowner",
    });
    defer del_parsed.deinit();
    _ = try expectTestOk(del_parsed);
}

// ===========================================================================
// `--json` output tests for info / run / wait (issue #22)
// ===========================================================================

test "info json with no live server populates local fields and marks server down" {
    const alloc = std.testing.allocator;
    const payload = try info_cmd.buildInfoPayload(
        alloc,
        "0.0.0",
        "/tmp/sock",
        "/tmp/state",
        "/tmp/logs",
        null,
    );
    try std.testing.expectEqualStrings("0.0.0", payload.version);
    try std.testing.expectEqualStrings("/tmp/sock", payload.socket_path);
    try std.testing.expectEqualStrings("/tmp/state", payload.state_dir);
    try std.testing.expectEqualStrings("/tmp/logs", payload.log_dir);
    try std.testing.expectEqual(false, payload.server.running);
    try std.testing.expectEqual(@as(?i64, null), payload.server.pid);
    try std.testing.expectEqual(@as(?i64, null), payload.server.uptime_ms);
    // `build` is populated from the `build_info` options module; values
    // depend on the host environment so we only assert presence / shape.
    try std.testing.expect(payload.build.version.len > 0);
    try std.testing.expect(payload.build.mode.len > 0);
}

// Issue #28: `hty info --json` must emit a structured `build` object so
// consumers can distinguish release / dev / no-git builds. We only check
// field names + types here — actual values depend on the git state of
// the checkout running the tests.
test "info json payload serializes a build object with all the issue-28 fields" {
    const alloc = std.testing.allocator;
    const payload = try info_cmd.buildInfoPayload(
        alloc,
        "0.0.0",
        "/tmp/sock",
        "/tmp/state",
        "/tmp/logs",
        null,
    );
    const json = try std.json.Stringify.valueAlloc(alloc, payload, .{});
    defer alloc.free(json);

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, json, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .object);

    const build_val = parsed.value.object.get("build") orelse return error.MissingBuildField;
    try std.testing.expect(build_val == .object);
    const build_obj = build_val.object;

    // Required strings.
    const version_val = build_obj.get("version") orelse return error.MissingField;
    try std.testing.expect(version_val == .string);
    const mode_val = build_obj.get("mode") orelse return error.MissingField;
    try std.testing.expect(mode_val == .string);

    // Nullable git-derived fields: must be present as either string or null.
    for ([_][]const u8{ "commit", "tag", "describe" }) |field| {
        const v = build_obj.get(field) orelse return error.MissingField;
        try std.testing.expect(v == .string or v == .null);
    }
    const dirty_val = build_obj.get("dirty") orelse return error.MissingField;
    try std.testing.expect(dirty_val == .bool);
}

// Issue: top-level `version` in `hty info --json` used to be the zon
// string while `hty --version` printed the richer describe line — the
// two disagreed. Fix is to drive both off `renderVersionString`. Since
// the `run` codepath recomputes `version` from git state, this test
// asserts the invariant directly: the top-level `version` equals
// `build.describe` whenever `describe` is non-null.
test "info json top-level version agrees with build.describe" {
    const alloc = std.testing.allocator;
    const git_info: info_cmd.GitInfo = .{
        .version = "0.3.1",
        .commit = "30aea6bd",
        .tag = null,
        .dirty = false,
        .describe = "v0.3.1-11-g30aea6bd",
    };
    const version_str = try info_cmd.renderVersionString(alloc, git_info);
    defer alloc.free(version_str);
    try std.testing.expectEqualStrings("v0.3.1-11-g30aea6bd", version_str);

    const version_line = try info_cmd.renderVersionLine(alloc, git_info);
    defer alloc.free(version_line);
    // Invariant: the CLI version line is `hty ` + the JSON version string.
    try std.testing.expectEqualStrings("hty v0.3.1-11-g30aea6bd", version_line);
}

test "info json with a live server reports pid and uptime" {
    const alloc = std.testing.allocator;
    var registry = SessionRegistry.init(alloc);
    defer registry.deinit();

    // Make the uptime non-zero so the assertion has something to check.
    std.Thread.sleep(5 * std.time.ns_per_ms);

    var parsed = try testRequest(&registry, .{ .op = "info" });
    defer parsed.deinit();
    const response_line = try std.json.Stringify.valueAlloc(alloc, parsed.value, .{});
    defer alloc.free(response_line);

    const payload = try info_cmd.buildInfoPayload(
        alloc,
        "0.0.0",
        "/tmp/sock",
        "/tmp/state",
        "/tmp/logs",
        response_line,
    );
    try std.testing.expectEqual(true, payload.server.running);
    // pid and uptime_ms should both have been filled from the server.
    try std.testing.expect(payload.server.pid != null);
    try std.testing.expect(payload.server.pid.? > 0);
    try std.testing.expect(payload.server.uptime_ms != null);
    try std.testing.expect(payload.server.uptime_ms.? >= 0);
}

test "run json returns a session with id, name, program, and args (issue #22)" {
    const alloc = std.testing.allocator;
    var registry = SessionRegistry.init(alloc);
    defer registry.deinit();

    var parsed = try testRequest(&registry, .{
        .op = "spawn",
        .name = "runjson",
        .program = "/bin/cat",
        .args = [_][]const u8{"-u"},
        .rows = 8,
        .cols = 24,
        .emit_raw_bytes = false,
    });
    defer parsed.deinit();
    const object = try expectTestOk(parsed);

    const session = object.get("session") orelse return error.InvalidResponse;
    const session_obj = switch (session) {
        .object => |o| o,
        else => return error.InvalidResponse,
    };

    const id_val = session_obj.get("id") orelse return error.InvalidResponse;
    try std.testing.expect(id_val == .string);
    // UUID shape: 36 chars (8-4-4-4-12).
    try std.testing.expectEqual(@as(usize, 36), id_val.string.len);
    try std.testing.expectEqual(@as(u8, '-'), id_val.string[8]);
    try std.testing.expectEqual(@as(u8, '-'), id_val.string[13]);
    try std.testing.expectEqual(@as(u8, '-'), id_val.string[18]);
    try std.testing.expectEqual(@as(u8, '-'), id_val.string[23]);

    const name_val = session_obj.get("name") orelse return error.InvalidResponse;
    try std.testing.expect(name_val == .string);
    try std.testing.expectEqualStrings("runjson", name_val.string);

    const program_val = session_obj.get("program") orelse return error.InvalidResponse;
    try std.testing.expect(program_val == .string);
    try std.testing.expectEqualStrings("/bin/cat", program_val.string);

    const args_val = session_obj.get("args") orelse return error.InvalidResponse;
    try std.testing.expect(args_val == .string);
    try std.testing.expectEqualStrings("-u", args_val.string);

    var kill_parsed = try testRequest(&registry, .{ .op = "kill", .session = "runjson" });
    defer kill_parsed.deinit();
    _ = try expectTestOk(kill_parsed);
}

test "wait --json text match reports matched, elapsed_ms, and text.needle+offset" {
    const alloc = std.testing.allocator;
    var registry = SessionRegistry.init(alloc);
    defer registry.deinit();

    {
        var parsed = try testRequest(&registry, .{
            .op = "spawn",
            .name = "wjson-text",
            .program = "/bin/cat",
            .rows = 8,
            .cols = 40,
            .emit_raw_bytes = false,
        });
        defer parsed.deinit();
        _ = try expectTestOk(parsed);
    }
    {
        var parsed = try testRequest(&registry, .{
            .op = "send_text",
            .session = "wjson-text",
            .text = "greetings earthlings\n",
        });
        defer parsed.deinit();
        _ = try expectTestOk(parsed);
    }
    {
        var parsed = try testRequest(&registry, .{
            .op = "wait_for_text",
            .session = "wjson-text",
            .text = "earthlings",
            .timeout_ms = 2_000,
        });
        defer parsed.deinit();
        const object = try expectTestOk(parsed);

        const wait = object.get("wait") orelse return error.InvalidResponse;
        try std.testing.expect(wait == .object);
        const w = wait.object;

        const matched = w.get("matched") orelse return error.InvalidResponse;
        try std.testing.expect(matched == .string);
        try std.testing.expectEqualStrings("text", matched.string);

        const elapsed = w.get("elapsed_ms") orelse return error.InvalidResponse;
        try std.testing.expect(elapsed == .integer);
        try std.testing.expect(elapsed.integer >= 0);

        const text = w.get("text") orelse return error.InvalidResponse;
        try std.testing.expect(text == .object);
        const needle = text.object.get("needle") orelse return error.InvalidResponse;
        try std.testing.expect(needle == .string);
        try std.testing.expectEqualStrings("earthlings", needle.string);
        const offset = text.object.get("offset") orelse return error.InvalidResponse;
        try std.testing.expect(offset == .integer);
        try std.testing.expect(offset.integer >= 0);

        const session = w.get("session") orelse return error.InvalidResponse;
        try std.testing.expect(session == .string);
        try std.testing.expectEqual(@as(usize, 36), session.string.len);
    }
    var kill_parsed = try testRequest(&registry, .{ .op = "kill", .session = "wjson-text" });
    defer kill_parsed.deinit();
    _ = try expectTestOk(kill_parsed);
}

test "wait --json regex match reports a real byte offset in text.offset" {
    const alloc = std.testing.allocator;
    var registry = SessionRegistry.init(alloc);
    defer registry.deinit();

    {
        var parsed = try testRequest(&registry, .{
            .op = "spawn",
            .name = "wjson-regex",
            .program = "/bin/cat",
            .rows = 8,
            .cols = 60,
            .emit_raw_bytes = false,
        });
        defer parsed.deinit();
        _ = try expectTestOk(parsed);
    }
    {
        var parsed = try testRequest(&registry, .{
            .op = "send_text",
            .session = "wjson-regex",
            .text = "prefix-- order 42 confirmed\n",
        });
        defer parsed.deinit();
        _ = try expectTestOk(parsed);
    }
    {
        var parsed = try testRequest(&registry, .{
            .op = "wait_for_text",
            .session = "wjson-regex",
            .text = "order [0-9]+ confirmed",
            .regex = true,
            .timeout_ms = 2_000,
        });
        defer parsed.deinit();
        const object = try expectTestOk(parsed);

        const wait = object.get("wait") orelse return error.InvalidResponse;
        try std.testing.expect(wait == .object);
        const w = wait.object;

        const matched = w.get("matched") orelse return error.InvalidResponse;
        try std.testing.expect(matched == .string);
        try std.testing.expectEqualStrings("text", matched.string);

        const text = w.get("text") orelse return error.InvalidResponse;
        try std.testing.expect(text == .object);
        const offset = text.object.get("offset") orelse return error.InvalidResponse;
        try std.testing.expect(offset == .integer);
        // Regex matches must now produce a real offset, not -1.
        try std.testing.expect(offset.integer >= 0);

        // The reported offset must actually point at a matching prefix.
        const snapshot = object.get("snapshot") orelse return error.InvalidResponse;
        try std.testing.expect(snapshot == .object);
        const buffer = snapshot.object.get("buffer") orelse return error.InvalidResponse;
        try std.testing.expect(buffer == .string);
        const buf = buffer.string;
        const off: usize = @intCast(offset.integer);
        try std.testing.expect(off < buf.len);
        // The snapshot buffer starts with "prefix-- " before the matching
        // region, so the offset should land at the start of "order ".
        try std.testing.expect(std.mem.startsWith(u8, buf[off..], "order "));
    }

    var kill_parsed = try testRequest(&registry, .{ .op = "kill", .session = "wjson-regex" });
    defer kill_parsed.deinit();
    _ = try expectTestOk(kill_parsed);
}

test "wait --json idle match reports matched=idle and elapsed_ms" {
    const alloc = std.testing.allocator;
    var registry = SessionRegistry.init(alloc);
    defer registry.deinit();

    {
        var parsed = try testRequest(&registry, .{
            .op = "spawn",
            .name = "wjson-idle",
            .program = "/bin/cat",
            .rows = 8,
            .cols = 40,
            .emit_raw_bytes = false,
        });
        defer parsed.deinit();
        _ = try expectTestOk(parsed);
    }
    {
        var parsed = try testRequest(&registry, .{
            .op = "wait_for_idle",
            .session = "wjson-idle",
            .idle_ms = 50,
            .timeout_ms = 2_000,
        });
        defer parsed.deinit();
        const object = try expectTestOk(parsed);

        const wait = object.get("wait") orelse return error.InvalidResponse;
        try std.testing.expect(wait == .object);
        const w = wait.object;

        const matched = w.get("matched") orelse return error.InvalidResponse;
        try std.testing.expect(matched == .string);
        try std.testing.expectEqualStrings("idle", matched.string);

        const elapsed = w.get("elapsed_ms") orelse return error.InvalidResponse;
        try std.testing.expect(elapsed == .integer);
        try std.testing.expect(elapsed.integer >= 0);
    }
    var kill_parsed = try testRequest(&registry, .{ .op = "kill", .session = "wjson-idle" });
    defer kill_parsed.deinit();
    _ = try expectTestOk(kill_parsed);
}

test "wait --json exit match reports matched=exit and exit.code" {
    const alloc = std.testing.allocator;
    var registry = SessionRegistry.init(alloc);
    defer registry.deinit();

    // `true` exits immediately with code 0. Resolve via PATH so this works
    // on Linux (/bin/true) and macOS (/usr/bin/true).
    const true_path = findCommand(alloc, "true") orelse return error.SkipZigTest;
    defer alloc.free(true_path);

    {
        var parsed = try testRequest(&registry, .{
            .op = "spawn",
            .name = "wjson-exit",
            .program = true_path,
            .rows = 8,
            .cols = 24,
            .emit_raw_bytes = false,
        });
        defer parsed.deinit();
        _ = try expectTestOk(parsed);
    }
    {
        var parsed = try testRequest(&registry, .{
            .op = "wait_for_exit",
            .session = "wjson-exit",
            .timeout_ms = 2_000,
        });
        defer parsed.deinit();
        const object = try expectTestOk(parsed);

        const wait = object.get("wait") orelse return error.InvalidResponse;
        try std.testing.expect(wait == .object);
        const w = wait.object;

        const matched = w.get("matched") orelse return error.InvalidResponse;
        try std.testing.expect(matched == .string);
        try std.testing.expectEqualStrings("exit", matched.string);

        const exit_obj_val = w.get("exit") orelse return error.InvalidResponse;
        try std.testing.expect(exit_obj_val == .object);
        const code = exit_obj_val.object.get("code") orelse return error.InvalidResponse;
        try std.testing.expect(code == .integer);
        try std.testing.expectEqual(@as(i64, 0), code.integer);
    }
    // Best-effort cleanup — session may already be gone.
    var kill_parsed = testRequest(&registry, .{ .op = "kill", .session = "wjson-exit" }) catch return;
    kill_parsed.deinit();
}

test "wait --json timeout reports matched=null, timeout=true, and elapsed_ms" {
    const alloc = std.testing.allocator;
    var registry = SessionRegistry.init(alloc);
    defer registry.deinit();

    {
        var parsed = try testRequest(&registry, .{
            .op = "spawn",
            .name = "wjson-timeout",
            .program = "/bin/cat",
            .rows = 8,
            .cols = 24,
            .emit_raw_bytes = false,
        });
        defer parsed.deinit();
        _ = try expectTestOk(parsed);
    }
    {
        var parsed = try testRequest(&registry, .{
            .op = "wait_for_text",
            .session = "wjson-timeout",
            .text = "neverappears",
            .timeout_ms = 150,
        });
        defer parsed.deinit();
        const object = try expectTestOk(parsed);

        const timed_out = object.get("timed_out") orelse return error.InvalidResponse;
        try std.testing.expect(timed_out == .bool);
        try std.testing.expectEqual(true, timed_out.bool);

        const wait = object.get("wait") orelse return error.InvalidResponse;
        try std.testing.expect(wait == .object);
        const w = wait.object;

        const matched = w.get("matched") orelse return error.InvalidResponse;
        try std.testing.expect(matched == .null);

        const to = w.get("timeout") orelse return error.InvalidResponse;
        try std.testing.expect(to == .bool);
        try std.testing.expectEqual(true, to.bool);

        const elapsed = w.get("elapsed_ms") orelse return error.InvalidResponse;
        try std.testing.expect(elapsed == .integer);
        try std.testing.expect(elapsed.integer >= 0);
    }
    var kill_parsed = try testRequest(&registry, .{ .op = "kill", .session = "wjson-timeout" });
    defer kill_parsed.deinit();
    _ = try expectTestOk(kill_parsed);
}

// ============================================================================
// Fused send/run with wait+snapshot (LatentEvals/hty#32)
// ============================================================================
//
// These tests exercise the `wait_and_snapshot` op directly. The op underpins
// `hty send --snapshot --wait-until-*` and `hty run --snapshot
// --wait-until-*` — both client commands compose existing send/spawn calls
// with this single fused wait so the post-action snapshot rides back on the
// same response that satisfies the wait condition.

test "wait_and_snapshot kind=idle returns matched=idle, elapsed_ms, and snapshot" {
    const alloc = std.testing.allocator;
    var registry = SessionRegistry.init(alloc);
    defer registry.deinit();

    {
        var parsed = try testRequest(&registry, .{
            .op = "spawn",
            .name = "fused-idle",
            .program = "/bin/cat",
            .rows = 8,
            .cols = 40,
            .emit_raw_bytes = false,
        });
        defer parsed.deinit();
        _ = try expectTestOk(parsed);
    }
    {
        var parsed = try testRequest(&registry, .{
            .op = "wait_and_snapshot",
            .session = "fused-idle",
            .wait_kind = "idle",
            .idle_ms = 50,
            .timeout_ms = 2_000,
            .snapshot = true,
        });
        defer parsed.deinit();
        const object = try expectTestOk(parsed);

        const wait = object.get("wait") orelse return error.InvalidResponse;
        try std.testing.expect(wait == .object);
        const matched = wait.object.get("matched") orelse return error.InvalidResponse;
        try std.testing.expect(matched == .string);
        try std.testing.expectEqualStrings("idle", matched.string);
        const elapsed = wait.object.get("elapsed_ms") orelse return error.InvalidResponse;
        try std.testing.expect(elapsed == .integer);
        // The op-start floor on idle means we never satisfy idle in 0ms;
        // we should always sit through at least one idle window.
        try std.testing.expect(elapsed.integer >= 50);

        const snap = object.get("snapshot") orelse return error.InvalidResponse;
        try std.testing.expect(snap == .object);
        try std.testing.expect(snap.object.get("buffer") != null);
    }
    var kill_parsed = try testRequest(&registry, .{ .op = "kill", .session = "fused-idle" });
    defer kill_parsed.deinit();
    _ = try expectTestOk(kill_parsed);
}

test "wait_and_snapshot kind=text matches a string and includes the buffer" {
    const alloc = std.testing.allocator;
    var registry = SessionRegistry.init(alloc);
    defer registry.deinit();

    {
        var parsed = try testRequest(&registry, .{
            .op = "spawn",
            .name = "fused-text",
            .program = "/bin/cat",
            .rows = 8,
            .cols = 40,
            .emit_raw_bytes = false,
        });
        defer parsed.deinit();
        _ = try expectTestOk(parsed);
    }
    {
        var parsed = try testRequest(&registry, .{
            .op = "send_text",
            .session = "fused-text",
            .text = "fused-hello\n",
        });
        defer parsed.deinit();
        _ = try expectTestOk(parsed);
    }
    {
        var parsed = try testRequest(&registry, .{
            .op = "wait_and_snapshot",
            .session = "fused-text",
            .wait_kind = "text",
            .text = "fused-hello",
            .timeout_ms = 2_000,
            .snapshot = true,
        });
        defer parsed.deinit();
        const object = try expectTestOk(parsed);

        const wait = object.get("wait") orelse return error.InvalidResponse;
        const matched = wait.object.get("matched") orelse return error.InvalidResponse;
        try std.testing.expectEqualStrings("text", matched.string);

        const snap = object.get("snapshot") orelse return error.InvalidResponse;
        const buffer = snap.object.get("buffer") orelse return error.InvalidResponse;
        try std.testing.expect(std.mem.indexOf(u8, buffer.string, "fused-hello") != null);
    }
    var kill_parsed = try testRequest(&registry, .{ .op = "kill", .session = "fused-text" });
    defer kill_parsed.deinit();
    _ = try expectTestOk(kill_parsed);
}

test "wait_and_snapshot kind=duration sleeps at least the requested ms" {
    const alloc = std.testing.allocator;
    var registry = SessionRegistry.init(alloc);
    defer registry.deinit();

    {
        var parsed = try testRequest(&registry, .{
            .op = "spawn",
            .name = "fused-dur",
            .program = "/bin/cat",
            .rows = 8,
            .cols = 40,
            .emit_raw_bytes = false,
        });
        defer parsed.deinit();
        _ = try expectTestOk(parsed);
    }
    {
        var parsed = try testRequest(&registry, .{
            .op = "wait_and_snapshot",
            .session = "fused-dur",
            .wait_kind = "duration",
            .duration_ms = 80,
            .timeout_ms = 2_000,
            .snapshot = true,
        });
        defer parsed.deinit();
        const object = try expectTestOk(parsed);

        const wait = object.get("wait") orelse return error.InvalidResponse;
        const elapsed = wait.object.get("elapsed_ms") orelse return error.InvalidResponse;
        try std.testing.expect(elapsed == .integer);
        try std.testing.expect(elapsed.integer >= 80);

        try std.testing.expect(object.get("snapshot") != null);
    }
    var kill_parsed = try testRequest(&registry, .{ .op = "kill", .session = "fused-dur" });
    defer kill_parsed.deinit();
    _ = try expectTestOk(kill_parsed);
}

test "wait_and_snapshot snapshot=false omits the snapshot field" {
    const alloc = std.testing.allocator;
    var registry = SessionRegistry.init(alloc);
    defer registry.deinit();

    {
        var parsed = try testRequest(&registry, .{
            .op = "spawn",
            .name = "fused-nosnap",
            .program = "/bin/cat",
            .rows = 8,
            .cols = 40,
            .emit_raw_bytes = false,
        });
        defer parsed.deinit();
        _ = try expectTestOk(parsed);
    }
    {
        var parsed = try testRequest(&registry, .{
            .op = "wait_and_snapshot",
            .session = "fused-nosnap",
            .wait_kind = "idle",
            .idle_ms = 30,
            .timeout_ms = 2_000,
            .snapshot = false,
        });
        defer parsed.deinit();
        const object = try expectTestOk(parsed);

        const wait = object.get("wait") orelse return error.InvalidResponse;
        try std.testing.expect(wait == .object);
        // The Response struct's optional snapshot serializes to JSON `null`
        // when omitted (rather than missing the key entirely), so check for
        // .null rather than absence.
        const snap_val = object.get("snapshot") orelse return error.InvalidResponse;
        try std.testing.expect(snap_val == .null);
    }
    var kill_parsed = try testRequest(&registry, .{ .op = "kill", .session = "fused-nosnap" });
    defer kill_parsed.deinit();
    _ = try expectTestOk(kill_parsed);
}

test "wait_and_snapshot kind=none with snapshot=true returns the snapshot immediately" {
    const alloc = std.testing.allocator;
    var registry = SessionRegistry.init(alloc);
    defer registry.deinit();

    {
        var parsed = try testRequest(&registry, .{
            .op = "spawn",
            .name = "fused-none",
            .program = "/bin/cat",
            .rows = 8,
            .cols = 40,
            .emit_raw_bytes = false,
        });
        defer parsed.deinit();
        _ = try expectTestOk(parsed);
    }
    {
        var parsed = try testRequest(&registry, .{
            .op = "wait_and_snapshot",
            .session = "fused-none",
            .wait_kind = "none",
            .snapshot = true,
        });
        defer parsed.deinit();
        const object = try expectTestOk(parsed);

        // No matched value when there's no wait.
        const wait = object.get("wait") orelse return error.InvalidResponse;
        try std.testing.expect(wait.object.get("matched").? == .null);

        const snap = object.get("snapshot") orelse return error.InvalidResponse;
        try std.testing.expect(snap == .object);
        try std.testing.expect(snap.object.get("buffer") != null);
    }
    var kill_parsed = try testRequest(&registry, .{ .op = "kill", .session = "fused-none" });
    defer kill_parsed.deinit();
    _ = try expectTestOk(kill_parsed);
}

test "wait_and_snapshot kind=text reports timed_out=true on timeout" {
    const alloc = std.testing.allocator;
    var registry = SessionRegistry.init(alloc);
    defer registry.deinit();

    {
        var parsed = try testRequest(&registry, .{
            .op = "spawn",
            .name = "fused-timeout",
            .program = "/bin/cat",
            .rows = 8,
            .cols = 40,
            .emit_raw_bytes = false,
        });
        defer parsed.deinit();
        _ = try expectTestOk(parsed);
    }
    {
        var parsed = try testRequest(&registry, .{
            .op = "wait_and_snapshot",
            .session = "fused-timeout",
            .wait_kind = "text",
            .text = "neverappears",
            .timeout_ms = 150,
            .snapshot = false,
        });
        defer parsed.deinit();
        const object = try expectTestOk(parsed);

        const timed_out = object.get("timed_out") orelse return error.InvalidResponse;
        try std.testing.expectEqual(true, timed_out.bool);

        const wait = object.get("wait") orelse return error.InvalidResponse;
        try std.testing.expect(wait.object.get("matched").? == .null);
        const to = wait.object.get("timeout") orelse return error.InvalidResponse;
        try std.testing.expectEqual(true, to.bool);
    }
    var kill_parsed = try testRequest(&registry, .{ .op = "kill", .session = "fused-timeout" });
    defer kill_parsed.deinit();
    _ = try expectTestOk(kill_parsed);
}

test "wait_and_snapshot --wait-until-idle has op-start floor (no instant fire after long quiet)" {
    // Race regression test (the central correctness goal of issue #32):
    // a session that's been quiet for >100ms before this op begins should
    // NOT immediately satisfy --wait-until-idle 100. The server measures
    // idle from `max(last_screen_change, op_start_ms)`, so the wait must
    // sit through at least the requested idle window even when no fresh
    // screen change is observed during the op.
    const alloc = std.testing.allocator;
    var registry = SessionRegistry.init(alloc);
    defer registry.deinit();

    {
        var parsed = try testRequest(&registry, .{
            .op = "spawn",
            .name = "fused-floor",
            .program = "/bin/cat",
            .rows = 8,
            .cols = 40,
            .emit_raw_bytes = false,
        });
        defer parsed.deinit();
        _ = try expectTestOk(parsed);
    }
    // Drain the initial spawn screen change, then sit idle long enough
    // that any naive `now - last_screen_change` would already exceed our
    // target idle_ms.
    std.Thread.sleep(250 * std.time.ns_per_ms);
    {
        var parsed = try testRequest(&registry, .{
            .op = "wait_and_snapshot",
            .session = "fused-floor",
            .wait_kind = "idle",
            .idle_ms = 100,
            .timeout_ms = 2_000,
            .snapshot = false,
        });
        defer parsed.deinit();
        const object = try expectTestOk(parsed);

        const wait = object.get("wait") orelse return error.InvalidResponse;
        const elapsed = wait.object.get("elapsed_ms") orelse return error.InvalidResponse;
        try std.testing.expect(elapsed == .integer);
        // With the op-start floor, elapsed must be at least one idle
        // window. Without the fix, elapsed would be ~0ms because the
        // pre-existing 250ms quiet would already satisfy the threshold.
        try std.testing.expect(elapsed.integer >= 100);
    }
    var kill_parsed = try testRequest(&registry, .{ .op = "kill", .session = "fused-floor" });
    defer kill_parsed.deinit();
    _ = try expectTestOk(kill_parsed);
}

test "wait_and_snapshot timeout_ms=0 disables the timeout" {
    // With timeout_ms=0, the deadline is i64.max — the op only returns
    // when the wait condition is satisfied. Pair with a quick-firing
    // condition (a 30ms idle window) so the test isn't slow.
    const alloc = std.testing.allocator;
    var registry = SessionRegistry.init(alloc);
    defer registry.deinit();

    {
        var parsed = try testRequest(&registry, .{
            .op = "spawn",
            .name = "fused-no-timeout",
            .program = "/bin/cat",
            .rows = 8,
            .cols = 40,
            .emit_raw_bytes = false,
        });
        defer parsed.deinit();
        _ = try expectTestOk(parsed);
    }
    {
        var parsed = try testRequest(&registry, .{
            .op = "wait_and_snapshot",
            .session = "fused-no-timeout",
            .wait_kind = "idle",
            .idle_ms = 30,
            .timeout_ms = 0,
            .snapshot = false,
        });
        defer parsed.deinit();
        const object = try expectTestOk(parsed);

        // Should succeed (not time out).
        const timed_out = object.get("timed_out") orelse return error.InvalidResponse;
        try std.testing.expectEqual(false, timed_out.bool);
        const wait = object.get("wait") orelse return error.InvalidResponse;
        const matched = wait.object.get("matched") orelse return error.InvalidResponse;
        try std.testing.expectEqualStrings("idle", matched.string);
    }
    var kill_parsed = try testRequest(&registry, .{ .op = "kill", .session = "fused-no-timeout" });
    defer kill_parsed.deinit();
    _ = try expectTestOk(kill_parsed);
}

test "wait_and_snapshot kind=regex matches a pattern and reports matched=regex" {
    const alloc = std.testing.allocator;
    var registry = SessionRegistry.init(alloc);
    defer registry.deinit();

    {
        var parsed = try testRequest(&registry, .{
            .op = "spawn",
            .name = "fused-regex",
            .program = "/bin/cat",
            .rows = 8,
            .cols = 60,
            .emit_raw_bytes = false,
        });
        defer parsed.deinit();
        _ = try expectTestOk(parsed);
    }
    {
        var parsed = try testRequest(&registry, .{
            .op = "send_text",
            .session = "fused-regex",
            .text = "order 1234 confirmed\n",
        });
        defer parsed.deinit();
        _ = try expectTestOk(parsed);
    }
    {
        var parsed = try testRequest(&registry, .{
            .op = "wait_and_snapshot",
            .session = "fused-regex",
            .wait_kind = "regex",
            .text = "order [0-9]+ confirmed",
            .timeout_ms = 2_000,
            .snapshot = true,
        });
        defer parsed.deinit();
        const object = try expectTestOk(parsed);

        const wait = object.get("wait") orelse return error.InvalidResponse;
        const matched = wait.object.get("matched") orelse return error.InvalidResponse;
        try std.testing.expectEqualStrings("regex", matched.string);

        // Regex matches still surface text.needle/text.offset.
        const text_obj = wait.object.get("text") orelse return error.InvalidResponse;
        try std.testing.expect(text_obj == .object);
        const offset = text_obj.object.get("offset") orelse return error.InvalidResponse;
        try std.testing.expect(offset == .integer);
        try std.testing.expect(offset.integer >= 0);
    }
    var kill_parsed = try testRequest(&registry, .{ .op = "kill", .session = "fused-regex" });
    defer kill_parsed.deinit();
    _ = try expectTestOk(kill_parsed);
}

test "wait_and_snapshot kind=exit returns matched=exit and the exit code" {
    const alloc = std.testing.allocator;
    var registry = SessionRegistry.init(alloc);
    defer registry.deinit();

    const true_path = findCommand(alloc, "true") orelse return error.SkipZigTest;
    defer alloc.free(true_path);

    {
        var parsed = try testRequest(&registry, .{
            .op = "spawn",
            .name = "fused-exit",
            .program = true_path,
            .rows = 8,
            .cols = 24,
            .emit_raw_bytes = false,
        });
        defer parsed.deinit();
        _ = try expectTestOk(parsed);
    }
    {
        var parsed = try testRequest(&registry, .{
            .op = "wait_and_snapshot",
            .session = "fused-exit",
            .wait_kind = "exit",
            .timeout_ms = 2_000,
            .snapshot = true,
        });
        defer parsed.deinit();
        const object = try expectTestOk(parsed);

        const wait = object.get("wait") orelse return error.InvalidResponse;
        const matched = wait.object.get("matched") orelse return error.InvalidResponse;
        try std.testing.expectEqualStrings("exit", matched.string);

        const exit_obj = wait.object.get("exit") orelse return error.InvalidResponse;
        const code = exit_obj.object.get("code") orelse return error.InvalidResponse;
        try std.testing.expectEqual(@as(i64, 0), code.integer);

        // Snapshot is still present even after exit.
        try std.testing.expect(object.get("snapshot") != null);
    }
    var kill_parsed = testRequest(&registry, .{ .op = "kill", .session = "fused-exit" }) catch return;
    kill_parsed.deinit();
}

// ============================================================================
// Session log origin tagging + attach lifecycle (LatentEvals/hty#33)
// ============================================================================
//
// The send-origin test goes through the standard `testRequest` harness so it
// covers the full RPC path. The attach-origin tests construct `AttachClient`s
// directly from a socketpair to avoid depending on the server's XDG-resolved
// log dir — we want these tests hermetic under /tmp.

const session_mod_tests = @import("session.zig");
const AttachClientTest = session_mod_tests.AttachClient;
const server_attach_mod = @import("server_attach.zig");
const attach_mod = @import("attach.zig");
const uuid_mod_tests = @import("uuid.zig");
const log_mod_tests = @import("log.zig");
const replay_mod = @import("commands/replay.zig");
const logs_cmd = @import("commands/logs.zig");
const hex = @import("hex.zig");

/// Set up a hermetic log dir under /tmp for an attach test. Returns the
/// absolute log_dir path (owned by the caller; free with `alloc.free`).
fn setupAttachLogDir(alloc: std.mem.Allocator, tag: []const u8) ![]u8 {
    const log_dir = try std.fmt.allocPrint(
        alloc,
        "/tmp/hty-attach-{s}-{d}",
        .{ tag, std.time.nanoTimestamp() },
    );
    errdefer alloc.free(log_dir);
    try std.fs.cwd().makePath(log_dir);
    const by_name = try std.fmt.allocPrint(alloc, "{s}/by-name", .{log_dir});
    defer alloc.free(by_name);
    try std.fs.cwd().makePath(by_name);
    return log_dir;
}

/// Read the session's log file through the by-name symlink.
fn readAttachLog(alloc: std.mem.Allocator, log_dir: []const u8, name: []const u8) ![]u8 {
    const link_path = try std.fmt.allocPrint(alloc, "{s}/by-name/{s}.jsonl", .{ log_dir, name });
    defer alloc.free(link_path);
    const file = try std.fs.openFileAbsolute(link_path, .{});
    defer file.close();
    return try file.readToEndAlloc(alloc, 1024 * 1024);
}

/// Parse a JSONL log into owned objects. Caller frees the returned slice
/// AND each parsed value inside via `parsed[i].deinit()`.
const LoggedObj = struct {
    parsed: std.json.Parsed(std.json.Value),
    obj: std.json.ObjectMap,
};

fn parseLogEvents(alloc: std.mem.Allocator, bytes: []const u8) ![]LoggedObj {
    var out = std.array_list.Managed(LoggedObj).init(alloc);
    errdefer {
        for (out.items) |item| item.parsed.deinit();
        out.deinit();
    }
    var it = std.mem.splitScalar(u8, bytes, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        var parsed = try std.json.parseFromSlice(std.json.Value, alloc, line, .{});
        if (parsed.value != .object) {
            parsed.deinit();
            continue;
        }
        try out.append(.{ .parsed = parsed, .obj = parsed.value.object });
    }
    return out.toOwnedSlice();
}

fn freeLogEvents(items: []LoggedObj) void {
    for (items) |*item| item.parsed.deinit();
    std.testing.allocator.free(items);
}

test "issue #33: send ops tag log events with origin=send" {
    const alloc = std.testing.allocator;
    const log_dir = try setupAttachLogDir(alloc, "send-origin");
    defer alloc.free(log_dir);
    defer std.fs.cwd().deleteTree(log_dir) catch {};

    var registry = SessionRegistry.init(alloc);
    defer registry.deinit();
    registry.log_dir = log_dir;

    {
        var parsed = try testRequest(&registry, .{
            .op = "spawn",
            .name = "sendorig",
            .program = "/bin/cat",
            .rows = 8,
            .cols = 24,
        });
        defer parsed.deinit();
        _ = try expectTestOk(parsed);
    }
    {
        var parsed = try testRequest(&registry, .{
            .op = "send_text",
            .session = "sendorig",
            .text = "y",
        });
        defer parsed.deinit();
        _ = try expectTestOk(parsed);
    }
    {
        var parsed = try testRequest(&registry, .{ .op = "kill", .session = "sendorig" });
        defer parsed.deinit();
        _ = try expectTestOk(parsed);
    }

    const contents = try readAttachLog(alloc, log_dir, "sendorig");
    defer alloc.free(contents);

    // Every input event must carry `origin:"send"` — and there must be
    // at least one, since we issued a send_text.
    const events = try parseLogEvents(alloc, contents);
    defer freeLogEvents(events);
    var saw_input = false;
    for (events) |ev| {
        const kind = ev.obj.get("kind") orelse continue;
        if (kind != .string) continue;
        if (!std.mem.eql(u8, kind.string, "input")) continue;
        saw_input = true;
        const origin = ev.obj.get("origin") orelse return error.MissingOrigin;
        try std.testing.expect(origin == .string);
        try std.testing.expectEqualStrings("send", origin.string);
    }
    try std.testing.expect(saw_input);
}

/// Make a connected socketpair and return (local, peer) as `std.net.Stream`s.
/// Caller closes both. `local` is the end we hand to `AttachClient`; `peer`
/// is the end the test uses to pretend to be an attach client.
const SocketPair = struct {
    local: std.net.Stream,
    peer: std.net.Stream,
};

fn makeSocketPair() !SocketPair {
    var fds: [2]std.posix.fd_t = undefined;
    const rc = std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds);
    if (rc != 0) return error.SocketPairFailed;
    return .{
        .local = .{ .handle = fds[0] },
        .peer = .{ .handle = fds[1] },
    };
}

/// Build an AttachClient with a minted client_id over `local` and register it
/// on the session's attach list, the way `handleAttachConnection` would. The
/// caller owns lifecycle — the client is reaped via `reapClosedAttachClients`
/// after its socket is closed, OR via session deinit.
fn registerAttachClient(
    alloc: std.mem.Allocator,
    sess: *session_mod_tests.Session,
    local: std.net.Stream,
) !*AttachClientTest {
    var uuid_buf: [36]u8 = undefined;
    uuid_mod_tests.generateUuidV7(&uuid_buf);
    const client_id = try std.fmt.allocPrint(alloc, "attach-{s}", .{uuid_buf[0..]});
    errdefer alloc.free(client_id);

    const client = try alloc.create(AttachClientTest);
    errdefer alloc.destroy(client);
    client.* = .{
        .alloc = alloc,
        .session = sess,
        .stream = local,
        .client_id = client_id,
    };

    // Mirror production attach setup: broadcast sockets are non-blocking.
    try session_mod_tests.setStreamNonBlocking(local.handle);

    try sess.attach_clients.append(alloc, client);

    // Record the connect event — this is what `handleAttachConnection`
    // does in production right after appending to the list.
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    log_mod_tests.logAttachConnectEvent(arena_state.allocator(), sess, client.client_id);
    return client;
}

/// Get a session pointer by name for tests that need to poke at the
/// attach machinery directly. Returns an error if the session is gone.
/// The borrow acquired by `resolveOrSole` is released immediately — the
/// returned pointer is a bare peek, valid only while the test refrains
/// from deleting the session on another thread.
fn sessionByName(registry: *SessionRegistry, name: []const u8) !*session_mod_tests.Session {
    const sess = try registry.resolveOrSole(name);
    registry.release(sess);
    return sess;
}

test "issue #33: attach lifecycle logs connect, input{origin=attach}, disconnect" {
    const alloc = std.testing.allocator;
    const log_dir = try setupAttachLogDir(alloc, "attach-lifecycle");
    defer alloc.free(log_dir);
    defer std.fs.cwd().deleteTree(log_dir) catch {};

    var registry = SessionRegistry.init(alloc);
    defer registry.deinit();
    registry.log_dir = log_dir;

    {
        var parsed = try testRequest(&registry, .{
            .op = "spawn",
            .name = "atcat",
            .program = "/bin/cat",
            .rows = 8,
            .cols = 24,
        });
        defer parsed.deinit();
        _ = try expectTestOk(parsed);
    }

    const sess = try sessionByName(&registry, "atcat");

    // Simulate an attach connection with a socketpair.
    const pair = try makeSocketPair();
    defer pair.peer.close();

    const client = try registerAttachClient(alloc, sess, pair.local);
    const client_id_owned = try alloc.dupe(u8, client.client_id);
    defer alloc.free(client_id_owned);

    // Dispatch an input frame the way the event loop's frame parser would.
    const frame = "{\"op\":\"input\",\"bytes_hex\":\"71\"}";
    try server_attach_mod.dispatchAttachFrame(client, frame);

    // Abort: close the peer, mark the client closed, reap.
    client.shutdown();
    attach_mod.reapClosedAttachClients(sess);

    {
        var kill_parsed = try testRequest(&registry, .{ .op = "kill", .session = "atcat" });
        defer kill_parsed.deinit();
        _ = try expectTestOk(kill_parsed);
    }

    const contents = try readAttachLog(alloc, log_dir, "atcat");
    defer alloc.free(contents);

    const events = try parseLogEvents(alloc, contents);
    defer freeLogEvents(events);

    var saw_connect = false;
    var saw_attach_input = false;
    var saw_disconnect = false;
    for (events) |ev| {
        const kind_v = ev.obj.get("kind") orelse continue;
        if (kind_v != .string) continue;
        const kind = kind_v.string;

        if (std.mem.eql(u8, kind, "attach_connect")) {
            const cid = ev.obj.get("client_id") orelse return error.MissingClientId;
            try std.testing.expectEqualStrings(client_id_owned, cid.string);
            saw_connect = true;
        } else if (std.mem.eql(u8, kind, "attach_disconnect")) {
            const cid = ev.obj.get("client_id") orelse return error.MissingClientId;
            try std.testing.expectEqualStrings(client_id_owned, cid.string);
            saw_disconnect = true;
        } else if (std.mem.eql(u8, kind, "input")) {
            const origin = ev.obj.get("origin") orelse return error.MissingOrigin;
            if (std.mem.eql(u8, origin.string, "attach")) {
                const cid = ev.obj.get("client_id") orelse return error.MissingClientId;
                try std.testing.expectEqualStrings(client_id_owned, cid.string);
                saw_attach_input = true;
            }
        }
    }
    try std.testing.expect(saw_connect);
    try std.testing.expect(saw_attach_input);
    try std.testing.expect(saw_disconnect);

    // client_id format is documented: "attach-" + UUIDv7.
    try std.testing.expect(std.mem.startsWith(u8, client_id_owned, "attach-"));
    try std.testing.expectEqual(@as(usize, "attach-".len + 36), client_id_owned.len);
}

test "issue #33: interleaved send/attach produces ordered origin labels" {
    const alloc = std.testing.allocator;
    const log_dir = try setupAttachLogDir(alloc, "interleaved");
    defer alloc.free(log_dir);
    defer std.fs.cwd().deleteTree(log_dir) catch {};

    var registry = SessionRegistry.init(alloc);
    defer registry.deinit();
    registry.log_dir = log_dir;

    {
        var parsed = try testRequest(&registry, .{
            .op = "spawn",
            .name = "inter",
            .program = "/bin/cat",
            .rows = 8,
            .cols = 24,
        });
        defer parsed.deinit();
        _ = try expectTestOk(parsed);
    }

    // 1. send
    {
        var parsed = try testRequest(&registry, .{
            .op = "send_text",
            .session = "inter",
            .text = "a",
        });
        defer parsed.deinit();
        _ = try expectTestOk(parsed);
    }

    // 2. attach, input, detach
    const sess = try sessionByName(&registry, "inter");
    const pair = try makeSocketPair();
    defer pair.peer.close();

    const client = try registerAttachClient(alloc, sess, pair.local);
    const frame = "{\"op\":\"input\",\"bytes_hex\":\"62\"}"; // 'b'
    try server_attach_mod.dispatchAttachFrame(client, frame);
    client.shutdown();
    attach_mod.reapClosedAttachClients(sess);

    // 3. send again
    {
        var parsed = try testRequest(&registry, .{
            .op = "send_text",
            .session = "inter",
            .text = "c",
        });
        defer parsed.deinit();
        _ = try expectTestOk(parsed);
    }

    {
        var kill_parsed = try testRequest(&registry, .{ .op = "kill", .session = "inter" });
        defer kill_parsed.deinit();
        _ = try expectTestOk(kill_parsed);
    }

    const contents = try readAttachLog(alloc, log_dir, "inter");
    defer alloc.free(contents);

    // Walk events and check the origin labels on input events appear in the
    // expected order: send, attach, send. Also assert the attach input is
    // bracketed by attach_connect / attach_disconnect.
    const events = try parseLogEvents(alloc, contents);
    defer freeLogEvents(events);

    var input_origins = std.array_list.Managed([]const u8).init(alloc);
    defer input_origins.deinit();
    var has_connect_before_attach_input = false;
    var has_disconnect_after_attach_input = false;
    var attach_input_idx: ?usize = null;

    for (events, 0..) |ev, idx| {
        const kind_v = ev.obj.get("kind") orelse continue;
        if (kind_v != .string) continue;
        const kind = kind_v.string;
        if (std.mem.eql(u8, kind, "input")) {
            const origin = ev.obj.get("origin") orelse return error.MissingOrigin;
            try input_origins.append(origin.string);
            if (std.mem.eql(u8, origin.string, "attach")) {
                attach_input_idx = idx;
            }
        }
    }
    try std.testing.expect(attach_input_idx != null);
    for (events[0..attach_input_idx.?]) |ev| {
        const kind_v = ev.obj.get("kind") orelse continue;
        if (kind_v == .string and std.mem.eql(u8, kind_v.string, "attach_connect")) {
            has_connect_before_attach_input = true;
        }
    }
    for (events[attach_input_idx.? + 1 ..]) |ev| {
        const kind_v = ev.obj.get("kind") orelse continue;
        if (kind_v == .string and std.mem.eql(u8, kind_v.string, "attach_disconnect")) {
            has_disconnect_after_attach_input = true;
        }
    }
    try std.testing.expect(has_connect_before_attach_input);
    try std.testing.expect(has_disconnect_after_attach_input);

    try std.testing.expectEqual(@as(usize, 3), input_origins.items.len);
    try std.testing.expectEqualStrings("send", input_origins.items[0]);
    try std.testing.expectEqualStrings("attach", input_origins.items[1]);
    try std.testing.expectEqualStrings("send", input_origins.items[2]);
}

test "issue #33: abrupt attach drop still logs attach_disconnect" {
    const alloc = std.testing.allocator;
    const log_dir = try setupAttachLogDir(alloc, "abrupt");
    defer alloc.free(log_dir);
    defer std.fs.cwd().deleteTree(log_dir) catch {};

    var registry = SessionRegistry.init(alloc);
    defer registry.deinit();
    registry.log_dir = log_dir;

    {
        var parsed = try testRequest(&registry, .{
            .op = "spawn",
            .name = "abrupt",
            .program = "/bin/cat",
            .rows = 8,
            .cols = 24,
        });
        defer parsed.deinit();
        _ = try expectTestOk(parsed);
    }

    const sess = try sessionByName(&registry, "abrupt");
    const pair = try makeSocketPair();

    const client = try registerAttachClient(alloc, sess, pair.local);
    const client_id_owned = try alloc.dupe(u8, client.client_id);
    defer alloc.free(client_id_owned);

    // "Abrupt": close the peer end (no detach op, no protocol teardown).
    // Mirror what the event loop does when it observes EOF on an attach
    // conn: flip the client closed, then the reaper does the rest.
    pair.peer.close();
    client.shutdown();
    attach_mod.reapClosedAttachClients(sess);

    {
        var kill_parsed = try testRequest(&registry, .{ .op = "kill", .session = "abrupt" });
        defer kill_parsed.deinit();
        _ = try expectTestOk(kill_parsed);
    }

    const contents = try readAttachLog(alloc, log_dir, "abrupt");
    defer alloc.free(contents);

    const events = try parseLogEvents(alloc, contents);
    defer freeLogEvents(events);

    var disconnects: usize = 0;
    for (events) |ev| {
        const kind_v = ev.obj.get("kind") orelse continue;
        if (kind_v != .string) continue;
        if (std.mem.eql(u8, kind_v.string, "attach_disconnect")) {
            const cid = ev.obj.get("client_id") orelse return error.MissingClientId;
            try std.testing.expectEqualStrings(client_id_owned, cid.string);
            disconnects += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 1), disconnects);
}

test "issue #33: pre-feature log parses through replayToTerminal (backward compat)" {
    const alloc = std.testing.allocator;

    // Synthetic pre-feature log: no `origin` on the input event, no
    // `attach_*` events. Every pre-feature session matched this shape, so
    // if replay blows up on this it's a hard regression.
    const legacy_log =
        \\{"t":1700000000000,"kind":"spawn","program":"cat","args":[],"rows":24,"cols":80}
        \\{"t":1700000000100,"kind":"input","bytes_hex":"68"}
        \\{"t":1700000000110,"kind":"output","bytes_hex":"68"}
        \\{"t":1700000000120,"kind":"exited","code":0}
    ;

    var result = try replay_mod.replayToTerminal(alloc, legacy_log, 24, 80);
    defer result.deinit(alloc);
    try std.testing.expectEqual(@as(u16, 24), result.rows);
    try std.testing.expectEqual(@as(u16, 80), result.cols);
}

test "issue #33: hty logs renders [send] and [attach] prefixes" {
    const alloc = std.testing.allocator;

    // Build mixed-origin log bytes in-memory and feed them through the
    // same code path `hty logs` uses to render human-readable detail.
    const mixed_log =
        \\{"t":100,"kind":"spawn","program":"cat","args":[],"rows":24,"cols":80}
        \\{"t":200,"kind":"input","origin":"send","bytes_hex":"79"}
        \\{"t":300,"kind":"attach_connect","client_id":"attach-abcd1234"}
        \\{"t":400,"kind":"input","origin":"attach","client_id":"attach-abcd1234","bytes_hex":"71"}
        \\{"t":500,"kind":"attach_disconnect","client_id":"attach-abcd1234"}
        \\{"t":600,"kind":"input","bytes_hex":"7a"}
    ;

    var saw_send_prefix = false;
    var saw_attach_prefix = false;
    var saw_unknown_prefix = false;

    var it = std.mem.splitScalar(u8, mixed_log, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        var parsed = try std.json.parseFromSlice(std.json.Value, alloc, line, .{});
        defer parsed.deinit();
        if (parsed.value != .object) continue;
        const obj = parsed.value.object;
        const kind_v = obj.get("kind") orelse continue;
        if (kind_v != .string) continue;
        const kind = kind_v.string;
        if (!std.mem.eql(u8, kind, "input")) continue;

        const detail = try logs_cmd.buildEventDetailForTest(alloc, kind, obj);
        defer alloc.free(detail);

        if (std.mem.indexOf(u8, detail, "[send]") != null) saw_send_prefix = true;
        if (std.mem.indexOf(u8, detail, "[attach]") != null) saw_attach_prefix = true;
        if (std.mem.indexOf(u8, detail, "[?]") != null) saw_unknown_prefix = true;
    }
    try std.testing.expect(saw_send_prefix);
    try std.testing.expect(saw_attach_prefix);
    // The trailing legacy-style input (no origin) must render as `[?]`
    // so readers can still distinguish it from real origins.
    try std.testing.expect(saw_unknown_prefix);
}

// ============================================================================
// Push-based watch + pre-creation (LatentEvals/hty#29)
// ============================================================================

/// Line-buffered reader around a stream with a small per-line timeout.
/// Holds a persistent buffer so that bytes read past the newline of one
/// line are preserved for the next call. Tests instantiate one and use
/// `readLine` as many times as needed, then call `deinit`.
const LineReader = struct {
    alloc: std.mem.Allocator,
    stream: std.net.Stream,
    buf: std.array_list.Managed(u8),

    fn init(alloc: std.mem.Allocator, stream: std.net.Stream) LineReader {
        return .{
            .alloc = alloc,
            .stream = stream,
            .buf = std.array_list.Managed(u8).init(alloc),
        };
    }

    fn deinit(self: *LineReader) void {
        self.buf.deinit();
    }

    /// Read until the next '\n' and return the bytes before it (newline
    /// consumed but not returned). Caller owns the returned slice.
    fn readLine(self: *LineReader, timeout_ms: u64) ![]u8 {
        const start_ns = std.time.nanoTimestamp();
        const deadline_ns = start_ns + @as(i128, @intCast(timeout_ms * std.time.ns_per_ms));

        // Serve from the existing buffer if a full line is already there.
        if (std.mem.indexOfScalar(u8, self.buf.items, '\n')) |nl| {
            return try self.popLine(nl);
        }

        var chunk: [512]u8 = undefined;
        while (true) {
            var pfd = [_]std.posix.pollfd{.{
                .fd = self.stream.handle,
                .events = std.posix.POLL.IN,
                .revents = 0,
            }};
            const now_ns = std.time.nanoTimestamp();
            if (now_ns >= deadline_ns) return error.ReadTimeout;
            const remaining_ms: i32 = @intCast(@divTrunc(deadline_ns - now_ns, std.time.ns_per_ms));
            const rc = try std.posix.poll(&pfd, @max(1, remaining_ms));
            if (rc == 0) return error.ReadTimeout;
            if ((pfd[0].revents & std.posix.POLL.IN) == 0) continue;

            const n = try self.stream.read(&chunk);
            if (n == 0) return error.EndOfStream;
            try self.buf.appendSlice(chunk[0..n]);
            if (std.mem.indexOfScalar(u8, self.buf.items, '\n')) |nl| {
                return try self.popLine(nl);
            }
        }
    }

    fn popLine(self: *LineReader, nl: usize) ![]u8 {
        const line = try self.alloc.dupe(u8, self.buf.items[0..nl]);
        const rest_len = self.buf.items.len - nl - 1;
        std.mem.copyForwards(u8, self.buf.items[0..rest_len], self.buf.items[nl + 1 ..]);
        self.buf.shrinkRetainingCapacity(rest_len);
        return line;
    }
};

test "issue #29: watch against existing session receives started + initial snapshot" {
    const alloc = std.testing.allocator;
    const log_dir = try setupAttachLogDir(alloc, "watch-existing");
    defer alloc.free(log_dir);
    defer std.fs.cwd().deleteTree(log_dir) catch {};

    var registry = SessionRegistry.init(alloc);
    defer registry.deinit();
    registry.log_dir = log_dir;

    // Spawn the target session up-front.
    {
        var parsed = try testRequest(&registry, .{
            .op = "spawn",
            .name = "watchexist",
            .program = "/bin/cat",
            .rows = 8,
            .cols = 24,
        });
        defer parsed.deinit();
        _ = try expectTestOk(parsed);
    }

    // Simulate a watch connection with a socketpair. We drive
    // handleAttachConnection directly (no real accept loop) to keep the
    // test hermetic. It is given the server-side half of the pair.
    const pair = try makeSocketPair();
    // Note: the peer is explicitly closed below after we're done reading
    // from it — not via defer — so the server's reader thread can notice
    // EOF while the session is still alive, without double-close.

    const line = "{\"op\":\"watch\",\"session\":\"watchexist\"}";
    const result = try server_attach_mod.handleAttachConnection(
        alloc,
        &registry,
        pair.local,
        line,
        true, // read_only
    );
    const watch_client = switch (result) {
        .attached => |client| client,
        else => return error.ExpectedAttached,
    };
    try std.testing.expect(watch_client.read_only);

    var reader = LineReader.init(alloc, pair.peer);
    defer reader.deinit();

    // First line is the ack.
    const ack = try reader.readLine(1000);
    defer alloc.free(ack);
    {
        var parsed = try std.json.parseFromSlice(std.json.Value, alloc, ack, .{});
        defer parsed.deinit();
        try std.testing.expect(parsed.value == .object);
        const ok = parsed.value.object.get("ok") orelse return error.MissingOk;
        try std.testing.expect(ok == .bool and ok.bool);
        // Not waiting — the session existed when we subscribed.
        if (parsed.value.object.get("waiting")) |w| {
            try std.testing.expect(!(w == .bool and w.bool));
        }
    }

    // Next line should be the initial snapshot frame.
    const snap = try reader.readLine(1000);
    defer alloc.free(snap);
    {
        var parsed = try std.json.parseFromSlice(std.json.Value, alloc, snap, .{});
        defer parsed.deinit();
        const kind = parsed.value.object.get("kind") orelse return error.MissingKind;
        try std.testing.expect(kind == .string);
        try std.testing.expectEqualStrings("output", kind.string);
        try std.testing.expect(parsed.value.object.get("bytes_hex") != null);
    }

    // Clean up: there is no reader thread anymore — mark the client
    // closed the way the loop would on EOF and reap it directly.
    const sess = try sessionByName(&registry, "watchexist");
    pair.peer.close();
    watch_client.shutdown();
    attach_mod.reapClosedAttachClients(sess);

    {
        var kill_parsed = try testRequest(&registry, .{ .op = "kill", .session = "watchexist" });
        defer kill_parsed.deinit();
        _ = try expectTestOk(kill_parsed);
    }
}

/// Open a raw attach-style connection against a harness server: connect
/// to the Unix socket and write the request line. The caller reads
/// frames off the returned stream (and owns/closes it).
fn openStreamingConn(socket_path: []const u8, request_line: []const u8) !std.net.Stream {
    const stream = try std.net.connectUnixSocket(socket_path);
    errdefer stream.close();
    try stream.writeAll(request_line);
    try stream.writeAll("\n");
    return stream;
}

/// Read frames until one of kind `expected_kind` arrives (skipping other
/// kinds), within `timeout_ms` total. Returns the frame's `bytes_hex`
/// decoded when present (caller frees), or an empty slice.
fn expectFrameKind(
    alloc: std.mem.Allocator,
    reader: *LineReader,
    expected_kind: []const u8,
    timeout_ms: u64,
) ![]const u8 {
    const deadline_ns = std.time.nanoTimestamp() + @as(i128, @intCast(timeout_ms)) * std.time.ns_per_ms;
    while (true) {
        const now_ns = std.time.nanoTimestamp();
        if (now_ns >= deadline_ns) return error.FrameTimeout;
        const remaining_ms: u64 = @intCast(@divTrunc(deadline_ns - now_ns, std.time.ns_per_ms));
        const line = try reader.readLine(@max(1, remaining_ms));
        defer alloc.free(line);
        var parsed = std.json.parseFromSlice(std.json.Value, alloc, line, .{}) catch continue;
        defer parsed.deinit();
        const obj = switch (parsed.value) {
            .object => |o| o,
            else => continue,
        };
        const kind = obj.get("kind") orelse continue;
        if (kind != .string) continue;
        if (!std.mem.eql(u8, kind.string, expected_kind)) continue;
        if (obj.get("bytes_hex")) |hv| {
            if (hv == .string) return try hex.decodeHex(alloc, hv.string);
        }
        return try alloc.dupe(u8, "");
    }
}

test "issue #29: watch pre-creation promotes on spawn (socket level)" {
    const alloc = std.testing.allocator;

    const harness = try startServerHarness(alloc, "watchpend");
    defer {
        harness.deinit(alloc);
        alloc.destroy(harness);
    }

    // No session exists yet. Park a watcher on a future name through the
    // real socket protocol.
    const stream = try openStreamingConn(harness.socket_path, "{\"op\":\"watch\",\"session\":\"ghostname\"}");
    defer stream.close();
    var reader = LineReader.init(alloc, stream);
    defer reader.deinit();

    // First line is the waiting ack.
    const ack = try reader.readLine(2000);
    defer alloc.free(ack);
    {
        var parsed = try std.json.parseFromSlice(std.json.Value, alloc, ack, .{});
        defer parsed.deinit();
        try std.testing.expect(parsed.value == .object);
        const ok = parsed.value.object.get("ok") orelse return error.MissingOk;
        try std.testing.expect(ok == .bool and ok.bool);
        const w = parsed.value.object.get("waiting") orelse return error.MissingWaiting;
        try std.testing.expect(w == .bool and w.bool);
    }

    // Spawn the session with the matching name; the loop promotes the
    // parked conn in the same iteration the spawn dispatches.
    {
        var parsed = try socketRequest(alloc, harness.socket_path, .{
            .op = "spawn",
            .name = "ghostname",
            .program = "/bin/cat",
            .rows = 8,
            .cols = 24,
        });
        defer parsed.deinit();
        _ = try expectTestOk(parsed);
    }

    // Next line must be the "started" frame, followed by the initial
    // snapshot as an `output` frame.
    const started_bytes = try expectFrameKind(alloc, &reader, "started", 5000);
    alloc.free(started_bytes);
    const snap_bytes = try expectFrameKind(alloc, &reader, "output", 5000);
    alloc.free(snap_bytes);

    {
        var kill_parsed = try socketRequest(alloc, harness.socket_path, .{ .op = "kill", .session = "ghostname" });
        defer kill_parsed.deinit();
        _ = try expectTestOk(kill_parsed);
    }
}

/// Background ticker that mimics the real server's accept loop calling
/// `registry.drainAll()` every ~25ms. Tests use this when they need PTY
/// events to flow to attach/watch subscribers without driving RPCs.
const RegistryTicker = struct {
    registry: *SessionRegistry,
    stop: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,

    fn start(self: *RegistryTicker) !void {
        self.thread = try std.Thread.spawn(.{}, RegistryTicker.loop, .{self});
    }

    fn stopAndJoin(self: *RegistryTicker) void {
        self.stop.store(true, .release);
        if (self.thread) |t| t.join();
        self.thread = null;
    }

    fn loop(self: *RegistryTicker) void {
        while (!self.stop.load(.acquire)) {
            self.registry.drainAll();
            std.Thread.sleep(10 * std.time.ns_per_ms);
        }
    }
};

test "issue #29: promoted watcher streams live output (regression: post-promotion read EOF)" {
    const alloc = std.testing.allocator;

    const harness = try startServerHarness(alloc, "watchstream");
    defer {
        harness.deinit(alloc);
        alloc.destroy(harness);
    }

    // Park a watcher on a name that doesn't exist yet, through the real
    // socket protocol.
    const stream = try openStreamingConn(harness.socket_path, "{\"op\":\"watch\",\"session\":\"streamfoo\"}");
    defer stream.close();
    var reader = LineReader.init(alloc, stream);
    defer reader.deinit();

    // Consume the waiting ack.
    const ack = try reader.readLine(2000);
    defer alloc.free(ack);

    // Spawn the session running a shell that prints three lines with a
    // short sleep between each, so each line reaches the PTY as a
    // separate output event.
    {
        var parsed = try socketRequest(alloc, harness.socket_path, .{
            .op = "spawn",
            .name = "streamfoo",
            .program = "/bin/sh",
            .args = [_][]const u8{ "-c", "for i in 1 2 3; do echo L$i; sleep 0.1; done" },
            .rows = 8,
            .cols = 24,
        });
        defer parsed.deinit();
        _ = try expectTestOk(parsed);
    }

    // Expect: `started` frame, then output frames containing L1/L2/L3.
    // The first `output` frame is the initial snapshot (possibly blank);
    // subsequent ones carry live PTY bytes. Rather than assume a precise
    // frame count we drain frames until we've seen all three markers or
    // the timeout expires.
    const started_bytes = try expectFrameKind(alloc, &reader, "started", 5000);
    alloc.free(started_bytes);

    var saw_l1 = false;
    var saw_l2 = false;
    var saw_l3 = false;
    const total_deadline_ns = std.time.nanoTimestamp() + @as(i128, 10_000) * std.time.ns_per_ms;
    while (!(saw_l1 and saw_l2 and saw_l3)) {
        const now_ns = std.time.nanoTimestamp();
        if (now_ns >= total_deadline_ns) break;
        const remaining_ms: u64 = @intCast(@divTrunc(total_deadline_ns - now_ns, std.time.ns_per_ms));
        const bytes = expectFrameKind(alloc, &reader, "output", @max(50, remaining_ms)) catch break;
        defer alloc.free(bytes);
        if (std.mem.indexOf(u8, bytes, "L1") != null) saw_l1 = true;
        if (std.mem.indexOf(u8, bytes, "L2") != null) saw_l2 = true;
        if (std.mem.indexOf(u8, bytes, "L3") != null) saw_l3 = true;
    }

    try std.testing.expect(saw_l1);
    try std.testing.expect(saw_l2);
    try std.testing.expect(saw_l3);

    {
        var kill_parsed = try socketRequest(alloc, harness.socket_path, .{ .op = "kill", .session = "streamfoo" });
        defer kill_parsed.deinit();
        _ = try expectTestOk(kill_parsed);
    }
}

test "issue #29: read-only input frames are dropped by the server" {
    const alloc = std.testing.allocator;
    const log_dir = try setupAttachLogDir(alloc, "watch-readonly-drop");
    defer alloc.free(log_dir);
    defer std.fs.cwd().deleteTree(log_dir) catch {};

    var registry = SessionRegistry.init(alloc);
    defer registry.deinit();
    registry.log_dir = log_dir;

    {
        var parsed = try testRequest(&registry, .{
            .op = "spawn",
            .name = "rotest",
            .program = "/bin/cat",
            .rows = 8,
            .cols = 24,
        });
        defer parsed.deinit();
        _ = try expectTestOk(parsed);
    }

    const sess = try sessionByName(&registry, "rotest");

    // Build a read-only AttachClient directly and dispatch an input
    // frame at it. It must be silently dropped — no error, no log entry.
    var uuid_buf: [36]u8 = undefined;
    uuid_mod_tests.generateUuidV7(&uuid_buf);
    const client_id = try std.fmt.allocPrint(alloc, "attach-{s}", .{uuid_buf[0..]});
    errdefer alloc.free(client_id);

    const pair = try makeSocketPair();
    defer pair.peer.close();

    const client = try alloc.create(AttachClientTest);
    errdefer alloc.destroy(client);
    client.* = .{
        .alloc = alloc,
        .session = sess,
        .stream = pair.local,
        .client_id = client_id,
        .read_only = true,
    };
    try sess.attach_clients.append(alloc, client);
    {
        var arena_state = std.heap.ArenaAllocator.init(alloc);
        defer arena_state.deinit();
        log_mod_tests.logAttachConnectEvent(arena_state.allocator(), sess, client.client_id);
    }

    // Dispatch an input frame — for a read-only client this is a no-op
    // (no error, no PTY send, no log event).
    const frame = "{\"op\":\"input\",\"bytes_hex\":\"7a\"}";
    try server_attach_mod.dispatchAttachFrame(client, frame);

    // A resize frame from a read-only client must likewise be dropped.
    const resize_frame = "{\"op\":\"resize\",\"rows\":99,\"cols\":99}";
    try server_attach_mod.dispatchAttachFrame(client, resize_frame);

    // Tear down client.
    client.shutdown();
    attach_mod.reapClosedAttachClients(sess);

    {
        var kill_parsed = try testRequest(&registry, .{ .op = "kill", .session = "rotest" });
        defer kill_parsed.deinit();
        _ = try expectTestOk(kill_parsed);
    }

    const contents = try readAttachLog(alloc, log_dir, "rotest");
    defer alloc.free(contents);
    const events = try parseLogEvents(alloc, contents);
    defer freeLogEvents(events);

    // No `input` event with origin=attach should be present — the
    // read-only client's input was dropped. Resize events from the
    // client should also be absent.
    for (events) |ev| {
        const kind_v = ev.obj.get("kind") orelse continue;
        if (kind_v != .string) continue;
        const kind = kind_v.string;
        if (std.mem.eql(u8, kind, "input")) {
            if (ev.obj.get("origin")) |o| {
                if (o == .string) {
                    try std.testing.expect(!std.mem.eql(u8, o.string, "attach"));
                }
            }
        }
        if (std.mem.eql(u8, kind, "resize")) {
            // Any resize present in the log must have come from the
            // initial spawn (8x24), not from our bogus 99x99 frame.
            const rows = ev.obj.get("rows") orelse continue;
            if (rows == .integer) try std.testing.expect(rows.integer != 99);
        }
    }
}

// ============================================================================
// Non-blocking attach broadcasts (hardening: stalled readers must not
// wedge drainAll / registry.mutex)
// ============================================================================

test "hardening: tryWriteFrame buffers on a full socket, preserves order, drops on overflow" {
    const alloc = std.testing.allocator;

    const pair = try makeSocketPair();
    defer pair.peer.close();

    // Build a bare AttachClient over the socketpair. tryWriteFrame /
    // flushPending never touch `session`, so `undefined` is safe here and
    // spares the test a full registry+PTY spawn.
    const client_id = try alloc.dupe(u8, "attach-hardening-buffer-test");
    errdefer alloc.free(client_id);
    const client = try alloc.create(AttachClientTest);
    client.* = .{
        .alloc = alloc,
        .session = undefined,
        .stream = pair.local,
        .client_id = client_id,
    };
    // As in production attach setup: the broadcast socket is non-blocking.
    try session_mod_tests.setStreamNonBlocking(pair.local.handle);
    defer client.deinit(); // closes pair.local, frees pending + client_id

    // Phase 1: write 8 KiB frames without the peer reading until the
    // kernel socket buffer fills and bytes start landing in `pending`,
    // then a few more. Every write must report success (client under its
    // buffer bound) and must not block.
    var frame: [8192]u8 = undefined;
    var expected = std.ArrayListUnmanaged(u8){};
    defer expected.deinit(alloc);
    var seq: u8 = 0;
    while (true) {
        @memset(&frame, 'a' + (seq % 26));
        seq +%= 1;
        try std.testing.expect(client.tryWriteFrame(&frame));
        try expected.appendSlice(alloc, &frame);
        // Single-threaded now — the buffer can be inspected directly.
        const pending_len = client.pending.items.len;
        // Stop well under max_pending_bytes so nothing gets dropped.
        if (pending_len >= 64 * 1024) break;
        try std.testing.expect(expected.items.len < AttachClientTest.max_pending_bytes);
    }

    // Phase 2: drain from the peer while ticking flushPending (as drainAll
    // does). Every byte must arrive, in write order.
    var received: usize = 0;
    var chunk: [8192]u8 = undefined;
    var drain_timer = try std.time.Timer.start();
    while (received < expected.items.len) {
        try std.testing.expect(drain_timer.read() < 10 * std.time.ns_per_s);
        client.flushPending();
        const n = std.posix.recv(pair.peer.handle, &chunk, std.posix.MSG.DONTWAIT) catch |err| switch (err) {
            error.WouldBlock => {
                std.Thread.sleep(1 * std.time.ns_per_ms);
                continue;
            },
            else => return err,
        };
        if (n == 0) break;
        try std.testing.expectEqualSlices(u8, expected.items[received..][0..n], chunk[0..n]);
        received += n;
    }
    try std.testing.expectEqual(expected.items.len, received);
    try std.testing.expect(!client.isClosed());

    // Phase 3: stop reading entirely and flood. Once the socket buffer
    // plus max_pending_bytes are exhausted, tryWriteFrame must give up
    // (returning false) and mark the client closed — never block.
    var dropped = false;
    var i: usize = 0;
    // 8 KiB per frame; the 1 MiB cap plus kernel buffer is < 1024 frames.
    while (i < 1024) : (i += 1) {
        if (!client.tryWriteFrame(&frame)) {
            dropped = true;
            break;
        }
    }
    try std.testing.expect(dropped);
    try std.testing.expect(client.isClosed());
}

test "hardening: stalled attach reader does not block drainAll; concurrent list completes and client is reaped" {
    const alloc = std.testing.allocator;
    const log_dir = try setupAttachLogDir(alloc, "stalled-reader");
    defer alloc.free(log_dir);
    defer std.fs.cwd().deleteTree(log_dir) catch {};

    var registry = SessionRegistry.init(alloc);
    defer registry.deinit();
    registry.log_dir = log_dir;

    // Spawn a session that bursts ~700 KB of output. Hex framing doubles
    // that on the attach wire, so the stalled client below must blow
    // through the kernel socket buffer plus the 1 MiB pending cap.
    {
        var parsed = try testRequest(&registry, .{
            .op = "spawn",
            .name = "stalled",
            .program = "/bin/sh",
            .args = [_][]const u8{ "-c", "head -c 700000 /dev/zero | tr '\\0' x; sleep 30" },
            .rows = 24,
            .cols = 200,
        });
        defer parsed.deinit();
        _ = try expectTestOk(parsed);
    }

    // Attach a client whose peer end never reads a single byte —
    // the pathological Ctrl-Z'd `hty watch`.
    const pair = try makeSocketPair();
    defer pair.peer.close();
    const sess = try sessionByName(&registry, "stalled");
    _ = try registerAttachClient(alloc, sess, pair.local);

    // Tick drainAll on a background thread like the real accept loop.
    // Before this hardening, the first broadcast that filled the stalled
    // socket blocked inside writeAll while holding registry.mutex, so the
    // ticker wedged and every RPC below hung forever.
    var ticker = RegistryTicker{ .registry = &registry };
    try ticker.start();
    defer ticker.stopAndJoin();

    // While the burst floods the broadcast path, `list` RPCs (which
    // contend on registry.mutex with drainAll) must keep completing, and
    // the overflowed client must get dropped + reaped. No per-call
    // stopwatch inside the flood: a drain tick honestly ingesting the
    // burst may hold registry.mutex for a while in Debug builds. The
    // pre-fix failure mode — drainAll blocked forever inside writeAll on
    // the stalled socket — makes the first `list` below never return
    // (and `reaped` can never flip), so this loop still catches it.
    var reaped = false;
    var overall_timer = try std.time.Timer.start();
    while (overall_timer.read() < 60 * std.time.ns_per_s) {
        {
            var parsed = try testRequest(&registry, .{ .op = "list" });
            defer parsed.deinit();
            _ = try expectTestOk(parsed);
        }
        // The ticker's drainAll mutates the attach list under
        // registry.mutex; fence this read the same way (attach_mutex is
        // gone — the list is loop-thread-only in production).
        registry.mutex.lock();
        const remaining = sess.attach_clients.items.len;
        registry.mutex.unlock();
        if (remaining == 0) {
            reaped = true;
            break;
        }
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }
    try std.testing.expect(reaped);

    // Once the session goes quiet (burst fully ingested), drain ticks are
    // cheap again and a concurrent `list` must meet its usual budget.
    {
        var idle = try testRequest(&registry, .{
            .op = "wait_for_idle",
            .session = "stalled",
            .idle_ms = 300,
            .timeout_ms = 60_000,
        });
        defer idle.deinit();
        _ = try expectTestOk(idle);
    }
    var list_timer = try std.time.Timer.start();
    {
        var parsed = try testRequest(&registry, .{ .op = "list" });
        defer parsed.deinit();
        _ = try expectTestOk(parsed);
    }
    try std.testing.expect(list_timer.read() < 2 * std.time.ns_per_s);

    // The dropped client must have gotten an attach_disconnect event.
    // (readAttachLog caps at 1 MiB; this log carries the whole burst as
    // hex output events, so read it with a larger cap.)
    {
        const link_path = try std.fmt.allocPrint(alloc, "{s}/by-name/stalled.jsonl", .{log_dir});
        defer alloc.free(link_path);
        const file = try std.fs.openFileAbsolute(link_path, .{});
        defer file.close();
        const contents = try file.readToEndAlloc(alloc, 64 * 1024 * 1024);
        defer alloc.free(contents);
        try std.testing.expect(std.mem.indexOf(u8, contents, "\"kind\":\"attach_disconnect\"") != null);
    }

    {
        var kill_parsed = try testRequest(&registry, .{ .op = "kill", .session = "stalled" });
        defer kill_parsed.deinit();
        _ = try expectTestOk(kill_parsed);
    }
}

test "event loop: stalled watch socket is dropped via the conn outbound buffer; list keeps answering" {
    const alloc = std.testing.allocator;

    const harness = try startServerHarness(alloc, "connstall");
    defer {
        harness.deinit(alloc);
        alloc.destroy(harness);
    }

    // Spawn a session that bursts ~700 KB of output. Hex framing doubles
    // that on the attach wire, so the stalled watcher below must blow
    // through the kernel socket buffer plus the 1 MiB pending cap.
    {
        var parsed = try socketRequest(alloc, harness.socket_path, .{
            .op = "spawn",
            .name = "connstall",
            .program = "/bin/sh",
            .args = [_][]const u8{ "-c", "sleep 0.3; head -c 700000 /dev/zero | tr '\\0' x; sleep 30" },
            .rows = 24,
            .cols = 200,
        });
        defer parsed.deinit();
        _ = try expectTestOk(parsed);
    }

    // Watch through the real socket protocol and then never read another
    // byte — the pathological Ctrl-Z'd `hty watch`.
    const stream = try openStreamingConn(harness.socket_path, "{\"op\":\"watch\",\"session\":\"connstall\"}");
    defer stream.close();
    {
        var reader = LineReader.init(alloc, stream);
        defer reader.deinit();
        const ack = try reader.readLine(2000);
        alloc.free(ack);
    }

    // While the burst floods the broadcast path, `list` RPCs must keep
    // completing, and the overflowed watcher must get dropped with an
    // `attach_disconnect` in the session log (the loop's reap path).
    var dropped = false;
    var overall_timer = try std.time.Timer.start();
    const link_path = try std.fmt.allocPrint(alloc, "{s}/by-name/connstall.jsonl", .{harness.log_dir});
    defer alloc.free(link_path);
    while (overall_timer.read() < 60 * std.time.ns_per_s) {
        {
            var parsed = try socketRequest(alloc, harness.socket_path, .{ .op = "list" });
            defer parsed.deinit();
            _ = try expectTestOk(parsed);
        }
        const file = std.fs.openFileAbsolute(link_path, .{}) catch {
            std.Thread.sleep(20 * std.time.ns_per_ms);
            continue;
        };
        defer file.close();
        const contents = file.readToEndAlloc(alloc, 64 * 1024 * 1024) catch {
            std.Thread.sleep(20 * std.time.ns_per_ms);
            continue;
        };
        defer alloc.free(contents);
        if (std.mem.indexOf(u8, contents, "\"kind\":\"attach_disconnect\"") != null) {
            dropped = true;
            break;
        }
        std.Thread.sleep(20 * std.time.ns_per_ms);
    }
    try std.testing.expect(dropped);

    // Once the burst is fully ingested a `list` must meet its usual
    // budget again.
    {
        var idle = try socketRequest(alloc, harness.socket_path, .{
            .op = "wait_for_idle",
            .session = "connstall",
            .idle_ms = 300,
            .timeout_ms = 60_000,
        });
        defer idle.deinit();
        _ = try expectTestOk(idle);
    }
    var list_timer = try std.time.Timer.start();
    {
        var parsed = try socketRequest(alloc, harness.socket_path, .{ .op = "list" });
        defer parsed.deinit();
        _ = try expectTestOk(parsed);
    }
    try std.testing.expect(list_timer.read() < 2 * std.time.ns_per_s);

    {
        var kill_parsed = try socketRequest(alloc, harness.socket_path, .{ .op = "kill", .session = "connstall" });
        defer kill_parsed.deinit();
        _ = try expectTestOk(kill_parsed);
    }
}

/// Send one attach `input` frame carrying `text` on an attach socket.
fn sendInputFrame(alloc: std.mem.Allocator, stream: std.net.Stream, text: []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const hex_str = try hex.encodeHex(arena, text);
    const frame = try std.fmt.allocPrint(arena, "{{\"op\":\"input\",\"bytes_hex\":\"{s}\"}}\n", .{hex_str});
    try stream.writeAll(frame);
}

/// Assert a socket-level wait_for_text found its needle (ok and not
/// timed out) — i.e. the text appears contiguously on the screen.
fn expectTextFound(alloc: std.mem.Allocator, socket_path: []const u8, session: []const u8, text: []const u8) !void {
    var parsed = try socketRequest(alloc, socket_path, .{
        .op = "wait_for_text",
        .session = session,
        .text = text,
        .timeout_ms = 10_000,
    });
    defer parsed.deinit();
    const object = try expectTestOk(parsed);
    if (object.get("timed_out")) |to| {
        try std.testing.expect(to == .bool and !to.bool);
    }
}

test "event loop: attach input fan-in interleaves at frame granularity" {
    const alloc = std.testing.allocator;

    const harness = try startServerHarness(alloc, "fanin");
    defer {
        harness.deinit(alloc);
        alloc.destroy(harness);
    }

    // `cat` with tty echo: every input byte is echoed to the screen in
    // the exact order it reached the PTY, so contiguity of each token in
    // the plain-text snapshot proves whole-frame interleaving.
    {
        var parsed = try socketRequest(alloc, harness.socket_path, .{
            .op = "spawn",
            .name = "fanin",
            .program = "/bin/cat",
            .rows = 10,
            .cols = 120,
        });
        defer parsed.deinit();
        _ = try expectTestOk(parsed);
    }

    // Two interactive attach clients over the real socket protocol.
    const a1 = try openStreamingConn(harness.socket_path, "{\"op\":\"attach\",\"session\":\"fanin\"}");
    defer a1.close();
    const a2 = try openStreamingConn(harness.socket_path, "{\"op\":\"attach\",\"session\":\"fanin\"}");
    defer a2.close();
    {
        var r1 = LineReader.init(alloc, a1);
        defer r1.deinit();
        const ack1 = try r1.readLine(2000);
        alloc.free(ack1);
        var r2 = LineReader.init(alloc, a2);
        defer r2.deinit();
        const ack2 = try r2.readLine(2000);
        alloc.free(ack2);
    }

    // Interleave frames from three sources in quick succession. Each
    // token is 12 bytes; if any two frames interleaved mid-frame, at
    // least one token would be broken on screen and its wait below would
    // time out. Total 72 chars < 120 cols, so nothing wraps.
    try sendInputFrame(alloc, a1, "A1A1A1A1A1A1");
    {
        var parsed = try socketRequest(alloc, harness.socket_path, .{
            .op = "send_text",
            .session = "fanin",
            .text = "R1R1R1R1R1R1",
        });
        defer parsed.deinit();
        _ = try expectTestOk(parsed);
    }
    try sendInputFrame(alloc, a2, "B1B1B1B1B1B1");
    try sendInputFrame(alloc, a1, "A2A2A2A2A2A2");
    try sendInputFrame(alloc, a2, "B2B2B2B2B2B2");
    {
        var parsed = try socketRequest(alloc, harness.socket_path, .{
            .op = "send_text",
            .session = "fanin",
            .text = "R2R2R2R2R2R2",
        });
        defer parsed.deinit();
        _ = try expectTestOk(parsed);
    }

    // All bytes arrive, none interleaved mid-frame: every token is found
    // contiguously in the echoed screen text.
    try expectTextFound(alloc, harness.socket_path, "fanin", "A1A1A1A1A1A1");
    try expectTextFound(alloc, harness.socket_path, "fanin", "R1R1R1R1R1R1");
    try expectTextFound(alloc, harness.socket_path, "fanin", "B1B1B1B1B1B1");
    try expectTextFound(alloc, harness.socket_path, "fanin", "A2A2A2A2A2A2");
    try expectTextFound(alloc, harness.socket_path, "fanin", "B2B2B2B2B2B2");
    try expectTextFound(alloc, harness.socket_path, "fanin", "R2R2R2R2R2R2");

    {
        var kill_parsed = try socketRequest(alloc, harness.socket_path, .{ .op = "kill", .session = "fanin" });
        defer kill_parsed.deinit();
        _ = try expectTestOk(kill_parsed);
    }
}

test "event loop: pending-input overflow drops without stalling the server" {
    const alloc = std.testing.allocator;

    const harness = try startServerHarness(alloc, "wedged");
    defer {
        harness.deinit(alloc);
        alloc.destroy(harness);
    }

    // A wedged child: the shell stops itself before exec'ing cat, so
    // nothing ever reads the tty. The kernel input queue fills, master-fd
    // writes surface WouldBlock, and the session's 64 KiB pending-input
    // buffer must absorb then *drop* the flood — never stall the loop.
    {
        var parsed = try socketRequest(alloc, harness.socket_path, .{
            .op = "spawn",
            .name = "wedged",
            .program = "/bin/sh",
            .args = [_][]const u8{ "-c", "kill -STOP $$; exec cat" },
            .rows = 24,
            .cols = 80,
        });
        defer parsed.deinit();
        _ = try expectTestOk(parsed);
    }

    // Flood 320 KiB (40 x 8 KiB frames) — 5x past the 64 KiB bound plus
    // any kernel tty buffer. Every send must return promptly with ok
    // (drops are silent by policy); a stalled server would hang the
    // first blocked request forever.
    var payload: [8192]u8 = undefined;
    @memset(&payload, 'x');
    var payload_hex: [16384]u8 = undefined;
    const hex_chars = "0123456789abcdef";
    for (payload, 0..) |b, i| {
        payload_hex[i * 2] = hex_chars[b >> 4];
        payload_hex[i * 2 + 1] = hex_chars[b & 0xf];
    }
    var flood_timer = try std.time.Timer.start();
    var i: usize = 0;
    while (i < 40) : (i += 1) {
        var parsed = try socketRequest(alloc, harness.socket_path, .{
            .op = "send_bytes_hex",
            .session = "wedged",
            .bytes_hex = @as([]const u8, &payload_hex),
        });
        defer parsed.deinit();
        _ = try expectTestOk(parsed);
    }
    try std.testing.expect(flood_timer.read() < 60 * std.time.ns_per_s);

    // The server is still fully responsive: `list` answers within its
    // usual budget.
    var list_timer = try std.time.Timer.start();
    {
        var parsed = try socketRequest(alloc, harness.socket_path, .{ .op = "list" });
        defer parsed.deinit();
        _ = try expectTestOk(parsed);
    }
    try std.testing.expect(list_timer.read() < 2 * std.time.ns_per_s);

    {
        var kill_parsed = try socketRequest(alloc, harness.socket_path, .{ .op = "kill", .session = "wedged" });
        defer kill_parsed.deinit();
        _ = try expectTestOk(kill_parsed);
    }
}

// ============================================================================
// Mouse input (issue #24)
// ============================================================================

/// Fixture app: emits `CSI ?... h` mouse-enable sequences, then appends
/// every byte it reads from stdin to $HTY_MOUSE_RECORD until EOT (0x04).
/// The test drives `hty send --click/--drag/--scroll` and reads the
/// record file to assert the wire bytes.
fn spawnMouseFixture(
    registry: *SessionRegistry,
    name: []const u8,
    modes: []const []const u8,
    record_path: []const u8,
) !void {
    const alloc = std.testing.allocator;
    const py = findCommand(alloc, "python3") orelse return error.SkipZigTest;
    defer alloc.free(py);

    // Build args: scripts/fixtures/mouse-echo.py <modes...>
    var args_list = std.ArrayListUnmanaged([]const u8){};
    defer args_list.deinit(alloc);
    try args_list.append(alloc, "scripts/fixtures/mouse-echo.py");
    for (modes) |m| try args_list.append(alloc, m);

    var env_list = std.ArrayListUnmanaged(struct { key: []const u8, value: []const u8 }){};
    defer env_list.deinit(alloc);
    try env_list.append(alloc, .{ .key = "HTY_MOUSE_RECORD", .value = record_path });

    var parsed = try testRequest(registry, .{
        .op = "spawn",
        .name = name,
        .program = py,
        .args = args_list.items,
        .env = env_list.items,
        .rows = 24,
        .cols = 80,
    });
    defer parsed.deinit();
    _ = try expectTestOk(parsed);

    // Wait for the fixture to print its enable sequence and "READY\n".
    var ready = try testRequest(registry, .{
        .op = "wait_for_text",
        .session = name,
        .text = "READY",
        .timeout_ms = 5_000,
    });
    defer ready.deinit();
    _ = try expectTestOk(ready);

    // One more idle pass so the raw_bytes for the enable sequence are
    // fully drained and the session's mouse_state is up to date.
    var idle = try testRequest(registry, .{
        .op = "wait_for_idle",
        .session = name,
        .idle_ms = 100,
        .timeout_ms = 2_000,
    });
    defer idle.deinit();
    _ = try expectTestOk(idle);
}

fn killMouseFixture(registry: *SessionRegistry, name: []const u8) !void {
    // Send EOT so the fixture exits cleanly; then kill to be safe.
    {
        var p = try testRequest(registry, .{
            .op = "send_bytes_hex",
            .session = name,
            .bytes_hex = "04",
        });
        defer p.deinit();
        _ = try expectTestOk(p);
    }
    var k = try testRequest(registry, .{ .op = "kill", .session = name });
    defer k.deinit();
    _ = try expectTestOk(k);
}

test "mouse: snapshot exposes mouse state after app enables 1002+1006" {
    const alloc = std.testing.allocator;
    var registry = SessionRegistry.init(alloc);
    defer registry.deinit();

    const rec = try std.fmt.allocPrint(alloc, "/tmp/hty-mouse-rec-{d}.bin", .{std.time.nanoTimestamp()});
    defer alloc.free(rec);
    std.fs.deleteFileAbsolute(rec) catch {};
    defer std.fs.deleteFileAbsolute(rec) catch {};

    spawnMouseFixture(&registry, "mouse_snap", &.{ "1002", "1006" }, rec) catch |err| {
        if (err == error.SkipZigTest) return err;
        return err;
    };
    defer killMouseFixture(&registry, "mouse_snap") catch {};

    var snap = try testRequest(&registry, .{ .op = "snapshot", .session = "mouse_snap" });
    defer snap.deinit();
    const obj = try expectTestOk(snap);

    const snap_val = obj.get("snapshot") orelse return error.InvalidResponse;
    try std.testing.expect(snap_val == .object);
    const mouse_val = snap_val.object.get("mouse") orelse return error.InvalidResponse;
    try std.testing.expect(mouse_val == .object);
    const m = mouse_val.object;
    try std.testing.expect(m.get("enabled").?.bool);
    try std.testing.expect(m.get("button_event").?.bool);
    try std.testing.expect(m.get("sgr").?.bool);
    try std.testing.expect(!m.get("x10").?.bool);
    try std.testing.expect(!m.get("any_event").?.bool);
}

test "mouse: send_mouse refuses when mouse is disabled" {
    const alloc = std.testing.allocator;
    var registry = SessionRegistry.init(alloc);
    defer registry.deinit();

    const uuid = try spawnCatSession(&registry, "no_mouse");
    defer alloc.free(uuid);
    defer {
        if (testRequest(&registry, .{ .op = "kill", .session = "no_mouse" })) |kk| {
            var k_mut = kk;
            k_mut.deinit();
        } else |_| {}
    }

    var parsed = try testRequest(&registry, .{
        .op = "send_mouse",
        .session = "no_mouse",
        .event = "press",
        .button = "left",
        .row = 5,
        .col = 10,
    });
    defer parsed.deinit();

    const resp = switch (parsed.value) {
        .object => |o| o,
        else => return error.InvalidResponse,
    };
    try std.testing.expectEqual(false, resp.get("ok").?.bool);
    const err_val = resp.get("error") orelse return error.InvalidResponse;
    try std.testing.expect(err_val == .string);
    try std.testing.expect(std.mem.indexOf(u8, err_val.string, "mouse") != null);
}

test "mouse: click emits SGR press+release when 1006 is enabled" {
    const alloc = std.testing.allocator;
    var registry = SessionRegistry.init(alloc);
    defer registry.deinit();

    const rec = try std.fmt.allocPrint(alloc, "/tmp/hty-mouse-rec-{d}.bin", .{std.time.nanoTimestamp()});
    defer alloc.free(rec);
    std.fs.deleteFileAbsolute(rec) catch {};
    defer std.fs.deleteFileAbsolute(rec) catch {};

    spawnMouseFixture(&registry, "mouse_click", &.{ "1002", "1006" }, rec) catch |err| {
        if (err == error.SkipZigTest) return err;
        return err;
    };
    defer killMouseFixture(&registry, "mouse_click") catch {};

    // --click 5 10 => press at (5,10), release at (5,10).
    {
        var p = try testRequest(&registry, .{
            .op = "send_mouse",
            .session = "mouse_click",
            .event = "press",
            .button = "left",
            .row = 5,
            .col = 10,
        });
        defer p.deinit();
        _ = try expectTestOk(p);
    }
    {
        var p = try testRequest(&registry, .{
            .op = "send_mouse",
            .session = "mouse_click",
            .event = "release",
            .button = "left",
            .row = 5,
            .col = 10,
        });
        defer p.deinit();
        _ = try expectTestOk(p);
    }

    // Give the fixture a moment to flush the bytes to the record file.
    var idle = try testRequest(&registry, .{
        .op = "wait_for_idle",
        .session = "mouse_click",
        .idle_ms = 100,
        .timeout_ms = 2_000,
    });
    defer idle.deinit();
    _ = try expectTestOk(idle);

    const file = std.fs.openFileAbsolute(rec, .{}) catch |err| {
        std.debug.print("record file missing: {s}\n", .{@errorName(err)});
        return err;
    };
    defer file.close();
    const contents = try file.readToEndAlloc(alloc, 4096);
    defer alloc.free(contents);

    // Expected SGR wire: ESC [ < 0 ; 10 ; 5 M (press) then ESC [ < 0 ; 10 ; 5 m (release).
    try std.testing.expect(std.mem.indexOf(u8, contents, "\x1b[<0;10;5M") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "\x1b[<0;10;5m") != null);
}

test "mouse: X10 coords out of range errors when SGR not negotiated" {
    const alloc = std.testing.allocator;
    var registry = SessionRegistry.init(alloc);
    defer registry.deinit();

    const rec = try std.fmt.allocPrint(alloc, "/tmp/hty-mouse-rec-{d}.bin", .{std.time.nanoTimestamp()});
    defer alloc.free(rec);
    std.fs.deleteFileAbsolute(rec) catch {};
    defer std.fs.deleteFileAbsolute(rec) catch {};

    // Only ?1000 (X10-only), no ?1006 — SGR must not be used.
    spawnMouseFixture(&registry, "mouse_oor", &.{"1000"}, rec) catch |err| {
        if (err == error.SkipZigTest) return err;
        return err;
    };
    defer killMouseFixture(&registry, "mouse_oor") catch {};

    var p = try testRequest(&registry, .{
        .op = "send_mouse",
        .session = "mouse_oor",
        .event = "press",
        .button = "left",
        .row = 1,
        .col = 224,
    });
    defer p.deinit();

    const object = switch (p.value) {
        .object => |o| o,
        else => return error.InvalidResponse,
    };
    const ok = object.get("ok") orelse return error.InvalidResponse;
    try std.testing.expectEqual(false, ok.bool);
    const err_val = object.get("error") orelse return error.InvalidResponse;
    try std.testing.expect(err_val == .string);
    try std.testing.expect(std.mem.indexOf(u8, err_val.string, "exceed X10 range") != null);
    try std.testing.expect(std.mem.indexOf(u8, err_val.string, "?1006") != null);
}

test "mouse: X10 encoding when only 1000 is on (no SGR)" {
    const alloc = std.testing.allocator;
    var registry = SessionRegistry.init(alloc);
    defer registry.deinit();

    const rec = try std.fmt.allocPrint(alloc, "/tmp/hty-mouse-rec-{d}.bin", .{std.time.nanoTimestamp()});
    defer alloc.free(rec);
    std.fs.deleteFileAbsolute(rec) catch {};
    defer std.fs.deleteFileAbsolute(rec) catch {};

    spawnMouseFixture(&registry, "mouse_x10", &.{"1000"}, rec) catch |err| {
        if (err == error.SkipZigTest) return err;
        return err;
    };
    defer killMouseFixture(&registry, "mouse_x10") catch {};

    {
        var p = try testRequest(&registry, .{
            .op = "send_mouse",
            .session = "mouse_x10",
            .event = "press",
            .button = "left",
            .row = 2,
            .col = 3,
        });
        defer p.deinit();
        _ = try expectTestOk(p);
    }

    var idle = try testRequest(&registry, .{
        .op = "wait_for_idle",
        .session = "mouse_x10",
        .idle_ms = 100,
        .timeout_ms = 2_000,
    });
    defer idle.deinit();
    _ = try expectTestOk(idle);

    const file = try std.fs.openFileAbsolute(rec, .{});
    defer file.close();
    const contents = try file.readToEndAlloc(alloc, 4096);
    defer alloc.free(contents);

    // X10 press: ESC [ M <0+32=' '> <col+32=35='#'> <row+32=34='"'>.
    const expected = [_]u8{ 0x1b, '[', 'M', 32, 35, 34 };
    try std.testing.expect(std.mem.indexOf(u8, contents, &expected) != null);
}

// ============================================================================
// `hty run --remove` — auto-delete session from registry once the child exits.
// ============================================================================

/// Drive the registry's drain loop until `predicate` returns true or the
/// deadline passes. Mirrors what the server's accept loop does every 25ms
/// in production — tests exercise the same sweep without spinning up the
/// real socket server.
fn waitForDrainCondition(
    registry: *SessionRegistry,
    deadline_ms: i64,
    ctx: anytype,
    predicate: *const fn (@TypeOf(ctx)) bool,
) bool {
    const start = std.time.milliTimestamp();
    while (std.time.milliTimestamp() - start < deadline_ms) {
        registry.drainAll();
        if (predicate(ctx)) return true;
        std.Thread.sleep(20 * std.time.ns_per_ms);
    }
    return false;
}

fn sessionCount(registry: *SessionRegistry) usize {
    registry.mutex.lock();
    defer registry.mutex.unlock();
    return registry.by_id.count();
}

test "run --remove: session is auto-removed after child exits" {
    const alloc = std.testing.allocator;
    const true_path = findCommand(alloc, "true") orelse return error.SkipZigTest;
    defer alloc.free(true_path);

    var log_dir_buf: [256]u8 = undefined;
    const log_dir = try std.fmt.bufPrint(
        &log_dir_buf,
        "/tmp/hty-remove-test-{d}",
        .{std.time.nanoTimestamp()},
    );
    try std.fs.cwd().makePath(log_dir);
    defer std.fs.cwd().deleteTree(log_dir) catch {};
    const by_name = try std.fmt.allocPrint(alloc, "{s}/by-name", .{log_dir});
    defer alloc.free(by_name);
    try std.fs.cwd().makePath(by_name);

    var registry = SessionRegistry.init(alloc);
    defer registry.deinit();
    registry.log_dir = log_dir;

    {
        var parsed = try testRequest(&registry, .{
            .op = "spawn",
            .program = true_path,
            .name = "auto-remove-true",
            .rows = 8,
            .cols = 24,
            .remove = true,
        });
        defer parsed.deinit();
        _ = try expectTestOk(parsed);
    }

    // Child exits almost immediately; the drain sweep reaps it as soon as
    // the exit is observed. Give ample headroom for CI.
    const Ctx = struct { r: *SessionRegistry };
    const ctx = Ctx{ .r = &registry };
    const Pred = struct {
        fn f(c: Ctx) bool {
            return sessionCount(c.r) == 0;
        }
    };
    const removed = waitForDrainCondition(&registry, 3000, ctx, Pred.f);
    try std.testing.expect(removed);
}

test "run --remove: session persists while child is alive" {
    const alloc = std.testing.allocator;

    var log_dir_buf: [256]u8 = undefined;
    const log_dir = try std.fmt.bufPrint(
        &log_dir_buf,
        "/tmp/hty-remove-live-test-{d}",
        .{std.time.nanoTimestamp()},
    );
    try std.fs.cwd().makePath(log_dir);
    defer std.fs.cwd().deleteTree(log_dir) catch {};
    const by_name = try std.fmt.allocPrint(alloc, "{s}/by-name", .{log_dir});
    defer alloc.free(by_name);
    try std.fs.cwd().makePath(by_name);

    var registry = SessionRegistry.init(alloc);
    defer registry.deinit();
    registry.log_dir = log_dir;

    // Spawn /bin/cat with --remove; cat sits waiting on stdin so the
    // session must still be listed until we kill it.
    {
        var parsed = try testRequest(&registry, .{
            .op = "spawn",
            .program = "/bin/cat",
            .name = "auto-remove-cat",
            .rows = 8,
            .cols = 24,
            .emit_raw_bytes = false,
            .remove = true,
        });
        defer parsed.deinit();
        _ = try expectTestOk(parsed);
    }

    // Drain a few ticks to let the auto-remove sweep run; session should
    // stay because cat is still running.
    registry.drainAll();
    std.Thread.sleep(150 * std.time.ns_per_ms);
    registry.drainAll();
    try std.testing.expectEqual(@as(usize, 1), sessionCount(&registry));

    // Kill the session — handleKill marks it .killed + stamps terminal_at.
    {
        var parsed = try testRequest(&registry, .{ .op = "kill", .session = "auto-remove-cat" });
        defer parsed.deinit();
        _ = try expectTestOk(parsed);
    }

    // After kill, the sweep must remove the session.
    const Ctx = struct { r: *SessionRegistry };
    const ctx = Ctx{ .r = &registry };
    const Pred = struct {
        fn f(c: Ctx) bool {
            return sessionCount(c.r) == 0;
        }
    };
    const removed = waitForDrainCondition(&registry, 3000, ctx, Pred.f);
    try std.testing.expect(removed);
}

test "run --remove: manual hty kill races cleanly with auto-remove (no crash)" {
    const alloc = std.testing.allocator;

    var log_dir_buf: [256]u8 = undefined;
    const log_dir = try std.fmt.bufPrint(
        &log_dir_buf,
        "/tmp/hty-remove-race-test-{d}",
        .{std.time.nanoTimestamp()},
    );
    try std.fs.cwd().makePath(log_dir);
    defer std.fs.cwd().deleteTree(log_dir) catch {};
    const by_name = try std.fmt.allocPrint(alloc, "{s}/by-name", .{log_dir});
    defer alloc.free(by_name);
    try std.fs.cwd().makePath(by_name);

    var registry = SessionRegistry.init(alloc);
    defer registry.deinit();
    registry.log_dir = log_dir;

    {
        var parsed = try testRequest(&registry, .{
            .op = "spawn",
            .program = "/bin/cat",
            .name = "race",
            .rows = 8,
            .cols = 24,
            .emit_raw_bytes = false,
            .remove = true,
        });
        defer parsed.deinit();
        _ = try expectTestOk(parsed);
    }

    // Issue kill immediately — then a second kill while the auto-remove
    // sweep is also eligible to fire. Both should succeed (kill is
    // idempotent) and the session eventually vanishes exactly once.
    {
        var parsed = try testRequest(&registry, .{ .op = "kill", .session = "race" });
        defer parsed.deinit();
        _ = try expectTestOk(parsed);
    }
    {
        var parsed = try testRequest(&registry, .{ .op = "kill", .session = "race" });
        defer parsed.deinit();
        // Second kill on the same now-killed session is still ok — the
        // handler short-circuits when status != .running.
        _ = try expectTestOk(parsed);
    }

    const Ctx = struct { r: *SessionRegistry };
    const ctx = Ctx{ .r = &registry };
    const Pred = struct {
        fn f(c: Ctx) bool {
            return sessionCount(c.r) == 0;
        }
    };
    const removed = waitForDrainCondition(&registry, 3000, ctx, Pred.f);
    try std.testing.expect(removed);
}

test "spawn without --remove keeps the session after exit" {
    const alloc = std.testing.allocator;
    const true_path = findCommand(alloc, "true") orelse return error.SkipZigTest;
    defer alloc.free(true_path);

    var log_dir_buf: [256]u8 = undefined;
    const log_dir = try std.fmt.bufPrint(
        &log_dir_buf,
        "/tmp/hty-noremove-test-{d}",
        .{std.time.nanoTimestamp()},
    );
    try std.fs.cwd().makePath(log_dir);
    defer std.fs.cwd().deleteTree(log_dir) catch {};
    const by_name = try std.fmt.allocPrint(alloc, "{s}/by-name", .{log_dir});
    defer alloc.free(by_name);
    try std.fs.cwd().makePath(by_name);

    var registry = SessionRegistry.init(alloc);
    defer registry.deinit();
    registry.log_dir = log_dir;

    {
        var parsed = try testRequest(&registry, .{
            .op = "spawn",
            .program = true_path,
            .name = "no-remove",
            .rows = 8,
            .cols = 24,
        });
        defer parsed.deinit();
        _ = try expectTestOk(parsed);
    }

    // Drain through several ticks to prove the zombie lingers because
    // `--remove` was *not* set.
    var i: usize = 0;
    while (i < 15) : (i += 1) {
        registry.drainAll();
        std.Thread.sleep(20 * std.time.ns_per_ms);
    }
    try std.testing.expectEqual(@as(usize, 1), sessionCount(&registry));
}

// ============================================================================
// Unit 6: session lifetime by ownership (refcount), not timing.
// ============================================================================

test "delete during wait_for_text: wait returns structured error, no UAF" {
    const alloc = std.testing.allocator;

    const harness = try startServerHarness(alloc, "delwait");
    defer {
        harness.deinit(alloc);
        alloc.destroy(harness);
    }

    {
        var parsed = try socketRequest(alloc, harness.socket_path, .{
            .op = "spawn",
            .program = "/bin/cat",
            .name = "del-mid-wait",
            .rows = 8,
            .cols = 24,
        });
        defer parsed.deinit();
        _ = try expectTestOk(parsed);
    }

    // Park a wait through the real socket protocol: the loop borrows the
    // session at resolve time and holds the waiter for up to 5s.
    const WaiterCtx = struct {
        alloc: std.mem.Allocator,
        socket_path: []const u8,
        not_found: std.atomic.Value(bool) = .init(false),
        timed_out: std.atomic.Value(bool) = .init(false),

        fn run(self: *@This()) void {
            var parsed = socketRequest(self.alloc, self.socket_path, .{
                .op = "wait_for_text",
                .session = "del-mid-wait",
                .text = "never-appears",
                .timeout_ms = 5000,
            }) catch return;
            defer parsed.deinit();
            const object = switch (parsed.value) {
                .object => |o| o,
                else => return,
            };
            if (object.get("error")) |err_val| {
                if (err_val == .string and std.mem.indexOf(u8, err_val.string, "session not found") != null) {
                    self.not_found.store(true, .release);
                }
            }
            if (object.get("timed_out")) |to_val| {
                if (to_val == .bool and to_val.bool) self.timed_out.store(true, .release);
            }
        }
    };
    var ctx = WaiterCtx{ .alloc = alloc, .socket_path = harness.socket_path };
    const waiter_thread = try std.Thread.spawn(.{}, WaiterCtx.run, .{&ctx});

    // Give the wait time to park, then delete the session out from under
    // it. The loop resolves the parked waiter with the structured error
    // in the same iteration the delete dispatches.
    std.Thread.sleep(150 * std.time.ns_per_ms);
    {
        var parsed = try socketRequest(alloc, harness.socket_path, .{ .op = "delete", .session = "del-mid-wait" });
        defer parsed.deinit();
        _ = try expectTestOk(parsed);
    }

    waiter_thread.join();

    // The wait must complete with a structured result: the "session not
    // found" error from the doomed check (normal case), or — under
    // extreme scheduling — its own timeout. Never a crash or a hang.
    try std.testing.expect(ctx.not_found.load(.acquire) or ctx.timed_out.load(.acquire));

    // And the session really is gone.
    {
        var parsed = try socketRequest(alloc, harness.socket_path, .{ .op = "list" });
        defer parsed.deinit();
        const object = try expectTestOk(parsed);
        const sessions = object.get("sessions") orelse return error.InvalidResponse;
        try std.testing.expectEqual(@as(usize, 0), sessions.array.items.len);
    }
}

test "handler error mid-op releases the session borrow" {
    const alloc = std.testing.allocator;
    var registry = SessionRegistry.init(alloc);
    defer registry.deinit();

    {
        var parsed = try testRequest(&registry, .{
            .op = "spawn",
            .program = "/bin/cat",
            .name = "err-mid-handler",
            .rows = 8,
            .cols = 24,
            .emit_raw_bytes = false,
        });
        defer parsed.deinit();
        _ = try expectTestOk(parsed);
    }

    // `send_key` with a bogus key resolves the session first, then errors
    // inside the handler — exercising the error exit path of the
    // dispatch-level release.
    {
        var parsed = try testRequest(&registry, .{
            .op = "send_key",
            .session = "err-mid-handler",
            .key = "definitely-not-a-key",
        });
        defer parsed.deinit();
        try expectTestError(parsed, "invalid key");
    }

    // The borrow must be back to zero: the `defer registry.release(sess)`
    // in dispatchRequest ran on the error return.
    const sess = try sessionByName(&registry, "err-mid-handler");
    registry.mutex.lock();
    const refs = sess.ref_count;
    registry.mutex.unlock();
    try std.testing.expectEqual(@as(u32, 0), refs);

    // Delete must now free the session for real — a stuck refcount would
    // surface as a leak, and std.testing.allocator fails the test on leaks.
    {
        var parsed = try testRequest(&registry, .{ .op = "delete", .session = "err-mid-handler" });
        defer parsed.deinit();
        _ = try expectTestOk(parsed);
    }
    try std.testing.expectEqual(@as(usize, 0), sessionCount(&registry));
}

test "refcount: removeLocked defers free while borrowed; last release frees" {
    const alloc = std.testing.allocator;
    var registry = SessionRegistry.init(alloc);
    defer registry.deinit();

    {
        var parsed = try testRequest(&registry, .{
            .op = "spawn",
            .program = "/bin/cat",
            .name = "refcount",
            .rows = 8,
            .cols = 24,
            .emit_raw_bytes = false,
        });
        defer parsed.deinit();
        _ = try expectTestOk(parsed);
    }
    {
        var parsed = try testRequest(&registry, .{ .op = "kill", .session = "refcount" });
        defer parsed.deinit();
        _ = try expectTestOk(parsed);
    }

    // Borrow the session the way dispatchRequest does.
    const sess = try registry.resolveOrSole("refcount");

    // Remove while borrowed: the session is unpublished immediately (no
    // resolve can find it), but the storage must NOT be freed yet.
    registry.remove(sess);
    try std.testing.expectEqual(@as(usize, 0), sessionCount(&registry));
    try std.testing.expect(sess.isDoomed());
    try std.testing.expectError(error.SessionNotFound, registry.resolveOrSole("refcount"));

    // The borrow still protects the memory — reads through the pointer
    // are safe (the debug allocator would trip on freed memory).
    try std.testing.expect(sess.getStatus() != .running);

    // Dropping the last borrow frees the session; the testing allocator
    // fails the test if it leaks instead.
    registry.release(sess);
}

// ============================================================================
// Wait-poll snapshot gating (hardening: skip redundant snapshots)
// ============================================================================

// A timing-out `wait_for_text` polls ~every 25ms. With the screen static,
// the unified wait loop must snapshot only on its first iteration — the
// change stamp gating skips every subsequent poll — and the gate must not
// stop a genuine screen change from being scanned and matched.
test "wait polls skip snapshots while the screen is unchanged" {
    var registry = SessionRegistry.init(std.testing.allocator);
    defer registry.deinit();

    {
        var parsed = try testRequest(&registry, .{
            .op = "spawn",
            .name = "quiet",
            .program = "/bin/cat",
            .rows = 8,
            .cols = 40,
            .emit_raw_bytes = false,
        });
        defer parsed.deinit();
        _ = try expectTestOk(parsed);
    }

    // Push some output through and let the screen settle so no straggling
    // PTY echo bumps the change stamp mid-measurement.
    {
        var parsed = try testRequest(&registry, .{
            .op = "send_text",
            .session = "quiet",
            .text = "settle marker\n",
        });
        defer parsed.deinit();
        _ = try expectTestOk(parsed);
    }
    {
        var parsed = try testRequest(&registry, .{
            .op = "wait_for_text",
            .session = "quiet",
            .text = "settle marker",
            .timeout_ms = 2_000,
        });
        defer parsed.deinit();
        _ = try expectTestOk(parsed);
    }
    {
        var parsed = try testRequest(&registry, .{
            .op = "wait_for_idle",
            .session = "quiet",
            .idle_ms = 300,
            .timeout_ms = 5_000,
        });
        defer parsed.deinit();
        _ = try expectTestOk(parsed);
    }

    const sess = (try registry.resolve("quiet")) orelse return error.SessionNotFound;
    const before = sess.terminal.snapshotCount();

    // ~24 poll iterations at 25ms. The needle never appears and the screen
    // never changes, so the loop must scan exactly once (first iteration);
    // the timeout response carries no snapshot payload, so the counter
    // delta is 1 in the steady state. Allow one extra in case a late drain
    // bumps the stamp once early in the wait — the point is that ~24
    // iterations must not take ~24 snapshots.
    {
        var parsed = try testRequest(&registry, .{
            .op = "wait_for_text",
            .session = "quiet",
            .text = "never appears",
            .timeout_ms = 600,
        });
        defer parsed.deinit();
        const object = try expectTestOk(parsed);
        const to_val = object.get("timed_out") orelse return error.InvalidResponse;
        try std.testing.expectEqual(true, to_val.bool);
    }
    const idle_polls_delta = sess.terminal.snapshotCount() - before;
    try std.testing.expect(idle_polls_delta <= 2);

    // The gate must not suppress a real change: fresh output bumps the
    // stamp, the next poll re-scans, and the wait resolves with a match.
    {
        var parsed = try testRequest(&registry, .{
            .op = "send_text",
            .session = "quiet",
            .text = "now it appears\n",
        });
        defer parsed.deinit();
        _ = try expectTestOk(parsed);
    }
    {
        var parsed = try testRequest(&registry, .{
            .op = "wait_for_text",
            .session = "quiet",
            .text = "now it appears",
            .timeout_ms = 2_000,
        });
        defer parsed.deinit();
        const object = try expectTestOk(parsed);
        const snapshot = object.get("snapshot") orelse return error.InvalidResponse;
        const snapshot_object = switch (snapshot) {
            .object => |o| o,
            else => return error.InvalidResponse,
        };
        const buffer = snapshot_object.get("buffer") orelse return error.InvalidResponse;
        try std.testing.expect(buffer == .string);
        try std.testing.expect(std.mem.indexOf(u8, buffer.string, "now it appears") != null);
    }

    {
        var parsed = try testRequest(&registry, .{ .op = "kill", .session = "quiet" });
        defer parsed.deinit();
        _ = try expectTestOk(parsed);
    }
}
