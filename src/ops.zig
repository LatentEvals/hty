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
const WaitPayload = protocol.WaitPayload;
const WaitTextMatch = protocol.WaitTextMatch;
const WaitExitInfo = protocol.WaitExitInfo;

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
extern fn hty_regex_find(re: *const HtyRegex, haystack: [*:0]const u8) c_long;
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

/// Server-side `info` op. Returns the pid and uptime (milliseconds since
/// the registry was constructed, which is the earliest observable moment
/// of server life). Clients call this when they want `hty info --json` to
/// include live server stats. All the "local" fields (`version`,
/// `socket_path`, `state_dir`, `log_dir`) are empty here because the
/// client knows its own paths; the server just fills in what only it
/// can know (pid, uptime).
pub fn handleInfo(arena: Allocator, registry: *SessionRegistry, id: ?i64) !Response {
    _ = arena;
    const now = std.time.milliTimestamp();
    const uptime_ms = now - registry.started_at_ms;
    const server_pid: i64 = @intCast(posix_getpid());
    return .{
        .id = id,
        .ok = true,
        .info = .{
            .version = "",
            .socket_path = "",
            .state_dir = "",
            .log_dir = "",
            .server = .{
                .running = true,
                .pid = server_pid,
                .uptime_ms = uptime_ms,
            },
            // The server-side `info` response only exists to surface
            // pid / uptime; the client rebuilds the full payload
            // (including `build`) before rendering, so an empty stub
            // is enough here.
            .build = .{
                .version = "",
                .mode = "",
            },
        },
    };
}

extern "c" fn getpid() c_int;

fn posix_getpid() c_int {
    return getpid();
}

pub fn handleList(arena: Allocator, registry: *SessionRegistry, id: ?i64) !Response {
    // Build the summary list under the registry lock so we don't see a
    // session being removed mid-iteration. `buildSessionSummary` only
    // reads atomic/immutable session fields, so holding the lock across
    // it is fine — no session-local locks acquired inside.
    registry.mutex.lock();
    defer registry.mutex.unlock();

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
    const cells = try dupeCells(arena, snapshot.cells);

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
            .cells = cells,
            .status = statusName(sess.getStatus()),
            .mouse = mouseWireFromSnapshot(sess.mouse_state.snapshot()),
        },
    };
}

/// Deep-copy the `cells` grid from `ScreenSnapshot` (terminal-owned) into
/// arena memory so it can safely outlive `snapshot.deinit`.
fn dupeCells(arena: Allocator, src: [][]const []const u8) ![]const []const []const u8 {
    const rows = try arena.alloc([]const []const u8, src.len);
    for (src, 0..) |row, r| {
        const row_copy = try arena.alloc([]const u8, row.len);
        for (row, 0..) |cell, c| {
            row_copy[c] = try arena.dupe(u8, cell);
        }
        rows[r] = row_copy;
    }
    return rows;
}

pub fn handleSendText(arena: Allocator, sess: *Session, object: std.json.ObjectMap, id: ?i64) !Response {
    const text = try readRequiredString(object, "text");
    logInputEvent(arena, sess, text, "send", null);
    try sess.terminal.send(.{ .text = text });
    return .{ .id = id, .ok = true };
}

pub fn handleSendKey(arena: Allocator, sess: *Session, object: std.json.ObjectMap, id: ?i64) !Response {
    const key = try readRequiredString(object, "key");
    const bytes = try keyToBytes(arena, key);
    logInputEvent(arena, sess, bytes, "send", null);
    try sess.terminal.send(.{ .bytes = bytes });
    return .{ .id = id, .ok = true };
}

pub fn handleSendBytesHex(arena: Allocator, sess: *Session, object: std.json.ObjectMap, id: ?i64) !Response {
    const bytes_hex = try readRequiredString(object, "bytes_hex");
    const bytes = try decodeHex(arena, bytes_hex);
    logInputEvent(arena, sess, bytes, "send", null);
    try sess.terminal.send(.{ .bytes = bytes });
    return .{ .id = id, .ok = true };
}

/// Encode a single mouse event into the bytes the target app expects,
/// using whichever encoding it has negotiated on the output stream
/// (SGR `?1006` preferred; falls back to legacy X10). Picks SGR whenever
/// `?1006` is set *or* the coordinates exceed the X10 range (byte + 32,
/// capped at 223), so we never silently truncate a click to the wrong
/// cell.
///
/// Wire shape: `{op: "send_mouse", event: "press"|"release"|"motion",
/// button: "left"|"right"|"middle"|"wheel_up"|"wheel_down", row: N,
/// col: N}`. Rows and cols are 1-indexed (snapshot convention).
///
/// If no app has enabled mouse input (none of `?1000` / `?1002` / `?1003`
/// observed), returns `error.MouseNotEnabled` — the client surfaces this
/// as a clear "target app has not enabled mouse input" error. Design
/// choice (a) in the spec: agents need to know the click was a no-op.
pub fn handleSendMouse(arena: Allocator, sess: *Session, object: std.json.ObjectMap, id: ?i64) !Response {
    const event = try readRequiredString(object, "event");
    const button = try readRequiredString(object, "button");
    const row_u64 = try json.readRequiredU64(object, "row");
    const col_u64 = try json.readRequiredU64(object, "col");
    if (row_u64 == 0 or col_u64 == 0) return error.InvalidFieldValue;

    const mouse = sess.mouse_state.snapshot();
    if (!mouse.enabled()) return error.MouseNotEnabled;

    // Ghostty's VT engine speaks in 1-indexed rows/cols, matching
    // xterm's wire format — no off-by-one here.
    const row: u32 = @intCast(row_u64);
    const col: u32 = @intCast(col_u64);

    // Map logical button to the base code used in both X10 and SGR
    // encodings. 0/1/2 = left/middle/right press; 64/65 = wheel up/down
    // (the "release" concept doesn't apply for wheels — we always emit
    // a single press). Motion adds 32 to the button code in both
    // encodings.
    var base: u32 = undefined;
    var is_wheel = false;
    if (std.mem.eql(u8, button, "left")) {
        base = 0;
    } else if (std.mem.eql(u8, button, "middle")) {
        base = 1;
    } else if (std.mem.eql(u8, button, "right")) {
        base = 2;
    } else if (std.mem.eql(u8, button, "wheel_up")) {
        base = 64;
        is_wheel = true;
    } else if (std.mem.eql(u8, button, "wheel_down")) {
        base = 65;
        is_wheel = true;
    } else {
        return error.InvalidFieldValue;
    }

    const is_motion = std.mem.eql(u8, event, "motion");
    const is_release = std.mem.eql(u8, event, "release");
    const is_press = std.mem.eql(u8, event, "press");
    if (!is_motion and !is_release and !is_press) return error.InvalidFieldValue;

    // Motion flag lives in bit 5 of the button code for both encodings.
    var button_code = base;
    if (is_motion) button_code |= 32;

    // Fall back to SGR if the app asked for it, or if legacy X10 would
    // overflow its single-byte coordinate field (col/row > 223 once you
    // add the +32 offset and cap at 0xFF). Cleaner than silently
    // clipping — agents picking coords out of a large snapshot would
    // otherwise click the wrong cell at the edge of a wide terminal.
    const use_sgr = mouse.sgr or col > 223 or row > 223;

    var buf = std.array_list.Managed(u8).init(arena);
    if (use_sgr) {
        // `ESC [ < <btn> ; <col> ; <row> M/m` — M for press/motion,
        // m for release. Wheels use M.
        const terminator: u8 = if (is_release and !is_wheel) 'm' else 'M';
        try buf.writer().print("\x1b[<{d};{d};{d}{c}", .{ button_code, col, row, terminator });
    } else {
        // X10: `ESC [ M <btn+32> <col+32> <row+32>`. Release maps to
        // button 3 (same for all buttons) in legacy encoding; motion
        // adds 32 in the button field (already applied above for
        // motion). Wheel events use the raw 64/65 code untouched.
        const x10_btn: u32 = if (is_release and !is_wheel) 3 else button_code;
        try buf.writer().print("\x1b[M", .{});
        try buf.append(@intCast(@min(x10_btn + 32, 0xFF)));
        try buf.append(@intCast(@min(col + 32, 0xFF)));
        try buf.append(@intCast(@min(row + 32, 0xFF)));
    }

    const bytes = buf.items;
    logInputEvent(arena, sess, bytes, "send", null);
    try sess.terminal.send(.{ .bytes = bytes });
    return .{ .id = id, .ok = true };
}

fn mouseWireFromSnapshot(s: session_mod.MouseStateSnapshot) protocol.MouseStateWire {
    return .{
        .enabled = s.enabled(),
        .x10 = s.x10,
        .button_event = s.button_event,
        .any_event = s.any_event,
        .sgr = s.sgr,
    };
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
    const start_ms = std.time.milliTimestamp();
    const deadline = start_ms + @as(i64, @intCast(timeout_ms));

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

    // Drain before each sleep. The accept thread also drains every 25ms,
    // but in-process test callers drive `processRequestLine` directly
    // with no accept loop, so the wait handlers remain the only thing
    // flushing events into the log and updating session state. Each
    // drainAll acquires the registry lock briefly and releases before
    // the sleep, so concurrent workers are not serialized behind the
    // wait.
    while (std.time.milliTimestamp() <= deadline) {
        registry.drainAll();

        var snapshot = try sess.terminal.snapshot();
        defer snapshot.deinit(sess.alloc);

        // Capture the byte offset of the match during the first (and only)
        // scan so regex callers get a uniform `text.offset` field. The
        // regex helper returns the offset directly from `regexec`'s
        // pmatch[0], so this doesn't cost a second pattern execution —
        // it's the same call that decides match-vs-no-match.
        const offset: ?i64 = if (compiled_regex) |re| blk: {
            const pos = try regexFindHaystack(sess.alloc, re, snapshot.buffer);
            break :blk pos;
        } else blk: {
            const idx = std.mem.indexOf(u8, snapshot.buffer, needle);
            break :blk if (idx) |i| @as(i64, @intCast(i)) else null;
        };
        if (offset) |off| {
            const elapsed = std.time.milliTimestamp() - start_ms;
            const needle_owned = try arena.dupe(u8, needle);
            const sid = try arena.dupe(u8, &sess.id);
            return try snapshotResponseWithWait(arena, id, snapshot, sess, .{
                .matched = "text",
                .elapsed_ms = elapsed,
                .session = sid,
                .text = .{ .needle = needle_owned, .offset = off },
            });
        }
        std.Thread.sleep(25 * std.time.ns_per_ms);
    }
    const elapsed = std.time.milliTimestamp() - start_ms;
    const sid = try arena.dupe(u8, &sess.id);
    return .{
        .id = id,
        .ok = true,
        .timed_out = true,
        .wait = .{
            .matched = null,
            .elapsed_ms = elapsed,
            .session = sid,
            .timeout = true,
        },
    };
}

/// Match a regex against a terminal snapshot using bounded temporary memory.
/// The haystack copy lives only for the duration of this call, so repeated
/// polling does not accumulate copies in the long-lived request arena.
pub fn regexMatchHaystack(alloc: Allocator, re: *const HtyRegex, haystack: []const u8) !bool {
    var haystack_arena = std.heap.ArenaAllocator.init(alloc);
    defer haystack_arena.deinit();

    const temp_alloc = haystack_arena.allocator();
    const nul_haystack = try temp_alloc.dupeZ(u8, haystack);
    return hty_regex_match(re, nul_haystack.ptr);
}

/// Like `regexMatchHaystack` but returns the byte offset of the first match
/// (or null when the pattern doesn't match). Uses the same bounded-arena
/// pattern so repeated polling doesn't accumulate haystack copies.
pub fn regexFindHaystack(alloc: Allocator, re: *const HtyRegex, haystack: []const u8) !?i64 {
    var haystack_arena = std.heap.ArenaAllocator.init(alloc);
    defer haystack_arena.deinit();

    const temp_alloc = haystack_arena.allocator();
    const nul_haystack = try temp_alloc.dupeZ(u8, haystack);
    const pos = hty_regex_find(re, nul_haystack.ptr);
    if (pos < 0) return null;
    return @intCast(pos);
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
    const start_ms = std.time.milliTimestamp();
    const deadline = start_ms + @as(i64, @intCast(timeout_ms));

    while (std.time.milliTimestamp() <= deadline) {
        registry.drainAll();

        const since = std.time.milliTimestamp() - sess.getLastScreenChange();
        if (since >= idle_ms) {
            var snapshot = try sess.terminal.snapshot();
            defer snapshot.deinit(sess.alloc);
            const elapsed = std.time.milliTimestamp() - start_ms;
            const sid = try arena.dupe(u8, &sess.id);
            return try snapshotResponseWithWait(arena, id, snapshot, sess, .{
                .matched = "idle",
                .elapsed_ms = elapsed,
                .session = sid,
            });
        }
        std.Thread.sleep(25 * std.time.ns_per_ms);
    }
    const elapsed = std.time.milliTimestamp() - start_ms;
    const sid = try arena.dupe(u8, &sess.id);
    return .{
        .id = id,
        .ok = true,
        .timed_out = true,
        .wait = .{
            .matched = null,
            .elapsed_ms = elapsed,
            .session = sid,
            .timeout = true,
        },
    };
}

pub fn handleWaitForExit(
    arena: Allocator,
    registry: *SessionRegistry,
    sess: *Session,
    object: std.json.ObjectMap,
    id: ?i64,
) !Response {
    const timeout_ms = try readOptionalU64(object, "timeout_ms", 10_000);
    const start_ms = std.time.milliTimestamp();
    const deadline = start_ms + @as(i64, @intCast(timeout_ms));

    while (std.time.milliTimestamp() <= deadline) {
        registry.drainAll();

        if (sess.getStatus() != .running) {
            const elapsed = std.time.milliTimestamp() - start_ms;
            const code_opt = sess.getExitCode();
            const code: i32 = code_opt orelse 0;
            const sid = try arena.dupe(u8, &sess.id);
            return .{
                .id = id,
                .ok = true,
                .event = .{ .kind = "exited", .code = code },
                .wait = .{
                    .matched = "exit",
                    .elapsed_ms = elapsed,
                    .session = sid,
                    .exit = .{ .code = code },
                },
            };
        }
        std.Thread.sleep(25 * std.time.ns_per_ms);
    }
    const elapsed = std.time.milliTimestamp() - start_ms;
    const sid = try arena.dupe(u8, &sess.id);
    return .{
        .id = id,
        .ok = true,
        .timed_out = true,
        .wait = .{
            .matched = null,
            .elapsed_ms = elapsed,
            .session = sid,
            .timeout = true,
        },
    };
}

/// Server-side fused wait+snapshot op. The client-side commands `hty send`
/// and `hty run` issue this after their input ops have completed, so a
/// single round-trip handles "wait for this condition and then snapshot
/// the screen" without the race window the three-RPC `send → wait → snapshot`
/// flow had (where idle could fire before the new send produced output).
///
/// The race fix is in the `idle` branch: the idle reference is
/// `max(last_screen_change, op_start_ms)`, so a session that's been quiet
/// for a long time before this op begins won't immediately satisfy
/// `--wait-until-idle 100` — we only count idle time accumulated *after*
/// this op started, which is at-or-after the moment the upstream send
/// returned.
///
/// `wait_kind` selects the condition:
/// - `"none"`        — no wait; just (optionally) snapshot.
/// - `"duration"`    — sleep `duration_ms`, then (optionally) snapshot.
/// - `"idle"`        — wait until the session has been idle for `idle_ms`
///                     (default 100), measured against the op-start floor.
/// - `"text"`        — wait until `text` appears in the rendered buffer.
/// - `"regex"`       — wait until the POSIX regex in `text` matches.
/// - `"exit"`        — wait until the child exits.
///
/// `timeout_ms` defaults to 30_000; a value of `0` disables the timeout.
/// `snapshot` (bool) controls whether the response includes the snapshot
/// payload.
pub fn handleWaitAndSnapshot(
    arena: Allocator,
    registry: *SessionRegistry,
    sess: *Session,
    object: std.json.ObjectMap,
    id: ?i64,
) !Response {
    const wait_kind_opt = try readOptionalString(object, "wait_kind");
    const wait_kind = wait_kind_opt orelse "none";
    const include_snapshot = try readOptionalBool(object, "snapshot", false);
    const timeout_ms_field = try readOptionalU64(object, "timeout_ms", 30_000);
    const start_ms = std.time.milliTimestamp();

    // timeout_ms == 0 means "no timeout" — pin the deadline at the largest
    // representable value so the loop never trips it.
    const deadline: i64 = if (timeout_ms_field == 0)
        std.math.maxInt(i64)
    else
        start_ms + @as(i64, @intCast(timeout_ms_field));

    if (std.mem.eql(u8, wait_kind, "none")) {
        return try buildFusedResponse(arena, id, sess, include_snapshot, null, 0, false, null, null);
    }

    if (std.mem.eql(u8, wait_kind, "duration")) {
        const duration_ms = try readOptionalU64(object, "duration_ms", 0);
        std.Thread.sleep(duration_ms * std.time.ns_per_ms);
        registry.drainAll();
        const elapsed = std.time.milliTimestamp() - start_ms;
        return try buildFusedResponse(arena, id, sess, include_snapshot, "duration", elapsed, false, null, null);
    }

    if (std.mem.eql(u8, wait_kind, "idle")) {
        const idle_ms_field = try readOptionalU64(object, "idle_ms", 100);
        const idle_ms: i64 = @intCast(idle_ms_field);

        while (std.time.milliTimestamp() <= deadline) {
            registry.drainAll();
            // Race fix: if the session was already idle before this op
            // started, treat op-start as the idle reference instead.
            const reference = @max(sess.getLastScreenChange(), start_ms);
            const since = std.time.milliTimestamp() - reference;
            if (since >= idle_ms) {
                const elapsed = std.time.milliTimestamp() - start_ms;
                return try buildFusedResponse(arena, id, sess, include_snapshot, "idle", elapsed, false, null, null);
            }
            std.Thread.sleep(25 * std.time.ns_per_ms);
        }
        const elapsed = std.time.milliTimestamp() - start_ms;
        return try buildFusedResponse(arena, id, sess, include_snapshot, null, elapsed, true, null, null);
    }

    if (std.mem.eql(u8, wait_kind, "text") or std.mem.eql(u8, wait_kind, "regex")) {
        const needle = try readRequiredString(object, "text");
        const use_regex = std.mem.eql(u8, wait_kind, "regex");

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
            defer snapshot.deinit(sess.alloc);

            const offset: ?i64 = if (compiled_regex) |re| blk: {
                break :blk try regexFindHaystack(sess.alloc, re, snapshot.buffer);
            } else blk: {
                const idx = std.mem.indexOf(u8, snapshot.buffer, needle);
                break :blk if (idx) |i| @as(i64, @intCast(i)) else null;
            };
            if (offset) |off| {
                const elapsed = std.time.milliTimestamp() - start_ms;
                const needle_owned = try arena.dupe(u8, needle);
                const matched_label: []const u8 = if (use_regex) "regex" else "text";
                const text_match = WaitTextMatch{ .needle = needle_owned, .offset = off };
                return try buildFusedResponse(arena, id, sess, include_snapshot, matched_label, elapsed, false, text_match, null);
            }
            std.Thread.sleep(25 * std.time.ns_per_ms);
        }
        const elapsed = std.time.milliTimestamp() - start_ms;
        return try buildFusedResponse(arena, id, sess, include_snapshot, null, elapsed, true, null, null);
    }

    if (std.mem.eql(u8, wait_kind, "exit")) {
        while (std.time.milliTimestamp() <= deadline) {
            registry.drainAll();
            if (sess.getStatus() != .running) {
                const elapsed = std.time.milliTimestamp() - start_ms;
                const code: i32 = sess.getExitCode() orelse 0;
                return try buildFusedResponse(arena, id, sess, include_snapshot, "exit", elapsed, false, null, .{ .code = code });
            }
            std.Thread.sleep(25 * std.time.ns_per_ms);
        }
        const elapsed = std.time.milliTimestamp() - start_ms;
        return try buildFusedResponse(arena, id, sess, include_snapshot, null, elapsed, true, null, null);
    }

    return error.InvalidFieldValue;
}

/// Pack a wait + (optional) snapshot result into a Response. Centralizes
/// the snapshot allocation so the wait branches above don't each duplicate
/// the snapshot/wait-payload plumbing.
fn buildFusedResponse(
    arena: Allocator,
    id: ?i64,
    sess: *Session,
    include_snapshot: bool,
    matched: ?[]const u8,
    elapsed_ms: i64,
    timed_out: bool,
    text: ?WaitTextMatch,
    exit_info: ?WaitExitInfo,
) !Response {
    const sid = try arena.dupe(u8, &sess.id);
    const wait_payload = WaitPayload{
        .matched = matched,
        .elapsed_ms = elapsed_ms,
        .session = sid,
        .timeout = timed_out,
        .text = text,
        .exit = exit_info,
    };

    if (!include_snapshot) {
        return .{
            .id = id,
            .ok = true,
            .timed_out = timed_out,
            .wait = wait_payload,
        };
    }

    var snapshot = try sess.terminal.snapshot();
    defer snapshot.deinit(sess.alloc);
    var response = try snapshotResponse(arena, id, snapshot, sess);
    response.wait = wait_payload;
    response.timed_out = timed_out;
    return response;
}

pub fn handleKill(arena: Allocator, registry: *SessionRegistry, sess: *Session, id: ?i64) !Response {
    _ = registry;
    if (sess.getStatus() == .running) {
        logKilledEvent(arena, sess);
        closeLogFile(sess);
        sess.terminal.kill() catch {};
        sess.setStatus(.killed);
        // Name stays reserved — the session record is still browsable and
        // replayable until explicitly removed with `hty delete`.
    }
    return .{ .id = id, .ok = true };
}

pub fn handleDelete(arena: Allocator, registry: *SessionRegistry, sess: *Session, id: ?i64) !Response {
    // Terminate the child if it's still running so we don't orphan it.
    if (sess.getStatus() == .running) {
        logKilledEvent(arena, sess);
        closeLogFile(sess);
        sess.terminal.kill() catch {};
        sess.setStatus(.killed);
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

pub fn snapshotResponseWithWait(
    arena: Allocator,
    id: ?i64,
    snapshot: hty.ScreenSnapshot,
    sess: *Session,
    wait_payload: WaitPayload,
) !Response {
    var response = try snapshotResponse(arena, id, snapshot, sess);
    response.wait = wait_payload;
    return response;
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
    const cells = try dupeCells(arena, snapshot.cells);

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
            .cells = cells,
            .status = statusName(sess.getStatus()),
            .mouse = mouseWireFromSnapshot(sess.mouse_state.snapshot()),
        },
    };
}

pub fn buildSessionSummary(arena: Allocator, sess: *Session) !SessionSummary {
    return .{
        .id = try arena.dupe(u8, &sess.id),
        .name = if (sess.name) |n| try arena.dupe(u8, n) else null,
        .program = try arena.dupe(u8, sess.program),
        .args = try arena.dupe(u8, sess.args_joined),
        .status = statusName(sess.getStatus()),
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

test "regexMatchHaystack does not retain haystack copies across calls" {
    var gpa = std.heap.DebugAllocator(.{ .enable_memory_limit = true }){};
    defer std.testing.expect(gpa.deinit() == .ok) catch @panic("leak");
    const alloc = gpa.allocator();

    const pattern = try alloc.dupeZ(u8, "needle");
    defer alloc.free(pattern);
    const re = hty_regex_compile(pattern.ptr) orelse return error.OutOfMemory;
    defer hty_regex_free(re);

    const haystack = try alloc.alloc(u8, 16 * 1024);
    defer alloc.free(haystack);
    @memset(haystack, 'a');

    const baseline = gpa.total_requested_bytes;
    var i: usize = 0;
    while (i < 64) : (i += 1) {
        try std.testing.expect(!(try regexMatchHaystack(alloc, re, haystack)));
        try std.testing.expectEqual(baseline, gpa.total_requested_bytes);
    }
}
