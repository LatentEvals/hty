//! `hty replay` — replay a recorded session log through a fresh VT engine.

const std = @import("std");
const sys = @import("hty").sys;
const Allocator = std.mem.Allocator;
const hty = @import("hty");

const common = @import("common.zig");
const logs = @import("logs.zig");
const watch = @import("watch.zig");
const json_mod = @import("../json.zig");
const getString = json_mod.getString;
const getInteger = json_mod.getInteger;
const decodeHex = @import("../hex.zig").decodeHex;

const c = @cImport({
    @cInclude("poll.h");
});

pub fn helpText() []const u8 {
    return
    \\hty replay [SESSION] [--speed Nx] [--at T] [--to T] [--loop]
    \\
    \\Replay a session by reading its log file and feeding the recorded
    \\output bytes back through a fresh in-memory VT engine. The program
    \\is NOT re-executed and no input is re-sent — replay is a pure
    \\visualization with zero side effects.
    \\
    \\Flags:
    \\  --speed Nx   Playback speed multiplier (default 1x). 0 = no sleep.
    \\  --at T       Fast-forward silently to T into the session before
    \\               painting (same duration syntax as --since).
    \\  --to T       Stop painting once the timeline reaches T.
    \\  --loop       Restart playback from the beginning when the log ends.
    \\
    \\Press Ctrl-C or Ctrl-Q to exit.
    \\
    ;
}

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

pub fn run(alloc: Allocator, io: std.Io, args: []const []const u8) !void {
    var opts = ReplayOptions{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--speed")) {
            i += 1;
            if (i >= args.len) common.printUsageAndExit("--speed requires an argument");
            opts.speed = std.fmt.parseFloat(f64, trimSpeedSuffix(args[i])) catch {
                common.printUsageAndExit("--speed must be a number (e.g. 1, 2x, 0.5)");
            };
            if (opts.speed <= 0) opts.speed = 0; // 0 = no sleep
        } else if (std.mem.eql(u8, arg, "--at")) {
            i += 1;
            if (i >= args.len) common.printUsageAndExit("--at requires an argument");
            opts.at_ms = common.parseDurationMs(args[i]) catch {
                common.printUsageAndExit("--at value is not a valid duration (examples: 5s, 1m, 500ms)");
            };
        } else if (std.mem.eql(u8, arg, "--to")) {
            i += 1;
            if (i >= args.len) common.printUsageAndExit("--to requires an argument");
            opts.to_ms = common.parseDurationMs(args[i]) catch {
                common.printUsageAndExit("--to value is not a valid duration");
            };
        } else if (std.mem.eql(u8, arg, "--loop")) {
            opts.loop = true;
        } else if (std.mem.startsWith(u8, arg, "--")) {
            common.printUsageAndExit("unknown flag for `hty replay`");
        } else {
            if (opts.session != null) common.printUsageAndExit("only one session argument is allowed");
            opts.session = arg;
        }
    }

    const path = logs.resolveLogPath(alloc, io, opts.session) catch |err| {
        switch (err) {
            error.SessionNotFound => try common.printErr("session log not found"),
            error.AmbiguousPrefix => try common.printErr("ambiguous session prefix"),
            error.AmbiguousSole => try common.printErr("more than one session log exists — name one explicitly"),
            else => try common.printErrFmt("failed to resolve session log: {s}", .{@errorName(err)}),
        }
        std.process.exit(common.ExitCode.not_found);
    };
    defer alloc.free(path);

    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(64 * 1024 * 1024)) catch |err| {
        try common.printErrFmt("cannot read {s}: {s}", .{ path, @errorName(err) });
        std.process.exit(common.ExitCode.generic);
    };
    defer alloc.free(bytes);

    // First pass: parse the spawn line for dimensions.
    var line_it = std.mem.splitScalar(u8, bytes, '\n');
    var rows: u16 = 24;
    var cols: u16 = 80;
    var first_t: ?i64 = null;
    const spawn_line = line_it.next() orelse {
        try common.printErr("log file is empty");
        std.process.exit(common.ExitCode.generic);
    };
    {
        var parsed = std.json.parseFromSlice(std.json.Value, alloc, spawn_line, .{}) catch {
            try common.printErr("log file is missing a valid spawn event on line 1");
            std.process.exit(common.ExitCode.generic);
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
        try common.printErr("log file is missing a timestamp on line 1");
        std.process.exit(common.ExitCode.generic);
    }

    // Setup alt-screen + raw mode (so Ctrl-C leaves cleanly).
    const stdin_fd = std.posix.STDIN_FILENO;
    const stdout_fd = std.posix.STDOUT_FILENO;
    const stdin_is_tty = sys.isatty(stdin_fd);

    try watch.enterAltScreen(stdout_fd);
    defer watch.leaveAltScreen(stdout_fd);

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

    replayLoop(io, alloc, bytes, rows, cols, first_t.?, opts) catch |err| {
        try common.printErrFmt("replay failed: {s}", .{@errorName(err)});
        std.process.exit(common.ExitCode.generic);
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
        try terminal.resize(alloc, .{ .cols = cur_cols.*, .rows = cur_rows.* });
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
    io: std.Io,
    alloc: Allocator,
    bytes: []const u8,
    initial_rows: u16,
    initial_cols: u16,
) !ReplayResult {
    var terminal = try hty.ghostty_vt.Terminal.init(io, alloc, .{
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
    io: std.Io,
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
        var terminal = try hty.ghostty_vt.Terminal.init(io, alloc, .{
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

        _ = try sys.write(stdout_fd, "\x1b[2J\x1b[H");

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
                    sys.sleep(scaled);
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
                sys.sleep(50 * std.time.ns_per_ms);
            }
        }
        sys.sleep(500 * std.time.ns_per_ms);
    }
}

fn paintFrame(alloc: Allocator, terminal: *hty.ghostty_vt.Terminal, rows: u16, cols: u16) !void {
    const frame = hty.renderScreenAnsi(alloc, terminal, rows, cols) catch return;
    defer alloc.free(frame);
    const stdout_fd = std.posix.STDOUT_FILENO;
    _ = sys.write(stdout_fd, "\x1b[H") catch return;
    _ = sys.write(stdout_fd, frame) catch return;
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
// Tests
// ============================================================================

test "trimSpeedSuffix strips trailing x" {
    try std.testing.expectEqualStrings("2", trimSpeedSuffix("2x"));
    try std.testing.expectEqualStrings("0.5", trimSpeedSuffix("0.5X"));
    try std.testing.expectEqualStrings("1", trimSpeedSuffix("1"));
}
