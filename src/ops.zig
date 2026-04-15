const std = @import("std");
const hty = @import("hty");

const Allocator = std.mem.Allocator;

const hex = @import("hex.zig");
const encodeHex = hex.encodeHex;
const decodeHex = hex.decodeHex;

const json = @import("json.zig");
const readOptionalBool = json.readOptionalBool;
const readOptionalString = json.readOptionalString;
const readOptionalU16 = json.readOptionalU16;
const readOptionalU64 = json.readOptionalU64;
const readOptionalUsize = json.readOptionalUsize;
const readRequiredString = json.readRequiredString;
const readRequiredU16 = json.readRequiredU16;
const readEnvArray = json.readEnvArray;
const readStringArray = json.readStringArray;

const keyToBytes = @import("keys.zig").keyToBytes;

const protocol = @import("protocol.zig");
const Response = protocol.Response;
const SessionSummary = protocol.SessionSummary;
const EventPayload = protocol.EventPayload;

const session_mod = @import("session.zig");
const Session = session_mod.Session;
const statusName = session_mod.statusName;

const log_mod = @import("log.zig");
const openSessionLog = log_mod.openSessionLog;
const logInputEvent = log_mod.logInputEvent;
const logResizeEvent = log_mod.logResizeEvent;
const logKilledEvent = log_mod.logKilledEvent;
const closeLogFile = log_mod.closeLogFile;

const SessionRegistry = @import("registry.zig").SessionRegistry;

// POSIX regex helpers defined in regex_helper.c. We use a C helper
// because Zig's @cImport translates regex_t as opaque on Linux,
// making it impossible to allocate on the stack.
const HtyRegex = opaque {};
extern fn hty_regex_compile(pattern: [*:0]const u8) ?*HtyRegex;
extern fn hty_regex_is_valid(re: *const HtyRegex) bool;
extern fn hty_regex_match(re: *const HtyRegex, haystack: [*:0]const u8) bool;
extern fn hty_regex_free(re: *HtyRegex) void;

pub fn handleSpawn(
    arena: Allocator,
    registry: *SessionRegistry,
    object: std.json.ObjectMap,
    id: ?i64,
) !Response {
    const program = try readRequiredString(object, "program");
    const args = try readStringArray(arena, object, "args");
    const env = try readEnvArray(arena, object, "env");
    const rows = try readOptionalU16(object, "rows", 24);
    const cols = try readOptionalU16(object, "cols", 80);
    const scrollback = try readOptionalUsize(object, "scrollback", 10_000);
    const cwd = try readOptionalString(object, "cwd");
    // Session logging always needs raw bytes; the client-provided value is
    // accepted for forward-compat but ignored.
    _ = try readOptionalBool(object, "emit_raw_bytes", true);
    const emit_raw_bytes = true;
    const emit_screen_updates = try readOptionalBool(object, "emit_screen_updates", true);
    const name = try readOptionalString(object, "name");

    const terminal = try hty.InteractiveTerminal.spawn(
        registry.alloc,
        .{
            .program = program,
            .args = args,
        },
        .{
            .rows = rows,
            .cols = cols,
            .scrollback = scrollback,
            .env = env,
            .cwd = cwd,
            .emit_raw_bytes = emit_raw_bytes,
            .emit_screen_updates = emit_screen_updates,
        },
    );
    errdefer terminal.deinit();

    const program_owned = try registry.alloc.dupe(u8, program);
    errdefer registry.alloc.free(program_owned);

    const args_joined_owned = try joinArgs(registry.alloc, args);
    errdefer registry.alloc.free(args_joined_owned);

    const name_owned: ?[]u8 = if (name) |n| try registry.alloc.dupe(u8, n) else null;
    errdefer if (name_owned) |n| registry.alloc.free(n);

    const sess = try registry.create(terminal, program_owned, args_joined_owned, name_owned);

    openSessionLog(arena, registry.log_dir, sess, program, args, rows, cols);

    return .{
        .id = id,
        .ok = true,
        .session = try buildSessionSummary(arena, sess),
    };
}

pub fn handleList(arena: Allocator, registry: *SessionRegistry, id: ?i64) !Response {
    const summaries = try arena.alloc(SessionSummary, registry.by_id.count());
    var it = registry.by_id.valueIterator();
    var index: usize = 0;
    while (it.next()) |sess_ptr| : (index += 1) {
        summaries[index] = try buildSessionSummary(arena, sess_ptr.*);
    }

    return .{
        .id = id,
        .ok = true,
        .sessions = summaries,
    };
}

pub fn handleSnapshot(arena: Allocator, sess: *Session, id: ?i64) !Response {
    var snapshot = try sess.terminal.snapshot();
    defer snapshot.deinit(sess.alloc);

    const buffer = try arena.dupe(u8, snapshot.buffer);
    const screen_ansi = try arena.dupe(u8, snapshot.screen_ansi);
    const title = if (snapshot.title) |current_title|
        try arena.dupe(u8, current_title)
    else
        null;
    const lines = try arena.alloc([]const u8, snapshot.lines.len);
    var line_iter = std.mem.splitScalar(u8, buffer, '\n');
    var idx: usize = 0;
    while (line_iter.next()) |line| : (idx += 1) {
        lines[idx] = line;
    }

    return .{
        .id = id,
        .ok = true,
        .snapshot = .{
            .rows = snapshot.rows,
            .cols = snapshot.cols,
            .cursor_row = snapshot.cursor_row,
            .cursor_col = snapshot.cursor_col,
            .title = title,
            .buffer = buffer,
            .screen_ansi = screen_ansi,
            .lines = lines,
            .status = statusName(sess.status),
        },
    };
}

pub fn handleSendText(arena: Allocator, sess: *Session, object: std.json.ObjectMap, id: ?i64) !Response {
    const text = try readRequiredString(object, "text");
    logInputEvent(arena, sess, text);
    try sess.terminal.send(.{ .text = text });
    return .{ .id = id, .ok = true };
}

pub fn handleSendKey(arena: Allocator, sess: *Session, object: std.json.ObjectMap, id: ?i64) !Response {
    const key = try readRequiredString(object, "key");
    const bytes = try keyToBytes(arena, key);
    logInputEvent(arena, sess, bytes);
    try sess.terminal.send(.{ .bytes = bytes });
    return .{ .id = id, .ok = true };
}

pub fn handleSendBytesHex(arena: Allocator, sess: *Session, object: std.json.ObjectMap, id: ?i64) !Response {
    const bytes_hex = try readRequiredString(object, "bytes_hex");
    const bytes = try decodeHex(arena, bytes_hex);
    logInputEvent(arena, sess, bytes);
    try sess.terminal.send(.{ .bytes = bytes });
    return .{ .id = id, .ok = true };
}

pub fn handleResize(arena: Allocator, sess: *Session, object: std.json.ObjectMap, id: ?i64) !Response {
    const rows = try readRequiredU16(object, "rows");
    const cols = try readRequiredU16(object, "cols");
    try sess.terminal.resize(rows, cols);
    logResizeEvent(arena, sess, rows, cols);
    return .{ .id = id, .ok = true };
}

pub fn handleWaitForText(
    arena: Allocator,
    registry: *SessionRegistry,
    sess: *Session,
    object: std.json.ObjectMap,
    id: ?i64,
) !Response {
    const needle = try readRequiredString(object, "text");
    const use_regex = try readOptionalBool(object, "regex", false);
    const timeout_ms = try readOptionalU64(object, "timeout_ms", 10_000);
    const deadline = std.time.milliTimestamp() + @as(i64, @intCast(timeout_ms));

    // If regex mode, compile the pattern once up front.
    var compiled_regex: ?*HtyRegex = null;
    if (use_regex) {
        const nul_pattern = try arena.dupeZ(u8, needle);
        compiled_regex = hty_regex_compile(nul_pattern.ptr);
        if (compiled_regex == null or !hty_regex_is_valid(compiled_regex.?)) {
            if (compiled_regex) |re| hty_regex_free(re);
            return error.InvalidRegex;
        }
    }
    defer if (compiled_regex) |re| hty_regex_free(re);

    while (std.time.milliTimestamp() <= deadline) {
        registry.drainAll();
        var snapshot = try sess.terminal.snapshot();
        const matched = if (compiled_regex) |re| blk: {
            const nul_haystack = arena.dupeZ(u8, snapshot.buffer) catch {
                snapshot.deinit(sess.alloc);
                return error.OutOfMemory;
            };
            break :blk hty_regex_match(re, nul_haystack.ptr);
        } else std.mem.indexOf(u8, snapshot.buffer, needle) != null;
        if (matched) {
            defer snapshot.deinit(sess.alloc);
            return try snapshotResponse(arena, id, snapshot, sess);
        }
        snapshot.deinit(sess.alloc);
        std.Thread.sleep(25 * std.time.ns_per_ms);
    }
    return .{ .id = id, .ok = true, .timed_out = true };
}

pub fn handleWaitForIdle(
    arena: Allocator,
    registry: *SessionRegistry,
    sess: *Session,
    object: std.json.ObjectMap,
    id: ?i64,
) !Response {
    const idle_ms_field = try readOptionalU64(object, "idle_ms", 250);
    const timeout_ms = try readOptionalU64(object, "timeout_ms", 10_000);
    const idle_ms: i64 = @intCast(idle_ms_field);
    const deadline = std.time.milliTimestamp() + @as(i64, @intCast(timeout_ms));

    while (std.time.milliTimestamp() <= deadline) {
        registry.drainAll();
        const since = std.time.milliTimestamp() - sess.last_screen_change_at_ms;
        if (since >= idle_ms) {
            var snapshot = try sess.terminal.snapshot();
            defer snapshot.deinit(sess.alloc);
            return try snapshotResponse(arena, id, snapshot, sess);
        }
        std.Thread.sleep(25 * std.time.ns_per_ms);
    }
    return .{ .id = id, .ok = true, .timed_out = true };
}

pub fn handleWaitForExit(
    arena: Allocator,
    registry: *SessionRegistry,
    sess: *Session,
    object: std.json.ObjectMap,
    id: ?i64,
) !Response {
    _ = arena;
    const timeout_ms = try readOptionalU64(object, "timeout_ms", 10_000);
    const deadline = std.time.milliTimestamp() + @as(i64, @intCast(timeout_ms));

    while (std.time.milliTimestamp() <= deadline) {
        registry.drainAll();
        if (sess.status != .running) {
            return .{
                .id = id,
                .ok = true,
                .event = .{ .kind = "exited", .code = sess.exit_code },
            };
        }
        std.Thread.sleep(25 * std.time.ns_per_ms);
    }
    return .{ .id = id, .ok = true, .timed_out = true };
}

pub fn handleKill(arena: Allocator, registry: *SessionRegistry, sess: *Session, id: ?i64) !Response {
    _ = registry;
    if (sess.status == .running) {
        logKilledEvent(arena, sess);
        closeLogFile(sess);
        sess.terminal.kill() catch {};
        sess.status = .killed;
        // Name stays reserved — the session record is still browsable and
        // replayable until explicitly removed with `hty delete`.
    }
    return .{ .id = id, .ok = true };
}

pub fn handleDelete(arena: Allocator, registry: *SessionRegistry, sess: *Session, id: ?i64) !Response {
    // Terminate the child if it's still running so we don't orphan it.
    if (sess.status == .running) {
        logKilledEvent(arena, sess);
        closeLogFile(sess);
        sess.terminal.kill() catch {};
        sess.status = .killed;
    } else {
        // Already ended; just make sure the log file handle is closed.
        closeLogFile(sess);
    }

    // Delete the log file and by-name symlink from disk before the session
    // struct (and its id/name storage) go away.
    if (registry.log_dir) |log_dir| {
        const uuid_path = std.fmt.allocPrint(
            arena,
            "{s}/{s}.jsonl",
            .{ log_dir, &sess.id },
        ) catch null;
        if (uuid_path) |p| std.fs.deleteFileAbsolute(p) catch {};

        if (sess.name) |name| {
            const link_path = std.fmt.allocPrint(
                arena,
                "{s}/by-name/{s}.jsonl",
                .{ log_dir, name },
            ) catch null;
            if (link_path) |p| std.fs.deleteFileAbsolute(p) catch {};
        }
    }

    registry.remove(sess);
    return .{ .id = id, .ok = true };
}

pub fn snapshotResponse(arena: Allocator, id: ?i64, snapshot: hty.ScreenSnapshot, sess: *Session) !Response {
    const buffer = try arena.dupe(u8, snapshot.buffer);
    const screen_ansi = try arena.dupe(u8, snapshot.screen_ansi);
    const title = if (snapshot.title) |current_title|
        try arena.dupe(u8, current_title)
    else
        null;
    const lines = try arena.alloc([]const u8, snapshot.lines.len);
    var line_iter = std.mem.splitScalar(u8, buffer, '\n');
    var idx: usize = 0;
    while (line_iter.next()) |line| : (idx += 1) {
        lines[idx] = line;
    }

    return .{
        .id = id,
        .ok = true,
        .snapshot = .{
            .rows = snapshot.rows,
            .cols = snapshot.cols,
            .cursor_row = snapshot.cursor_row,
            .cursor_col = snapshot.cursor_col,
            .title = title,
            .buffer = buffer,
            .screen_ansi = screen_ansi,
            .lines = lines,
            .status = statusName(sess.status),
        },
    };
}

pub fn buildSessionSummary(arena: Allocator, sess: *Session) !SessionSummary {
    return .{
        .id = try arena.dupe(u8, &sess.id),
        .name = if (sess.name) |n| try arena.dupe(u8, n) else null,
        .program = try arena.dupe(u8, sess.program),
        .args = try arena.dupe(u8, sess.args_joined),
        .status = statusName(sess.status),
        .created_at_ms = sess.created_at_ms,
    };
}

pub fn joinArgs(alloc: Allocator, args: []const []const u8) ![]u8 {
    if (args.len == 0) return try alloc.alloc(u8, 0);
    var total: usize = 0;
    for (args) |arg| total += arg.len + 1;
    const out = try alloc.alloc(u8, total - 1);
    var idx: usize = 0;
    for (args, 0..) |arg, i| {
        if (i > 0) {
            out[idx] = ' ';
            idx += 1;
        }
        @memcpy(out[idx..][0..arg.len], arg);
        idx += arg.len;
    }
    return out;
}

pub fn eventToPayload(arena: Allocator, event: hty.OutputEvent) !EventPayload {
    return switch (event) {
        .started => .{ .kind = "started" },
        .screen_update => .{ .kind = "screen_update" },
        .bell => .{ .kind = "bell" },
        .title_changed => |title| .{
            .kind = "title_changed",
            .title = try arena.dupe(u8, title),
        },
        .exited => |code| .{ .kind = "exited", .code = code },
        .failure => |message| .{
            .kind = "failure",
            .message = try arena.dupe(u8, message),
        },
        .raw_bytes => |bytes| .{
            .kind = "raw_bytes",
            .bytes_hex = try encodeHex(arena, bytes),
        },
    };
}

test "joinArgs handles empty, single, multi" {
    const empty_result = try joinArgs(std.testing.allocator, &.{});
    defer std.testing.allocator.free(empty_result);
    try std.testing.expectEqualStrings("", empty_result);

    const single_result = try joinArgs(std.testing.allocator, &.{"foo"});
    defer std.testing.allocator.free(single_result);
    try std.testing.expectEqualStrings("foo", single_result);

    const multi_result = try joinArgs(std.testing.allocator, &.{ "foo", "bar baz", "qux" });
    defer std.testing.allocator.free(multi_result);
    try std.testing.expectEqualStrings("foo bar baz qux", multi_result);
}
