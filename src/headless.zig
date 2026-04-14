const std = @import("std");
const hty = @import("hty");

const Allocator = std.mem.Allocator;

const resolveSocketPath = @import("paths.zig").resolveSocketPath;
const resolveLogDir = @import("paths.zig").resolveLogDir;
const ensureOwnedDir = @import("paths.zig").ensureOwnedDir;

const encodeHex = @import("hex.zig").encodeHex;
const decodeHex = @import("hex.zig").decodeHex;

const generateUuidV7 = @import("uuid.zig").generateUuidV7;
const shortestUniquePrefixLen = @import("uuid.zig").shortestUniquePrefixLen;

const readOptionalId = @import("json.zig").readOptionalId;
const readRequiredString = @import("json.zig").readRequiredString;
const readOptionalString = @import("json.zig").readOptionalString;
const readOptionalBool = @import("json.zig").readOptionalBool;
const readOptionalU64 = @import("json.zig").readOptionalU64;
const readOptionalUsize = @import("json.zig").readOptionalUsize;
const readRequiredU16 = @import("json.zig").readRequiredU16;
const readOptionalU16 = @import("json.zig").readOptionalU16;
const readStringArray = @import("json.zig").readStringArray;
const readEnvArray = @import("json.zig").readEnvArray;
const getString = @import("json.zig").getString;
const getInteger = @import("json.zig").getInteger;

const keyToBytes = @import("keys.zig").keyToBytes;

const help_text = @import("help_text.zig");
const helpForTopic = help_text.helpForTopic;
const generalHelpText = help_text.generalHelpText;

const protocol = @import("protocol.zig");
const Response = protocol.Response;
const SnapshotPayload = protocol.SnapshotPayload;
const EventPayload = protocol.EventPayload;
const SessionSummary = protocol.SessionSummary;
const encodeResponse = protocol.encodeResponse;
const requestErrorMessage = protocol.requestErrorMessage;

const session_mod = @import("session.zig");
const SessionStatus = session_mod.SessionStatus;
const Session = session_mod.Session;
const AttachClient = session_mod.AttachClient;
const statusName = session_mod.statusName;

const log_mod = @import("log.zig");
const writeLogEvent = log_mod.writeLogEvent;
const closeLogFile = log_mod.closeLogFile;
const openSessionLog = log_mod.openSessionLog;
const logDrainedEvent = log_mod.logDrainedEvent;
const logInputEvent = log_mod.logInputEvent;
const logKilledEvent = log_mod.logKilledEvent;
const logResizeEvent = log_mod.logResizeEvent;

const attach = @import("attach.zig");
const broadcastRawBytesToAttach = attach.broadcastRawBytesToAttach;
const broadcastExitedToAttach = attach.broadcastExitedToAttach;
const reapClosedAttachClients = attach.reapClosedAttachClients;

const SessionRegistry = @import("registry.zig").SessionRegistry;

const server_attach = @import("server_attach.zig");
const ConnectionResult = server_attach.ConnectionResult;
const handleAttachConnection = server_attach.handleAttachConnection;
const detectAttachOp = server_attach.detectAttachOp;
const attachReaderLoop = server_attach.attachReaderLoop;
const dispatchAttachFrame = server_attach.dispatchAttachFrame;
const writeAttachAck = server_attach.writeAttachAck;
const writeAttachError = server_attach.writeAttachError;

const server = @import("server.zig");
const runServer = server.runServer;
const handleConnection = server.handleConnection;
const processRequestLine = server.processRequestLine;
const dispatchRequest = server.dispatchRequest;

const ensure = @import("ensure.zig");
const ensureServer = ensure.ensureServer;
const tryConnect = ensure.tryConnect;
const spawnServer = ensure.spawnServer;

const ops = @import("ops.zig");
const handleSpawn = ops.handleSpawn;
const handleList = ops.handleList;
const handleSnapshot = ops.handleSnapshot;
const handleSendText = ops.handleSendText;
const handleSendKey = ops.handleSendKey;
const handleSendBytesHex = ops.handleSendBytesHex;
const handleResize = ops.handleResize;
const handleWaitForText = ops.handleWaitForText;
const handleWaitForIdle = ops.handleWaitForIdle;
const handleWaitForExit = ops.handleWaitForExit;
const handleKill = ops.handleKill;
const handleDelete = ops.handleDelete;
const snapshotResponse = ops.snapshotResponse;
const buildSessionSummary = ops.buildSessionSummary;
const joinArgs = ops.joinArgs;
const eventToPayload = ops.eventToPayload;

const common = @import("commands/common.zig");
const sendRequest = common.sendRequest;
const sendRawRequest = common.sendRawRequest;
const printJsonLine = common.printJsonLine;
const printLine = common.printLine;
const printRaw = common.printRaw;
const printErr = common.printErr;
const printErrFmt = common.printErrFmt;
const expectOkOrExit = common.expectOkOrExit;
const errorToExitCode = common.errorToExitCode;
const printUsageAndExit = common.printUsageAndExit;
const writeJsonString = common.writeJsonString;
const ExitCode = common.ExitCode;

// Force Zig's test discovery to walk the extracted modules even when the root
// file only references specific decls from them.
comptime {
    _ = @import("help_text.zig");
    _ = @import("keys.zig");
    _ = @import("uuid.zig");
    _ = @import("commands/send.zig");
}

const c = @cImport({
    @cInclude("poll.h");
    @cInclude("unistd.h");
    @cInclude("fcntl.h");
    @cInclude("sys/stat.h");
    @cInclude("sys/ioctl.h");
    @cInclude("time.h");
});

/// Suppress std.log output below error level across the whole binary.
/// The Ghostty VT parser emits warn-level messages when it hits escape
/// sequences it doesn't implement (e.g. the non-standard "CSI m with
/// intermediate: 63" vim occasionally sends). Those go to stderr, and
/// for the replay / watch / attach clients stderr is the user's
/// terminal — the warnings land right on top of the rendered frame.
/// The server redirects stdio to /dev/null so raising the level there
/// costs nothing; raising it for the clients fixes the visual glitch.
pub const std_options: std.Options = .{
    .log_level = .err,
};

// ============================================================================
// Client subcommands
// ============================================================================

const run_cmd = @import("commands/run.zig");
const runClientRun = run_cmd.run;

const list_cmd = @import("commands/list.zig");
const runClientList = list_cmd.run;

const kill_cmd = @import("commands/kill.zig");
const runClientKill = kill_cmd.run;

fn runClientDelete(alloc: Allocator, args: []const []const u8) !void {
    const session_ref = if (args.len > 0) args[0] else null;

    // First try the server — it owns any live or zombie sessions in the
    // current registry and will cleanly kill + unlink them.
    var payload_buf = std.array_list.Managed(u8).init(alloc);
    defer payload_buf.deinit();
    try payload_buf.appendSlice("{\"op\":\"delete\"");
    if (session_ref) |s| {
        try payload_buf.appendSlice(",\"session\":");
        try writeJsonString(payload_buf.writer().any(), s);
    }
    try payload_buf.appendSlice("}");

    var server_ok = false;
    if (sendRawRequest(alloc, payload_buf.items)) |response_line| {
        defer alloc.free(response_line);
        var parsed = std.json.parseFromSlice(std.json.Value, alloc, response_line, .{}) catch null;
        defer if (parsed) |*p| p.deinit();
        if (parsed) |*p| {
            if (p.value == .object) {
                if (p.value.object.get("ok")) |ok_val| {
                    if (ok_val == .bool and ok_val.bool) server_ok = true;
                }
            }
        }
    } else |_| {}

    if (server_ok) {
        const display = session_ref orelse "session";
        const msg = try std.fmt.allocPrint(alloc, "deleted {s}", .{display});
        defer alloc.free(msg);
        try printLine(msg);
        return;
    }

    // Server didn't know about it (orphan from a prior server instance,
    // or server unreachable). Unlink the log file and symlink directly.
    const ref = session_ref orelse {
        try printErr("hty delete: session not found");
        std.process.exit(ExitCode.not_found);
    };

    const path = resolveLogPath(alloc, ref) catch |err| {
        switch (err) {
            error.SessionNotFound => try printErr("hty delete: session not found"),
            error.AmbiguousPrefix => try printErr("hty delete: ambiguous session prefix"),
            error.AmbiguousSole => try printErr("hty delete: more than one session exists — name one explicitly"),
            else => try printErrFmt("hty delete: {s}", .{@errorName(err)}),
        }
        std.process.exit(ExitCode.not_found);
    };
    defer alloc.free(path);

    // `path` may be the by-name symlink or a direct UUID file. Resolve
    // it to the canonical UUID file so we can delete both it and the
    // symlink (if any) cleanly.
    const real_path = std.fs.realpathAlloc(alloc, path) catch try alloc.dupe(u8, path);
    defer alloc.free(real_path);

    std.fs.deleteFileAbsolute(real_path) catch |err| {
        try printErrFmt("hty delete: failed to unlink {s}: {s}", .{ real_path, @errorName(err) });
        std.process.exit(ExitCode.generic);
    };
    // Also remove the name symlink if the reference was a name.
    if (!std.mem.eql(u8, path, real_path)) {
        std.fs.deleteFileAbsolute(path) catch {};
    }

    const msg = try std.fmt.allocPrint(alloc, "deleted {s} (log file unlinked)", .{ref});
    defer alloc.free(msg);
    try printLine(msg);
}

const send_cmd = @import("commands/send.zig");
const runClientSend = send_cmd.run;

const snapshot_cmd = @import("commands/snapshot.zig");
const runClientSnapshot = snapshot_cmd.run;

const wait_cmd = @import("commands/wait.zig");
const runClientWait = wait_cmd.run;

const watch_cmd = @import("commands/watch.zig");
const runClientWatch = watch_cmd.run;
const enterAltScreen = watch_cmd.enterAltScreen;
const leaveAltScreen = watch_cmd.leaveAltScreen;

const attach_cmd = @import("commands/attach.zig");
const runClientAttach = attach_cmd.run;


// ============================================================================
// hty replay
// ============================================================================

const ReplayOptions = struct {
    session: ?[]const u8 = null,
    speed: f64 = 1.0,
    at_ms: ?u64 = null,
    to_ms: ?u64 = null,
    loop: bool = false,
};

const LoggedEvent = struct {
    t: i64,
    kind: []const u8,
    bytes: ?[]const u8 = null,
    rows: ?u16 = null,
    cols: ?u16 = null,
};

fn runClientReplay(alloc: Allocator, args: []const []const u8) !void {
    var opts = ReplayOptions{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--speed")) {
            i += 1;
            if (i >= args.len) printUsageAndExit("--speed requires an argument");
            opts.speed = std.fmt.parseFloat(f64, trimSpeedSuffix(args[i])) catch {
                printUsageAndExit("--speed must be a number (e.g. 1, 2x, 0.5)");
            };
            if (opts.speed <= 0) opts.speed = 0; // 0 = no sleep
        } else if (std.mem.eql(u8, arg, "--at")) {
            i += 1;
            if (i >= args.len) printUsageAndExit("--at requires an argument");
            opts.at_ms = parseDurationMs(args[i]) catch {
                printUsageAndExit("--at value is not a valid duration (examples: 5s, 1m, 500ms)");
            };
        } else if (std.mem.eql(u8, arg, "--to")) {
            i += 1;
            if (i >= args.len) printUsageAndExit("--to requires an argument");
            opts.to_ms = parseDurationMs(args[i]) catch {
                printUsageAndExit("--to value is not a valid duration");
            };
        } else if (std.mem.eql(u8, arg, "--loop")) {
            opts.loop = true;
        } else if (std.mem.startsWith(u8, arg, "--")) {
            printUsageAndExit("unknown flag for `hty replay`");
        } else {
            if (opts.session != null) printUsageAndExit("only one session argument is allowed");
            opts.session = arg;
        }
    }

    const path = resolveLogPath(alloc, opts.session) catch |err| {
        switch (err) {
            error.SessionNotFound => try printErr("session log not found"),
            error.AmbiguousPrefix => try printErr("ambiguous session prefix"),
            error.AmbiguousSole => try printErr("more than one session log exists — name one explicitly"),
            else => try printErrFmt("failed to resolve session log: {s}", .{@errorName(err)}),
        }
        std.process.exit(ExitCode.not_found);
    };
    defer alloc.free(path);

    const file = std.fs.openFileAbsolute(path, .{ .mode = .read_only }) catch |err| {
        try printErrFmt("cannot open {s}: {s}", .{ path, @errorName(err) });
        std.process.exit(ExitCode.generic);
    };
    defer file.close();

    const bytes = file.readToEndAlloc(alloc, 64 * 1024 * 1024) catch |err| {
        try printErrFmt("read failed: {s}", .{@errorName(err)});
        std.process.exit(ExitCode.generic);
    };
    defer alloc.free(bytes);

    // First pass: parse the spawn line for dimensions.
    var line_it = std.mem.splitScalar(u8, bytes, '\n');
    var rows: u16 = 24;
    var cols: u16 = 80;
    var first_t: ?i64 = null;
    const spawn_line = line_it.next() orelse {
        try printErr("log file is empty");
        std.process.exit(ExitCode.generic);
    };
    {
        var parsed = std.json.parseFromSlice(std.json.Value, alloc, spawn_line, .{}) catch {
            try printErr("log file is missing a valid spawn event on line 1");
            std.process.exit(ExitCode.generic);
        };
        defer parsed.deinit();
        if (parsed.value == .object) {
            const obj = parsed.value.object;
            if (getInteger(obj, "rows")) |r| rows = @intCast(r);
            if (getInteger(obj, "cols")) |c_| cols = @intCast(c_);
            if (getInteger(obj, "t")) |t| first_t = t;
        }
    }
    if (first_t == null) {
        try printErr("log file is missing a timestamp on line 1");
        std.process.exit(ExitCode.generic);
    }

    // Setup alt-screen + raw mode (so Ctrl-C leaves cleanly).
    const stdin_fd = std.posix.STDIN_FILENO;
    const stdout_fd = std.posix.STDOUT_FILENO;
    const stdin_is_tty = std.posix.isatty(stdin_fd);

    try enterAltScreen(stdout_fd);
    defer leaveAltScreen(stdout_fd);

    const saved_termios: ?std.posix.termios = if (stdin_is_tty)
        std.posix.tcgetattr(stdin_fd) catch null
    else
        null;
    if (saved_termios) |st| {
        var raw = st;
        raw.iflag.BRKINT = false;
        raw.iflag.ICRNL = false;
        raw.iflag.INPCK = false;
        raw.iflag.ISTRIP = false;
        raw.iflag.IXON = false;
        raw.lflag.ECHO = false;
        raw.lflag.ICANON = false;
        raw.lflag.IEXTEN = false;
        raw.lflag.ISIG = false;
        raw.cc[@intFromEnum(std.c.V.MIN)] = 0;
        raw.cc[@intFromEnum(std.c.V.TIME)] = 0;
        std.posix.tcsetattr(stdin_fd, .FLUSH, raw) catch {};
    }
    defer if (saved_termios) |st| std.posix.tcsetattr(stdin_fd, .FLUSH, st) catch {};

    replayLoop(alloc, bytes, rows, cols, first_t.?, opts) catch |err| {
        try printErrFmt("replay failed: {s}", .{@errorName(err)});
        std.process.exit(ExitCode.generic);
    };
}

/// Pure-VT replay result. Owns the terminal — caller must `deinit`.
/// `rows`/`cols` reflect the final resize state (initial if none occurred).
pub const ReplayResult = struct {
    terminal: hty.ghostty_vt.Terminal,
    rows: u16,
    cols: u16,

    pub fn deinit(self: *ReplayResult, alloc: Allocator) void {
        self.terminal.deinit(alloc);
        self.* = undefined;
    }
};

/// Apply one parsed JSONL log event to a VT terminal. Returns true iff the
/// event was "visible" (output or resize) — i.e. the grid may have changed.
/// Other kinds (title, bell, input, killed, failure, exited) are ignored.
///
/// Shared between `replayLoop` (the CLI viewer) and `replayToTerminal` (the
/// headless helper) so both agree on what a log event does to the grid.
fn applyLogEvent(
    alloc: Allocator,
    obj: std.json.ObjectMap,
    terminal: *hty.ghostty_vt.Terminal,
    stream: *hty.ghostty_vt.TerminalStream,
    cur_rows: *u16,
    cur_cols: *u16,
) !bool {
    const kind_val = obj.get("kind") orelse return false;
    if (kind_val != .string) return false;
    const kind = kind_val.string;

    if (std.mem.eql(u8, kind, "output")) {
        const hex = getString(obj, "bytes_hex") orelse return false;
        const decoded = decodeHex(alloc, hex) catch return false;
        defer alloc.free(decoded);
        stream.nextSlice(decoded);
        return true;
    } else if (std.mem.eql(u8, kind, "resize")) {
        const nr = getInteger(obj, "rows") orelse return false;
        const nc = getInteger(obj, "cols") orelse return false;
        cur_rows.* = @intCast(nr);
        cur_cols.* = @intCast(nc);
        try terminal.resize(alloc, cur_cols.*, cur_rows.*);
        return true;
    }
    return false;
}

/// Feed a session log into a fresh VT engine and return the resulting state.
/// Pure: no sleeps, no stdout, no stdin. The first line (spawn event) is
/// skipped — its `rows`/`cols` should be parsed by the caller and passed as
/// `initial_rows` / `initial_cols`. Malformed lines are tolerated (skipped).
///
/// Intended for tests that assert replay produces the same grid as the live
/// session that recorded the log.
pub fn replayToTerminal(
    alloc: Allocator,
    bytes: []const u8,
    initial_rows: u16,
    initial_cols: u16,
) !ReplayResult {
    var terminal = try hty.ghostty_vt.Terminal.init(alloc, .{
        .cols = initial_cols,
        .rows = initial_rows,
        .max_scrollback = 10_000,
    });
    errdefer terminal.deinit(alloc);

    const handler = terminal.vtHandler();
    var stream = hty.ghostty_vt.TerminalStream.initAlloc(alloc, handler);
    defer stream.deinit();

    var cur_rows: u16 = initial_rows;
    var cur_cols: u16 = initial_cols;

    var it = std.mem.splitScalar(u8, bytes, '\n');
    _ = it.next(); // skip spawn line (dimensions are passed in explicitly)

    while (it.next()) |line| {
        if (line.len == 0) continue;

        var parsed = std.json.parseFromSlice(std.json.Value, alloc, line, .{}) catch continue;
        defer parsed.deinit();
        if (parsed.value != .object) continue;

        _ = applyLogEvent(alloc, parsed.value.object, &terminal, &stream, &cur_rows, &cur_cols) catch continue;
    }

    return .{ .terminal = terminal, .rows = cur_rows, .cols = cur_cols };
}

fn replayLoop(
    alloc: Allocator,
    bytes: []const u8,
    initial_rows: u16,
    initial_cols: u16,
    first_t: i64,
    opts: ReplayOptions,
) !void {
    const stdin_fd = std.posix.STDIN_FILENO;
    const stdout_fd = std.posix.STDOUT_FILENO;

    const at_threshold: i64 = first_t + @as(i64, @intCast(opts.at_ms orelse 0));
    const to_threshold: ?i64 = if (opts.to_ms) |v| first_t + @as(i64, @intCast(v)) else null;

    while (true) {
        var terminal = try hty.ghostty_vt.Terminal.init(alloc, .{
            .cols = initial_cols,
            .rows = initial_rows,
            .max_scrollback = 10_000,
        });
        defer terminal.deinit(alloc);

        const handler = terminal.vtHandler();
        var stream = hty.ghostty_vt.TerminalStream.initAlloc(alloc, handler);
        defer stream.deinit();

        var cur_rows: u16 = initial_rows;
        var cur_cols: u16 = initial_cols;

        var prev_t: ?i64 = null;
        var it = std.mem.splitScalar(u8, bytes, '\n');
        // Skip the spawn line, already parsed.
        _ = it.next();

        _ = try std.posix.write(stdout_fd, "\x1b[2J\x1b[H");

        while (it.next()) |line| {
            if (line.len == 0) continue;

            if (checkCtrlCFromStdin(stdin_fd)) return;

            var parsed = std.json.parseFromSlice(std.json.Value, alloc, line, .{}) catch continue;
            defer parsed.deinit();
            if (parsed.value != .object) continue;
            const obj = parsed.value.object;

            const t = getInteger(obj, "t") orelse continue;
            if (to_threshold) |tt| if (t > tt) break;

            const kind_val = obj.get("kind") orelse continue;
            if (kind_val != .string) continue;

            const past_at = t >= at_threshold;

            // Sleep between events (only once we're past --at, so we don't
            // wait real-time while fast-forwarding).
            if (past_at and prev_t != null and opts.speed > 0) {
                const dt_ms = t - prev_t.?;
                if (dt_ms > 0) {
                    const dt_ns = @as(u64, @intCast(dt_ms)) * std.time.ns_per_ms;
                    const scaled = @as(u64, @intFromFloat(@as(f64, @floatFromInt(dt_ns)) / opts.speed));
                    std.Thread.sleep(scaled);
                }
            }
            prev_t = t;

            const visible = try applyLogEvent(alloc, obj, &terminal, &stream, &cur_rows, &cur_cols);
            if (visible and past_at) try paintFrame(alloc, &terminal, cur_rows, cur_cols);
        }

        // End-of-log: without --loop, hold on the final frame until the
        // viewer hits Ctrl-C / Ctrl-Q. This matches the expectation that
        // replay is a post-mortem viewer, not a transient playback.
        if (!opts.loop) {
            while (true) {
                if (checkCtrlCFromStdin(stdin_fd)) return;
                std.Thread.sleep(50 * std.time.ns_per_ms);
            }
        }
        std.Thread.sleep(500 * std.time.ns_per_ms);
    }
}

fn paintFrame(alloc: Allocator, terminal: *hty.ghostty_vt.Terminal, rows: u16, cols: u16) !void {
    const frame = hty.renderScreenAnsi(alloc, terminal, rows, cols) catch return;
    defer alloc.free(frame);
    const stdout_fd = std.posix.STDOUT_FILENO;
    _ = std.posix.write(stdout_fd, "\x1b[H") catch return;
    _ = std.posix.write(stdout_fd, frame) catch return;
}

fn checkCtrlCFromStdin(stdin_fd: std.posix.fd_t) bool {
    var poll_fd: c.pollfd = .{ .fd = stdin_fd, .events = c.POLLIN, .revents = 0 };
    if (c.poll(&poll_fd, 1, 0) <= 0) return false;
    if ((poll_fd.revents & c.POLLIN) == 0) return false;
    var buf: [32]u8 = undefined;
    const n = std.posix.read(stdin_fd, &buf) catch return false;
    for (buf[0..n]) |b| {
        if (b == 0x03 or b == 0x11) return true;
    }
    return false;
}

fn trimSpeedSuffix(text: []const u8) []const u8 {
    if (text.len > 0 and (text[text.len - 1] == 'x' or text[text.len - 1] == 'X')) {
        return text[0 .. text.len - 1];
    }
    return text;
}

// ============================================================================
// hty logs
// ============================================================================

const LogsOptions = struct {
    session: ?[]const u8 = null,
    follow: bool = false,
    since_ms: ?u64 = null,
    json: bool = false,
};

fn runClientLogs(alloc: Allocator, args: []const []const u8) !void {
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
            if (i >= args.len) printUsageAndExit("--since requires an argument");
            opts.since_ms = parseDurationMs(args[i]) catch {
                printUsageAndExit("--since value is not a valid duration (examples: 5s, 1m, 500ms, 30)");
            };
        } else if (std.mem.startsWith(u8, arg, "--")) {
            printUsageAndExit("unknown flag for `hty logs`");
        } else {
            if (opts.session != null) printUsageAndExit("only one session argument is allowed");
            opts.session = arg;
        }
    }

    const path = resolveLogPath(alloc, opts.session) catch |err| {
        switch (err) {
            error.SessionNotFound => try printErr("session log not found"),
            error.AmbiguousPrefix => try printErr("ambiguous session prefix"),
            error.AmbiguousSole => try printErr("more than one session log exists — name one explicitly"),
            else => try printErrFmt("failed to resolve session log: {s}", .{@errorName(err)}),
        }
        std.process.exit(ExitCode.not_found);
    };
    defer alloc.free(path);

    const file = std.fs.openFileAbsolute(path, .{ .mode = .read_only }) catch |err| {
        try printErrFmt("cannot open {s}: {s}", .{ path, @errorName(err) });
        std.process.exit(ExitCode.generic);
    };
    defer file.close();

    var buffered = std.array_list.Managed(u8).init(alloc);
    defer buffered.deinit();

    // Initial pass: read the whole file into memory. This keeps the filter
    // logic simple — we can't know the "last event timestamp" without seeing
    // every line, and even multi-megabyte logs are fine to load wholesale.
    const initial = file.readToEndAlloc(alloc, 64 * 1024 * 1024) catch |err| {
        try printErrFmt("read failed: {s}", .{@errorName(err)});
        std.process.exit(ExitCode.generic);
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
        try printLine("TIMESTAMP               KIND     DETAIL");
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
        try printLine(line);
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
    try printLine(line);
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

fn lastTimestampInJsonl(bytes: []const u8) ?i64 {
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

const parseDurationMs = common.parseDurationMs;

fn resolveLogPath(alloc: Allocator, reference: ?[]const u8) ![]u8 {
    const log_dir = try resolveLogDir(alloc);
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

fn fileExistsAbsolute(path: []const u8) bool {
    std.fs.accessAbsolute(path, .{}) catch return false;
    return true;
}

// ============================================================================
// Misc helpers
// ============================================================================

// ============================================================================
// Help text
// ============================================================================

fn writeHelp(args: []const []const u8) !void {
    if (args.len == 0) {
        try printRaw(generalHelpText());
        return;
    }

    if (helpForTopic(args[0])) |help| {
        try printRaw(help);
        return;
    }

    const alloc = std.heap.c_allocator;
    const message = try std.fmt.allocPrint(alloc, "unknown help topic: {s}\n\n{s}", .{ args[0], generalHelpText() });
    defer alloc.free(message);
    try printRaw(message);
}

const keys_cmd = @import("commands/keys.zig");
fn writeSupportedKeys() !void {
    try keys_cmd.run(std.heap.c_allocator, &.{});
}

const info_cmd = @import("commands/info.zig");
const runInfo = info_cmd.run;

fn writeUsageError(arg: []const u8) !void {
    const alloc = std.heap.c_allocator;
    const message = try std.fmt.allocPrint(alloc, "unknown subcommand: {s}\n\n{s}", .{ arg, generalHelpText() });
    defer alloc.free(message);
    var stderr = std.fs.File.stderr();
    _ = try stderr.writeAll(message);
}



// ============================================================================
// Entry point
// ============================================================================

pub fn main() !void {
    const alloc = std.heap.c_allocator;
    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);

    if (args.len < 2) {
        try printRaw(generalHelpText());
        return;
    }

    const verb = args[1];

    // Hidden server entry point.
    if (std.mem.eql(u8, verb, "__server__")) {
        if (args.len < 3) {
            try printErr("__server__ requires a socket path");
            std.process.exit(ExitCode.generic);
        }
        try runServer(alloc, args[2]);
        return;
    }

    if (std.mem.eql(u8, verb, "--help") or std.mem.eql(u8, verb, "-h") or std.mem.eql(u8, verb, "help")) {
        try writeHelp(args[2..]);
        return;
    }
    if (std.mem.eql(u8, verb, "keys")) {
        try writeSupportedKeys();
        return;
    }
    if (std.mem.eql(u8, verb, "info")) {
        try runInfo(alloc);
        return;
    }

    const subargs = args[2..];
    if (std.mem.eql(u8, verb, "run")) return runClientRun(alloc, subargs);
    if (std.mem.eql(u8, verb, "list")) return runClientList(alloc, subargs);
    if (std.mem.eql(u8, verb, "watch")) return runClientWatch(alloc, subargs);
    if (std.mem.eql(u8, verb, "send")) return runClientSend(alloc, subargs);
    if (std.mem.eql(u8, verb, "snapshot")) return runClientSnapshot(alloc, subargs);
    if (std.mem.eql(u8, verb, "wait")) return runClientWait(alloc, subargs);
    if (std.mem.eql(u8, verb, "kill")) return runClientKill(alloc, subargs);
    if (std.mem.eql(u8, verb, "delete")) return runClientDelete(alloc, subargs);
    if (std.mem.eql(u8, verb, "logs")) return runClientLogs(alloc, subargs);
    if (std.mem.eql(u8, verb, "replay")) return runClientReplay(alloc, subargs);
    if (std.mem.eql(u8, verb, "attach")) return runClientAttach(alloc, subargs);

    try writeUsageError(verb);
    std.process.exit(ExitCode.generic);
}

// ============================================================================
// Tests
// ============================================================================

test "detectAttachOp recognizes attach requests" {
    const alloc = std.testing.allocator;
    try std.testing.expect(detectAttachOp(alloc, "{\"op\":\"attach\",\"session\":\"foo\"}"));
    try std.testing.expect(detectAttachOp(alloc, "{\"op\":\"attach\"}"));
    try std.testing.expect(!detectAttachOp(alloc, "{\"op\":\"snapshot\"}"));
    try std.testing.expect(!detectAttachOp(alloc, "{\"op\":\"spawn\",\"program\":\"/bin/sh\"}"));
    try std.testing.expect(!detectAttachOp(alloc, "not json"));
    try std.testing.expect(!detectAttachOp(alloc, "[\"attach\"]"));
}

test "parseDurationMs accepts bare integers, ms, s, m, h" {
    try std.testing.expectEqual(@as(u64, 5_000), try parseDurationMs("5"));
    try std.testing.expectEqual(@as(u64, 500), try parseDurationMs("500ms"));
    try std.testing.expectEqual(@as(u64, 10_000), try parseDurationMs("10s"));
    try std.testing.expectEqual(@as(u64, 60_000), try parseDurationMs("1m"));
    try std.testing.expectEqual(@as(u64, 2 * 60 * 60 * 1000), try parseDurationMs("2h"));
    try std.testing.expectError(error.InvalidDuration, parseDurationMs(""));
    try std.testing.expectError(error.InvalidDuration, parseDurationMs("abc"));
    try std.testing.expectError(error.InvalidDuration, parseDurationMs("5d"));
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

test "trimSpeedSuffix strips trailing x" {
    try std.testing.expectEqualStrings("2", trimSpeedSuffix("2x"));
    try std.testing.expectEqualStrings("0.5", trimSpeedSuffix("0.5X"));
    try std.testing.expectEqualStrings("1", trimSpeedSuffix("1"));
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
}
