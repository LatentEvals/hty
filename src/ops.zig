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
const encodeResponse = protocol.encodeResponse;
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
    // Opt-in: when true, the drain-loop auto-removes this session once
    // its child exits (success, failure, or signal). Wired up by
    // `hty run --remove`. Default false preserves the historical
    // "sessions linger after exit until `hty delete`" behavior.
    const remove_on_exit = try readOptionalBool(object, "remove", false);

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
    sess.remove_on_exit = remove_on_exit;

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
/// using whichever encoding it has negotiated on the output stream.
/// SGR (`ESC [ < ... M/m`) is used only when the app enabled `?1006`;
/// otherwise legacy X10 (`ESC [ M <btn+32> <col+32> <row+32>`) is used.
/// If the coords exceed the X10 single-byte range (col/row > 223) and
/// the app hasn't enabled SGR, we surface `error.MouseCoordOutOfRange`
/// rather than silently sending SGR bytes to an X10-only app (which it
/// couldn't parse) or truncating the click to the wrong cell.
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

    // SGR only when the target app negotiated `?1006`. If the app is
    // X10-only and the coords don't fit (col/row > 223 once you add the
    // +32 offset), surface an error rather than silently sending SGR
    // bytes the app can't parse — or truncating to the wrong cell.
    const use_sgr = mouse.sgr;
    if (!use_sgr and (col > 223 or row > 223)) return error.MouseCoordOutOfRange;

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

/// The condition a wait loop polls for. Both RPC surfaces — the standalone
/// `wait_for_*` ops and the fused `wait_and_snapshot` op — parse their
/// request fields into one of these and run the same `runWait` loop; only
/// the response formatting differs per surface.
pub const WaitCondition = union(enum) {
    /// Sleep a fixed number of milliseconds, then complete. Never times
    /// out (the fused op's `duration` kind ignores the deadline).
    duration: u64,
    /// Complete once the screen has been quiet for `idle_ms`. When
    /// `floor_ms` is set, the idle reference is
    /// `max(last_screen_change, floor_ms)` — the fused op passes its
    /// op-start time so a long-quiet session can't satisfy the idle wait
    /// instantly (see `handleWaitAndSnapshot`). The standalone op passes
    /// null to keep its historical "idle since whenever" semantics.
    idle: struct { idle_ms: i64, floor_ms: ?i64 },
    /// Complete once `needle` appears in the rendered buffer — substring
    /// match, or POSIX regex when `regex` is non-null. `matched_label` is
    /// the wire value reported on success: the standalone op always says
    /// "text" (historical shape, even in regex mode) while the fused op
    /// distinguishes "text" / "regex".
    text: struct { needle: []const u8, regex: ?*HtyRegex, matched_label: []const u8 },
    /// Complete once the child process has exited.
    exit,
};

/// Outcome of a wait, surface-agnostic. `evaluateWaitCondition` produces
/// the satisfied outcomes (`matched` non-null, with `text`/`exit` detail
/// when the condition provides it); `runWait` produces the `timed_out`
/// ones.
pub const WaitResult = struct {
    matched: ?[]const u8 = null,
    elapsed_ms: i64 = 0,
    timed_out: bool = false,
    text: ?WaitTextMatch = null,
    exit: ?WaitExitInfo = null,
};

/// Compile a POSIX regex for a text wait, surfacing `error.InvalidRegex`
/// on any compile failure. Caller owns the result (`hty_regex_free`).
fn compileWaitRegex(arena: Allocator, pattern: []const u8) !*HtyRegex {
    const nul_pattern = try arena.dupeZ(u8, pattern);
    const re = hty_regex_compile(nul_pattern.ptr) orelse return error.InvalidRegex;
    if (!hty_regex_is_valid(re)) {
        hty_regex_free(re);
        return error.InvalidRegex;
    }
    return re;
}

/// The four RPC ops that can wait. Every one of them is parsed by
/// `planWait` into the same `WaitCondition` core; the kind decides which
/// request fields to read and which response shape (`WaitFormat`) applies.
pub const WaitOpKind = enum { text, idle, exit, fused };

/// Map an op name to its wait kind, or null for non-wait ops. The event
/// loop uses this to decide whether a request parks the connection as a
/// waiter instead of dispatching synchronously through the op table.
pub fn waitOpKind(op: []const u8) ?WaitOpKind {
    if (std.mem.eql(u8, op, "wait_for_text")) return .text;
    if (std.mem.eql(u8, op, "wait_for_idle")) return .idle;
    if (std.mem.eql(u8, op, "wait_for_exit")) return .exit;
    if (std.mem.eql(u8, op, "wait_and_snapshot")) return .fused;
    return null;
}

/// Which wire shape a wait outcome is formatted into: the standalone
/// `wait_for_*` shape or the fused `wait_and_snapshot` shape (with or
/// without the snapshot payload).
pub const WaitFormat = enum { standalone, fused_bare, fused_snapshot };

/// A parsed wait request: what to wait for, until when, and how to format
/// the outcome. `condition == null` only for the fused op's
/// `wait_kind: "none"` — no wait at all; the caller answers immediately.
pub const WaitPlan = struct {
    condition: ?WaitCondition,
    /// Absolute timeout deadline (ms). `maxInt(i64)` means no timeout
    /// (fused `timeout_ms: 0`); `duration` conditions ignore it entirely.
    deadline: i64,
    format: WaitFormat,
};

/// Parse the wait-defining fields of a request into a `WaitPlan`,
/// preserving each op's historical field names, defaults, and parse
/// order. Shared by the blocking handlers below (which feed the plan to
/// `runWait`) and the event loop (which parks a waiter with it). A
/// compiled regex in the returned condition is owned by the caller —
/// free it with `freeWaitConditionRegex`.
pub fn planWait(
    arena: Allocator,
    kind: WaitOpKind,
    object: std.json.ObjectMap,
    start_ms: i64,
) !WaitPlan {
    switch (kind) {
        .text => {
            const needle = try readRequiredString(object, "text");
            const use_regex = try readOptionalBool(object, "regex", false);
            const timeout_ms = try readOptionalU64(object, "timeout_ms", 10_000);
            const compiled: ?*HtyRegex = if (use_regex) try compileWaitRegex(arena, needle) else null;
            return .{
                .condition = .{
                    .text = .{
                        .needle = needle,
                        .regex = compiled,
                        // Historical wire shape: the standalone op reports
                        // matched="text" even in regex mode.
                        .matched_label = "text",
                    },
                },
                .deadline = start_ms + @as(i64, @intCast(timeout_ms)),
                .format = .standalone,
            };
        },
        .idle => {
            const idle_ms_field = try readOptionalU64(object, "idle_ms", 250);
            const timeout_ms = try readOptionalU64(object, "timeout_ms", 10_000);
            return .{
                .condition = .{ .idle = .{
                    .idle_ms = @intCast(idle_ms_field),
                    .floor_ms = null,
                } },
                .deadline = start_ms + @as(i64, @intCast(timeout_ms)),
                .format = .standalone,
            };
        },
        .exit => {
            const timeout_ms = try readOptionalU64(object, "timeout_ms", 10_000);
            return .{
                .condition = .exit,
                .deadline = start_ms + @as(i64, @intCast(timeout_ms)),
                .format = .standalone,
            };
        },
        .fused => {
            const wait_kind_opt = try readOptionalString(object, "wait_kind");
            const wait_kind = wait_kind_opt orelse "none";
            const include_snapshot = try readOptionalBool(object, "snapshot", false);
            const timeout_ms_field = try readOptionalU64(object, "timeout_ms", 30_000);
            const format: WaitFormat = if (include_snapshot) .fused_snapshot else .fused_bare;
            // timeout_ms == 0 means "no timeout" — pin the deadline at the
            // largest representable value so the wait never trips it.
            const deadline: i64 = if (timeout_ms_field == 0)
                std.math.maxInt(i64)
            else
                start_ms + @as(i64, @intCast(timeout_ms_field));

            if (std.mem.eql(u8, wait_kind, "none")) {
                return .{ .condition = null, .deadline = deadline, .format = format };
            }
            const condition: WaitCondition = blk: {
                if (std.mem.eql(u8, wait_kind, "duration")) {
                    break :blk .{ .duration = try readOptionalU64(object, "duration_ms", 0) };
                }
                if (std.mem.eql(u8, wait_kind, "idle")) {
                    const idle_ms_field = try readOptionalU64(object, "idle_ms", 100);
                    // Race fix: if the session was already idle before this
                    // op started, treat op-start as the idle reference.
                    break :blk .{ .idle = .{ .idle_ms = @intCast(idle_ms_field), .floor_ms = start_ms } };
                }
                if (std.mem.eql(u8, wait_kind, "text") or std.mem.eql(u8, wait_kind, "regex")) {
                    const needle = try readRequiredString(object, "text");
                    const use_regex = std.mem.eql(u8, wait_kind, "regex");
                    const compiled: ?*HtyRegex = if (use_regex) try compileWaitRegex(arena, needle) else null;
                    break :blk .{ .text = .{
                        .needle = needle,
                        .regex = compiled,
                        .matched_label = if (use_regex) "regex" else "text",
                    } };
                }
                if (std.mem.eql(u8, wait_kind, "exit")) {
                    break :blk .exit;
                }
                return error.InvalidFieldValue;
            };
            return .{ .condition = condition, .deadline = deadline, .format = format };
        },
    }
}

/// Free the compiled regex a `planWait` condition may own. Safe on every
/// condition kind; a no-op when there is nothing to free.
pub fn freeWaitConditionRegex(condition: WaitCondition) void {
    switch (condition) {
        .text => |cfg| if (cfg.regex) |re| hty_regex_free(re),
        else => {},
    }
}

/// Encode a completed wait (match, exit, duration, or timeout) into the
/// wire bytes of its surface's response shape. Used by the event loop to
/// answer parked waiters; the returned line is owned by the caller. Any
/// memory `result` references (e.g. the duped needle) only needs to stay
/// alive for the duration of this call — the encoded line is a full copy.
pub fn encodeWaitOutcome(
    alloc: Allocator,
    id: ?i64,
    sess: *Session,
    format: WaitFormat,
    result: WaitResult,
) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const response = switch (format) {
        .standalone => try standaloneWaitResponse(arena, id, sess, result),
        .fused_bare, .fused_snapshot => try buildFusedResponse(
            arena,
            id,
            sess,
            format == .fused_snapshot,
            result.matched,
            result.elapsed_ms,
            result.timed_out,
            result.text,
            result.exit,
        ),
    };
    return encodeResponse(alloc, response);
}

/// Per-waiter evaluation state carried between `evaluateWaitCondition`
/// calls. One instance lives for the lifetime of a wait — on `runWait`'s
/// stack for in-process dispatch, or in the event loop's waiter table for
/// parked connections — and holds everything a re-evaluation needs
/// besides the condition itself.
pub const WaitState = struct {
    /// When the wait began; the reference point for `duration` conditions
    /// and for `elapsed_ms` in every outcome.
    start_ms: i64,
    /// Screen-change stamp observed by the most recent text scan. Snapshots
    /// are the expensive part of a text poll, and the screen usually hasn't
    /// changed between evaluations — re-scan only when the stamp moved
    /// since the previous scan (the caller's drain is what bumps it). Null
    /// means "never scanned", so the first evaluation always scans.
    last_scanned_change: ?i64 = null,
    /// Sessions spawned with `emit_screen_updates: false` never bump the
    /// change stamp, so for those every evaluation scans unconditionally.
    track_screen_changes: bool,

    pub fn init(sess: *const Session, start_ms: i64) WaitState {
        return .{
            .start_ms = start_ms,
            .track_screen_changes = sess.terminal.config.emit_screen_updates,
        };
    }
};

/// Evaluate one wait condition against current session state, returning
/// the outcome when satisfied or null when the wait should continue.
///
/// Pure and loop-agnostic by design: no sleeps, no drains, no deadline
/// bookkeeping, and no I/O beyond session snapshot/status reads. The
/// caller owns the schedule — when to drain, when to re-evaluate, and
/// when to give up. In-process dispatch calls it from `runWait`'s 25ms
/// poll shell; the server's event loop calls it from the waiter table
/// after each housekeeping drain and on deadline expiry.
pub fn evaluateWaitCondition(
    arena: Allocator,
    condition: WaitCondition,
    sess: *Session,
    state: *WaitState,
) !?WaitResult {
    switch (condition) {
        .duration => |duration_ms| {
            const now = std.time.milliTimestamp();
            if (now - state.start_ms >= @as(i64, @intCast(duration_ms))) {
                return .{
                    .matched = "duration",
                    .elapsed_ms = now - state.start_ms,
                };
            }
        },
        .idle => |cfg| {
            const reference = if (cfg.floor_ms) |floor|
                @max(sess.getLastScreenChange(), floor)
            else
                sess.getLastScreenChange();
            const since = std.time.milliTimestamp() - reference;
            if (since >= cfg.idle_ms) {
                return .{
                    .matched = "idle",
                    .elapsed_ms = std.time.milliTimestamp() - state.start_ms,
                };
            }
        },
        .text => |cfg| {
            // Read the stamp *before* snapshotting: output that lands
            // in between is scanned now with an older stamp recorded,
            // so the next drain's newer stamp forces a re-scan — we
            // may scan once redundantly, but never miss a change.
            const change_stamp = sess.getLastScreenChange();
            const unchanged = state.track_screen_changes and
                state.last_scanned_change != null and
                state.last_scanned_change.? == change_stamp;
            if (!unchanged) {
                state.last_scanned_change = change_stamp;

                // Polling uses the cheap plain-text snapshot; the full
                // snapshot (ANSI render, cells grid, normalizer) is
                // built once by the response formatter on completion.
                const buffer = try sess.terminal.plainSnapshot();
                defer sess.alloc.free(buffer);

                // Capture the byte offset of the match during the first
                // (and only) scan so regex callers get a uniform
                // `text.offset` field. The regex helper returns the offset
                // directly from `regexec`'s pmatch[0], so this doesn't
                // cost a second pattern execution — it's the same call
                // that decides match-vs-no-match.
                const offset: ?i64 = if (cfg.regex) |re| blk: {
                    break :blk try regexFindHaystack(sess.alloc, re, buffer);
                } else blk: {
                    const idx = std.mem.indexOf(u8, buffer, cfg.needle);
                    break :blk if (idx) |i| @as(i64, @intCast(i)) else null;
                };
                if (offset) |off| {
                    return .{
                        .matched = cfg.matched_label,
                        .elapsed_ms = std.time.milliTimestamp() - state.start_ms,
                        .text = .{ .needle = try arena.dupe(u8, cfg.needle), .offset = off },
                    };
                }
            }
        },
        .exit => {
            if (sess.getStatus() != .running) {
                return .{
                    .matched = "exit",
                    .elapsed_ms = std.time.milliTimestamp() - state.start_ms,
                    .exit = .{ .code = sess.getExitCode() orelse 0 },
                };
            }
        },
    }
    return null;
}

/// The single deadline-loop / drain / poll shell shared by all wait ops:
/// loop { check deadline; drainAll; evaluateWaitCondition; sleep 25ms }.
/// All condition checking lives in `evaluateWaitCondition`; this shell
/// only owns the schedule and the two lifecycle policies below.
///
/// Only the in-process dispatch path (`processRequestLine`, used by
/// single-threaded tests) still blocks here — the socket server parks
/// waits in its event loop's waiter table instead. Drain before each
/// sleep: in-process callers have no server loop, so the wait handlers
/// remain the only thing flushing events into the log and updating
/// session state on that path.
///
/// `duration` conditions are a plain sleep on the wire, not a poll of
/// session state, so two policies don't apply to them (historical
/// semantics, preserved exactly): they never time out (the fused op's
/// `duration` kind ignores the deadline) and they never observe session
/// dooming — a duration wait completes even if the session is deleted
/// mid-sleep.
fn runWait(
    arena: Allocator,
    registry: *SessionRegistry,
    sess: *Session,
    condition: WaitCondition,
    start_ms: i64,
    deadline: i64,
) !WaitResult {
    var state = WaitState.init(sess, start_ms);
    const is_duration = condition == .duration;

    while (true) {
        if (!is_duration and std.time.milliTimestamp() > deadline) {
            return .{
                .timed_out = true,
                .elapsed_ms = std.time.milliTimestamp() - start_ms,
            };
        }

        registry.drainAll();

        if (try evaluateWaitCondition(arena, condition, sess, &state)) |result| {
            return result;
        }

        // A concurrent `hty delete` (or the `--remove` sweep inside the
        // drainAll above) unpublished this session while we were waiting.
        // Our borrow keeps the memory valid, but the session is gone for
        // every observable purpose — surface the same structured error a
        // fresh resolve would, instead of polling a corpse until timeout.
        // Checked *after* the condition so a wait that was satisfied on
        // the same drain tick that doomed the session (e.g. wait_for_exit
        // on a `--remove` session) still reports its success.
        if (!is_duration and sess.isDoomed()) return error.SessionNotFound;

        std.Thread.sleep(25 * std.time.ns_per_ms);
    }
}

/// Format a standalone `wait_for_*` op's response from a `WaitResult`,
/// preserving each op's historical wire shape: text/idle successes carry a
/// snapshot payload, exit successes carry an `event` payload instead, and
/// timeouts carry only the wait payload.
fn standaloneWaitResponse(
    arena: Allocator,
    id: ?i64,
    sess: *Session,
    result: WaitResult,
) !Response {
    const sid = try arena.dupe(u8, &sess.id);
    if (result.timed_out) {
        return .{
            .id = id,
            .ok = true,
            .timed_out = true,
            .wait = .{
                .matched = null,
                .elapsed_ms = result.elapsed_ms,
                .session = sid,
                .timeout = true,
            },
        };
    }
    if (result.exit) |exit_info| {
        return .{
            .id = id,
            .ok = true,
            .event = .{ .kind = "exited", .code = exit_info.code },
            .wait = .{
                .matched = result.matched,
                .elapsed_ms = result.elapsed_ms,
                .session = sid,
                .exit = exit_info,
            },
        };
    }
    var snapshot = try sess.terminal.snapshot();
    defer snapshot.deinit(sess.alloc);
    return try snapshotResponseWithWait(arena, id, snapshot, sess, .{
        .matched = result.matched,
        .elapsed_ms = result.elapsed_ms,
        .session = sid,
        .text = result.text,
    });
}

/// Shared body of the three standalone `wait_for_*` handlers: parse the
/// request into a `WaitPlan`, run the blocking wait shell, format the
/// standalone response. (The event loop bypasses this — it calls
/// `planWait` itself and parks a waiter instead of blocking.)
fn runStandaloneWait(
    arena: Allocator,
    registry: *SessionRegistry,
    sess: *Session,
    object: std.json.ObjectMap,
    id: ?i64,
    kind: WaitOpKind,
) !Response {
    const start_ms = std.time.milliTimestamp();
    const plan = try planWait(arena, kind, object, start_ms);
    const condition = plan.condition.?; // standalone kinds always wait
    defer freeWaitConditionRegex(condition);

    const result = try runWait(arena, registry, sess, condition, start_ms, plan.deadline);
    return try standaloneWaitResponse(arena, id, sess, result);
}

pub fn handleWaitForText(
    arena: Allocator,
    registry: *SessionRegistry,
    sess: *Session,
    object: std.json.ObjectMap,
    id: ?i64,
) !Response {
    return runStandaloneWait(arena, registry, sess, object, id, .text);
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
    return runStandaloneWait(arena, registry, sess, object, id, .idle);
}

pub fn handleWaitForExit(
    arena: Allocator,
    registry: *SessionRegistry,
    sess: *Session,
    object: std.json.ObjectMap,
    id: ?i64,
) !Response {
    return runStandaloneWait(arena, registry, sess, object, id, .exit);
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
    const start_ms = std.time.milliTimestamp();
    const plan = try planWait(arena, .fused, object, start_ms);
    const include_snapshot = plan.format == .fused_snapshot;

    const condition = plan.condition orelse
        return try buildFusedResponse(arena, id, sess, include_snapshot, null, 0, false, null, null);
    defer freeWaitConditionRegex(condition);

    const result = try runWait(arena, registry, sess, condition, start_ms, plan.deadline);
    return try buildFusedResponse(
        arena,
        id,
        sess,
        include_snapshot,
        result.matched,
        result.elapsed_ms,
        result.timed_out,
        result.text,
        result.exit,
    );
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
        // Stamp the terminal timestamp so the drain-loop auto-remove
        // sweep can reap this session if it was spawned with `--remove`.
        // A no-op for sessions without `remove_on_exit`.
        sess.markTerminal(std.time.milliTimestamp());
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
