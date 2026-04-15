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

const SessionRegistry = @import("registry.zig").SessionRegistry;
const processRequestLine = @import("server.zig").processRequestLine;
const replayToTerminal = @import("commands/replay.zig").replayToTerminal;

// ============================================================================
// Integration test helpers (drive the in-process dispatch without sockets)
// ============================================================================

fn testRequest(
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

fn expectTestOk(parsed: std.json.Parsed(std.json.Value)) !std.json.ObjectMap {
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
    }

    {
        var parsed = try testRequest(&registry, .{ .op = "kill", .session = "cat" });
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
        const snap_obj = switch (snap) { .object => |o| o, else => return error.InvalidResponse };
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
        const snap_obj = switch (snap) { .object => |o| o, else => return error.InvalidResponse };
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
fn expectTestError(parsed: std.json.Parsed(std.json.Value), needle: []const u8) !void {
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
fn spawnCatSession(registry: *SessionRegistry, name: ?[]const u8) ![]u8 {
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
    const session_obj = switch (session) { .object => |o| o, else => return error.InvalidResponse };
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
        const snap_obj = switch (snap) { .object => |o| o, else => return error.InvalidResponse };
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
