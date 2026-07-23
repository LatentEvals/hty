//! `hty attach` — interactively attach to a running session (CLI side).
//! This is the client half; the server broadcast lives in `../attach.zig`.

const std = @import("std");
const sys = @import("hty").sys;
const Allocator = std.mem.Allocator;

const common = @import("common.zig");
const paths = @import("../paths.zig");
const ensure = @import("../ensure.zig");
const hex = @import("../hex.zig");
const watch = @import("watch.zig");

const c = @cImport({
    @cInclude("poll.h");
    @cInclude("sys/ioctl.h");
});

pub fn helpText() []const u8 {
    return
    \\hty attach [SESSION]
    \\
    \\Interactively attach to a running session. Your terminal's keystrokes
    \\are forwarded into the PTY and the session's rendered output streams
    \\back — the same session an agent is driving can be taken over by a
    \\human (or multiple humans) at any time.
    \\
    \\Detach keybinds (tmux-style, Ctrl-A is the prefix):
    \\  Ctrl-A d      Detach cleanly.
    \\  Ctrl-A Ctrl-A Send a literal Ctrl-A to the session.
    \\
    \\The observer's terminal size is sent on attach and on SIGWINCH, so
    \\the child program sees the right LINES/COLUMNS.
    \\
    \\Multiple clients can attach to the same session simultaneously —
    \\writes are atomic per input frame, reads are broadcast to everyone.
    \\
    ;
}

/// Global SIGWINCH flag. The attach loop checks this each tick and emits
/// a resize frame when set. Atomic so the signal handler stays trivial.
var attach_resized = std.atomic.Value(bool).init(false);

fn attachSigwinchHandler(_: std.posix.SIG) callconv(.c) void {
    attach_resized.store(true, .release);
}

/// Shared state between the attach main thread and its reader thread.
/// The reader owns the socket read half; the main thread owns the write
/// half and the stdin loop.
///
/// `waiting` / `started` implement the pre-creation handshake: when the
/// server acks with `waiting:true`, the main thread stays out of raw
/// mode and the reader flips `started` as soon as it sees the
/// `{"kind":"started"}` frame. Once that happens, the main thread
/// installs raw mode / SIGWINCH and falls into the regular input loop.
const AttachClientState = struct {
    stream: sys.Stream,
    done: std.atomic.Value(bool) = .init(false),
    waiting: std.atomic.Value(bool) = .init(false),
    started: std.atomic.Value(bool) = .init(false),
    /// Set when a `{"kind":"exited","code":N}` frame is observed. Allows
    /// `hty run --attach` to propagate the child's status as its own
    /// exit code. Unset (null) means we detached cleanly or the server
    /// hung up without reporting an exit.
    exit_code: std.atomic.Value(i32) = .init(std.math.minInt(i32)),
    /// If true, the reader loop drops the very first `output` frame it
    /// sees (the server's initial screen snapshot). Subsequent output
    /// frames carrying actual child output are streamed normally. Used
    /// by `hty run --attach` on non-TTY stdout so captured pipelines
    /// don't start with a screenful of ANSI-styled blank rows.
    suppress_initial_snapshot: bool = false,
    /// Mutable flag tracked alongside `suppress_initial_snapshot`. Once
    /// the first output frame has been observed (and dropped), this
    /// flips to false and subsequent output frames pass through.
    initial_snapshot_pending: std.atomic.Value(bool) = .init(false),

    pub fn getExitCode(self: *AttachClientState) ?i32 {
        const v = self.exit_code.load(.acquire);
        if (v == std.math.minInt(i32)) return null;
        return v;
    }
};

pub fn run(alloc: Allocator, io: std.Io, args: []const []const u8) !void {
    var session_ref: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.startsWith(u8, arg, "--")) {
            common.printUsageAndExit("unknown flag for `hty attach`");
        }
        if (session_ref != null) common.printUsageAndExit("only one session argument is allowed");
        session_ref = arg;
    }

    const stdin_fd = std.posix.STDIN_FILENO;
    const stdout_fd = std.posix.STDOUT_FILENO;
    const stdin_is_tty = sys.isatty(stdin_fd);

    // Read observer terminal dimensions so we can resize the PTY to match.
    var winsize = std.mem.zeroes(c.winsize);
    if (stdin_is_tty) {
        _ = c.ioctl(stdout_fd, c.TIOCGWINSZ, &winsize);
    }
    const init_rows: u16 = if (winsize.ws_row > 0) winsize.ws_row else 24;
    const init_cols: u16 = if (winsize.ws_col > 0) winsize.ws_col else 80;

    // Connect and issue the attach request before flipping the terminal
    // into raw mode so errors land on the user's normal terminal.
    const socket_path = common.resolveSocketPathOrExit(alloc);
    defer alloc.free(socket_path);

    var stream = ensure.ensureServer(alloc, io, socket_path, .{}) catch {
        try common.printErr("hty attach: cannot connect to server");
        std.process.exit(common.ExitCode.generic);
    };

    var request_buf: std.Io.Writer.Allocating = .init(alloc);
    defer request_buf.deinit();
    try request_buf.writer.writeAll("{\"op\":\"attach\"");
    if (session_ref) |s| {
        try request_buf.writer.writeAll(",\"session\":");
        try common.writeJsonString(&request_buf.writer, s);
    }
    try request_buf.writer.print(",\"rows\":{d},\"cols\":{d}}}\n", .{ init_rows, init_cols });
    stream.writeAll(request_buf.writer.buffered()) catch {
        stream.close();
        try common.printErr("hty attach: failed to send attach request");
        std.process.exit(common.ExitCode.generic);
    };

    // Read the attach ack line before going into raw mode.
    var ack_buf = std.array_list.Managed(u8).init(alloc);
    defer ack_buf.deinit();
    var ack_chunk: [512]u8 = undefined;
    while (true) {
        const n = stream.read(&ack_chunk) catch {
            stream.close();
            try common.printErr("hty attach: server hung up before ack");
            std.process.exit(common.ExitCode.generic);
        };
        if (n == 0) {
            stream.close();
            try common.printErr("hty attach: server closed connection before ack");
            std.process.exit(common.ExitCode.generic);
        }
        try ack_buf.appendSlice(ack_chunk[0..n]);
        if (std.mem.indexOfScalar(u8, ack_buf.items, '\n') != null) break;
    }
    const nl = std.mem.indexOfScalar(u8, ack_buf.items, '\n').?;
    const ack_line = ack_buf.items[0..nl];
    var is_waiting = false;
    {
        var parsed = std.json.parseFromSlice(std.json.Value, alloc, ack_line, .{}) catch {
            stream.close();
            try common.printErr("hty attach: malformed ack");
            std.process.exit(common.ExitCode.generic);
        };
        defer parsed.deinit();
        const obj = switch (parsed.value) {
            .object => |o| o,
            else => {
                stream.close();
                try common.printErr("hty attach: malformed ack");
                std.process.exit(common.ExitCode.generic);
            },
        };
        const ok = obj.get("ok") orelse {
            stream.close();
            try common.printErr("hty attach: ack missing ok field");
            std.process.exit(common.ExitCode.generic);
        };
        if (ok != .bool or !ok.bool) {
            const err_msg = if (obj.get("error")) |em| switch (em) {
                .string => em.string,
                else => "attach refused",
            } else "attach refused";
            stream.close();
            try common.printErrFmt("hty attach: {s}", .{err_msg});
            std.process.exit(common.ExitCode.not_found);
        }
        if (obj.get("waiting")) |w| {
            if (w == .bool) is_waiting = w.bool;
        }
    }

    // Any bytes that arrived on the socket after the ack's '\n' are early
    // output frames — feed them to the reader thread through a preload.
    const preload = if (nl + 1 < ack_buf.items.len)
        try alloc.dupe(u8, ack_buf.items[nl + 1 ..])
    else
        &[_]u8{};
    defer if (preload.len > 0) alloc.free(preload);

    // Shared state + reader thread. The reader owns the socket read half
    // from this point on, both during the pre-creation waiting phase (if
    // any) and during the full interactive phase below.
    var shared = AttachClientState{ .stream = stream };
    if (is_waiting) shared.waiting.store(true, .release);
    const reader_thread = std.Thread.spawn(.{}, attachClientReaderLoop, .{ alloc, &shared, preload }) catch {
        stream.close();
        try common.printErr("hty attach: failed to spawn reader thread");
        std.process.exit(common.ExitCode.generic);
    };

    // Waiting phase: the server parked us pending session creation. Stay
    // out of raw mode and SIGWINCH so accidental keys don't wind up
    // anywhere interesting, and so the terminal isn't stranded if the
    // user Ctrl-Cs out. Paint a status line and poll stdin for Ctrl-C.
    // When the reader observes `{"kind":"started"}` it flips
    // `shared.started` and the loop below drops through to the
    // interactive setup.
    if (is_waiting) {
        const display = session_ref orelse "";
        watch.paintWaitingFrame(stdout_fd, display);

        var wbuf: [32]u8 = undefined;
        while (!shared.done.load(.acquire) and !shared.started.load(.acquire)) {
            if (stdin_is_tty) {
                var pfd: c.pollfd = .{ .fd = stdin_fd, .events = c.POLLIN, .revents = 0 };
                const nr = c.poll(&pfd, 1, 25);
                if (nr > 0 and (pfd.revents & c.POLLIN) != 0) {
                    const n = std.posix.read(stdin_fd, &wbuf) catch 0;
                    var cancel = false;
                    for (wbuf[0..n]) |b| {
                        if (b == 0x03) { // Ctrl-C
                            cancel = true;
                            break;
                        }
                    }
                    if (cancel) {
                        shared.done.store(true, .release);
                        _ = stream.writeAll("{\"op\":\"detach\"}\n") catch {};
                        sys.shutdown(stream.handle, .both) catch {};
                        reader_thread.join();
                        stream.close();
                        return;
                    }
                }
            } else {
                sys.sleep(25 * std.time.ns_per_ms);
            }
        }

        // If the reader flipped done without started, the socket died
        // during the wait (server hung up, etc.). Bail cleanly.
        if (!shared.started.load(.acquire)) {
            reader_thread.join();
            stream.close();
            return;
        }
    }

    // ------------------------------------------------------------------
    // Interactive phase begins here. Either we skipped the waiting phase
    // (normal attach to an existing session) or we just got promoted.
    // Flip the terminal into raw mode and install SIGWINCH.
    // ------------------------------------------------------------------

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

    // Install SIGWINCH handler so the PTY follows terminal resizes.
    var sa: std.posix.Sigaction = .{
        .handler = .{ .handler = attachSigwinchHandler },
        .mask = std.mem.zeroes(std.posix.sigset_t),
        .flags = 0,
    };
    std.posix.sigaction(std.c.SIG.WINCH, &sa, null);
    defer {
        var sa_reset: std.posix.Sigaction = .{
            .handler = .{ .handler = std.posix.SIG.DFL },
            .mask = std.mem.zeroes(std.posix.sigset_t),
            .flags = 0,
        };
        std.posix.sigaction(std.c.SIG.WINCH, &sa_reset, null);
    }

    // If we came through the waiting phase, the server's PTY is the size
    // it was spawned with, not our terminal's. Send an initial resize so
    // the session matches what the user sees. Also read our current
    // dimensions in case the user resized during the wait.
    if (is_waiting) {
        var ws = std.mem.zeroes(c.winsize);
        if (stdin_is_tty) _ = c.ioctl(stdout_fd, c.TIOCGWINSZ, &ws);
        const r: u16 = if (ws.ws_row > 0) ws.ws_row else init_rows;
        const co: u16 = if (ws.ws_col > 0) ws.ws_col else init_cols;
        const frame = std.fmt.allocPrint(
            alloc,
            "{{\"op\":\"resize\",\"rows\":{d},\"cols\":{d}}}\n",
            .{ r, co },
        ) catch "";
        defer if (frame.len > 0) alloc.free(frame);
        if (frame.len > 0) stream.writeAll(frame) catch {};
    }

    // Main loop: forward stdin into input frames with a Ctrl-A detach state
    // machine, watch for SIGWINCH to emit resize frames, and bail out if
    // the reader thread reports the session exited.
    var ctrl_a_pending = false;
    var input_buf: [4096]u8 = undefined;
    var cur_rows = init_rows;
    var cur_cols = init_cols;

    while (!shared.done.load(.acquire)) {
        // Propagate window-size changes.
        if (attach_resized.swap(false, .acq_rel)) {
            var ws = std.mem.zeroes(c.winsize);
            if (stdin_is_tty) _ = c.ioctl(stdout_fd, c.TIOCGWINSZ, &ws);
            const new_rows: u16 = if (ws.ws_row > 0) ws.ws_row else cur_rows;
            const new_cols: u16 = if (ws.ws_col > 0) ws.ws_col else cur_cols;
            if (new_rows != cur_rows or new_cols != cur_cols) {
                cur_rows = new_rows;
                cur_cols = new_cols;
                const frame = std.fmt.allocPrint(
                    alloc,
                    "{{\"op\":\"resize\",\"rows\":{d},\"cols\":{d}}}\n",
                    .{ new_rows, new_cols },
                ) catch continue;
                defer alloc.free(frame);
                stream.writeAll(frame) catch break;
            }
        }

        // Poll stdin with a short timeout so we wake often enough to
        // notice SIGWINCH flags and reader-thread exit.
        var pfd: c.pollfd = .{ .fd = stdin_fd, .events = c.POLLIN, .revents = 0 };
        const nr = c.poll(&pfd, 1, 25);
        if (nr <= 0) continue;
        if ((pfd.revents & c.POLLIN) == 0) continue;

        const n = std.posix.read(stdin_fd, &input_buf) catch break;
        if (n == 0) break;

        // Run the bytes through the detach state machine, accumulating any
        // pass-through bytes to send as a single input frame.
        var passthrough = std.array_list.Managed(u8).init(alloc);
        defer passthrough.deinit();
        var detach = false;
        for (input_buf[0..n]) |b| {
            if (ctrl_a_pending) {
                ctrl_a_pending = false;
                if (b == 'd') {
                    detach = true;
                    break;
                }
                if (b == 0x01) {
                    // Literal Ctrl-A.
                    passthrough.append(0x01) catch break;
                    continue;
                }
                // Unrecognized chord — forward Ctrl-A followed by the byte
                // so the session still sees both.
                passthrough.append(0x01) catch break;
                passthrough.append(b) catch break;
                continue;
            }
            if (b == 0x01) {
                ctrl_a_pending = true;
                continue;
            }
            passthrough.append(b) catch break;
        }

        if (passthrough.items.len > 0) {
            const hex_str = hex.encodeHex(alloc, passthrough.items) catch continue;
            defer alloc.free(hex_str);
            const frame = std.fmt.allocPrint(
                alloc,
                "{{\"op\":\"input\",\"bytes_hex\":\"{s}\"}}\n",
                .{hex_str},
            ) catch continue;
            defer alloc.free(frame);
            stream.writeAll(frame) catch break;
        }

        if (detach) break;
    }

    // Signal the reader thread to wind down and join it.
    shared.done.store(true, .release);
    _ = stream.writeAll("{\"op\":\"detach\"}\n") catch {};
    sys.shutdown(stream.handle, .both) catch {};
    reader_thread.join();
    stream.close();
}

fn attachClientReaderLoop(alloc: Allocator, shared: *AttachClientState, preload: []const u8) void {
    defer shared.done.store(true, .release);

    const stdout_fd = std.posix.STDOUT_FILENO;
    var buffer = std.array_list.Managed(u8).init(alloc);
    defer buffer.deinit();

    if (preload.len > 0) {
        buffer.appendSlice(preload) catch return;
    }

    var chunk: [8192]u8 = undefined;
    while (!shared.done.load(.acquire)) {
        // Drain any complete lines already buffered.
        while (std.mem.indexOfScalar(u8, buffer.items, '\n')) |nl| {
            const line = buffer.items[0..nl];
            handleAttachServerFrame(alloc, shared, stdout_fd, line);
            const rest = buffer.items[nl + 1 ..];
            std.mem.copyForwards(u8, buffer.items[0..rest.len], rest);
            buffer.shrinkRetainingCapacity(rest.len);
        }

        if (shared.done.load(.acquire)) return;

        const n = shared.stream.read(&chunk) catch return;
        if (n == 0) return;
        buffer.appendSlice(chunk[0..n]) catch return;
    }
}

fn handleAttachServerFrame(
    alloc: Allocator,
    shared: *AttachClientState,
    stdout_fd: std.posix.fd_t,
    line: []const u8,
) void {
    if (std.mem.trim(u8, line, " \t\r").len == 0) return;

    var parsed = std.json.parseFromSlice(std.json.Value, alloc, line, .{}) catch return;
    defer parsed.deinit();

    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return,
    };

    const kind_val = obj.get("kind") orelse return;
    if (kind_val != .string) return;
    const kind = kind_val.string;

    if (std.mem.eql(u8, kind, "started")) {
        // Promotion signal. Clear the "Waiting…" paint so the main
        // thread's alt-screen enter lands on a blank canvas.
        shared.started.store(true, .release);
        if (shared.waiting.load(.acquire)) {
            shared.waiting.store(false, .release);
            _ = sys.write(stdout_fd, "\x1b[2J\x1b[H") catch {};
        }
        return;
    }

    if (std.mem.eql(u8, kind, "output")) {
        const hex_val = obj.get("bytes_hex") orelse return;
        if (hex_val != .string) return;
        // Drop the server's initial screen snapshot for callers that
        // opted in (e.g. `hty run --attach` on non-TTY stdout). The
        // snapshot is always the first output frame emitted right after
        // the ack; every frame after it is real child output.
        if (shared.initial_snapshot_pending.swap(false, .acq_rel)) {
            return;
        }
        const bytes = hex.decodeHex(alloc, hex_val.string) catch return;
        defer alloc.free(bytes);
        _ = sys.write(stdout_fd, bytes) catch {};
        return;
    }

    if (std.mem.eql(u8, kind, "exited")) {
        if (obj.get("code")) |cv| {
            if (cv == .integer) {
                const code: i32 = @intCast(cv.integer);
                shared.exit_code.store(code, .release);
            }
        }
        shared.done.store(true, .release);
        return;
    }
}

/// Options for the interactive attach phase when an attach ack has
/// already been received on `stream` and the server is streaming
/// frames. Used by both `hty attach` (after its own waiting-phase
/// handshake) and `hty run --attach` (which hands off a fresh session).
pub const InteractiveOptions = struct {
    /// Any bytes that arrived on the socket between the ack's '\n' and
    /// our handoff point. Ownership is transferred to the reader thread
    /// (freed via alloc.free once consumed). Pass &[_]u8{} if none.
    preload: []const u8 = &[_]u8{},
    /// If true, send an initial resize frame using the caller's current
    /// terminal dimensions. `hty attach` uses this after being promoted
    /// out of a waiting-phase handshake; `run --attach` sets it to false
    /// because the spawn request already pinned the PTY dimensions.
    send_initial_resize: bool = false,
    /// If true, use the alt-screen for the interactive session (saves
    /// the user's scrollback). `hty attach` always uses alt-screen;
    /// `run --attach` skips it on non-TTY stdout so captured output
    /// (tests, pipes) contains just the raw program output.
    use_alt_screen: bool = true,
    /// Initial rows/cols used for the first resize frame if
    /// `send_initial_resize` is set. Also used as the baseline for the
    /// in-loop SIGWINCH comparison.
    init_rows: u16 = 24,
    init_cols: u16 = 80,
    /// If true, the reader loop drops the server's initial screen
    /// snapshot (emitted right after the attach ack). `run --attach`
    /// sets this on non-TTY stdout so piped output isn't prefixed with
    /// a screenful of ANSI-styled blank rows.
    suppress_initial_snapshot: bool = false,
};

/// Run the interactive phase of an attach on an already-ack'd stream.
/// This is shared by `hty attach` (normal path and waiting-promotion
/// path) and `hty run --attach`. On return, the caller owns
/// `shared.exit_code` (null = detached, i32 = child exit code) and is
/// responsible for closing the stream / joining any reader thread.
///
/// The function spawns the reader thread internally, joins it before
/// returning, and does NOT close the stream (the caller may still want
/// to send a final `detach` op).
pub fn runInteractive(
    alloc: Allocator,
    shared: *AttachClientState,
    opts: InteractiveOptions,
) !void {
    const stdin_fd = std.posix.STDIN_FILENO;
    const stdout_fd = std.posix.STDOUT_FILENO;
    const stdin_is_tty = sys.isatty(stdin_fd);
    const stdout_is_tty = sys.isatty(stdout_fd);
    const use_alt = opts.use_alt_screen and stdout_is_tty;

    if (opts.suppress_initial_snapshot) {
        shared.suppress_initial_snapshot = true;
        shared.initial_snapshot_pending.store(true, .release);
    }

    const reader_thread = std.Thread.spawn(
        .{},
        attachClientReaderLoop,
        .{ alloc, shared, opts.preload },
    ) catch {
        try common.printErr("hty attach: failed to spawn reader thread");
        std.process.exit(common.ExitCode.generic);
    };

    if (use_alt) {
        try watch.enterAltScreen(stdout_fd);
    }
    defer if (use_alt) watch.leaveAltScreen(stdout_fd);

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

    var sa: std.posix.Sigaction = .{
        .handler = .{ .handler = attachSigwinchHandler },
        .mask = std.mem.zeroes(std.posix.sigset_t),
        .flags = 0,
    };
    std.posix.sigaction(std.c.SIG.WINCH, &sa, null);
    defer {
        var sa_reset: std.posix.Sigaction = .{
            .handler = .{ .handler = std.posix.SIG.DFL },
            .mask = std.mem.zeroes(std.posix.sigset_t),
            .flags = 0,
        };
        std.posix.sigaction(std.c.SIG.WINCH, &sa_reset, null);
    }

    if (opts.send_initial_resize) {
        var ws = std.mem.zeroes(c.winsize);
        if (stdin_is_tty) _ = c.ioctl(stdout_fd, c.TIOCGWINSZ, &ws);
        const r: u16 = if (ws.ws_row > 0) ws.ws_row else opts.init_rows;
        const co: u16 = if (ws.ws_col > 0) ws.ws_col else opts.init_cols;
        const frame = std.fmt.allocPrint(
            alloc,
            "{{\"op\":\"resize\",\"rows\":{d},\"cols\":{d}}}\n",
            .{ r, co },
        ) catch "";
        defer if (frame.len > 0) alloc.free(frame);
        if (frame.len > 0) shared.stream.writeAll(frame) catch {};
    }

    var ctrl_a_pending = false;
    var input_buf: [4096]u8 = undefined;
    var cur_rows = opts.init_rows;
    var cur_cols = opts.init_cols;

    while (!shared.done.load(.acquire)) {
        if (attach_resized.swap(false, .acq_rel)) {
            var ws = std.mem.zeroes(c.winsize);
            if (stdin_is_tty) _ = c.ioctl(stdout_fd, c.TIOCGWINSZ, &ws);
            const new_rows: u16 = if (ws.ws_row > 0) ws.ws_row else cur_rows;
            const new_cols: u16 = if (ws.ws_col > 0) ws.ws_col else cur_cols;
            if (new_rows != cur_rows or new_cols != cur_cols) {
                cur_rows = new_rows;
                cur_cols = new_cols;
                const frame = std.fmt.allocPrint(
                    alloc,
                    "{{\"op\":\"resize\",\"rows\":{d},\"cols\":{d}}}\n",
                    .{ new_rows, new_cols },
                ) catch continue;
                defer alloc.free(frame);
                shared.stream.writeAll(frame) catch break;
            }
        }

        if (!stdin_is_tty) {
            // No stdin to forward — just wait for the reader thread.
            sys.sleep(25 * std.time.ns_per_ms);
            continue;
        }

        var pfd: c.pollfd = .{ .fd = stdin_fd, .events = c.POLLIN, .revents = 0 };
        const nr = c.poll(&pfd, 1, 25);
        if (nr <= 0) continue;
        if ((pfd.revents & c.POLLIN) == 0) continue;

        const n = std.posix.read(stdin_fd, &input_buf) catch break;
        if (n == 0) break;

        var passthrough = std.array_list.Managed(u8).init(alloc);
        defer passthrough.deinit();
        var detach = false;
        for (input_buf[0..n]) |b| {
            if (ctrl_a_pending) {
                ctrl_a_pending = false;
                if (b == 'd') {
                    detach = true;
                    break;
                }
                if (b == 0x01) {
                    passthrough.append(0x01) catch break;
                    continue;
                }
                passthrough.append(0x01) catch break;
                passthrough.append(b) catch break;
                continue;
            }
            if (b == 0x01) {
                ctrl_a_pending = true;
                continue;
            }
            passthrough.append(b) catch break;
        }

        if (passthrough.items.len > 0) {
            const hex_str = hex.encodeHex(alloc, passthrough.items) catch continue;
            defer alloc.free(hex_str);
            const frame = std.fmt.allocPrint(
                alloc,
                "{{\"op\":\"input\",\"bytes_hex\":\"{s}\"}}\n",
                .{hex_str},
            ) catch continue;
            defer alloc.free(frame);
            shared.stream.writeAll(frame) catch break;
        }

        if (detach) break;
    }

    shared.done.store(true, .release);
    _ = shared.stream.writeAll("{\"op\":\"detach\"}\n") catch {};
    sys.shutdown(shared.stream.handle, .both) catch {};
    reader_thread.join();
}

/// Helper for `hty run --attach`: given a freshly-spawned session's id,
/// open a new server connection, send an attach request, read the ack,
/// and run the interactive phase. Returns the child's exit code if the
/// session exited while attached, null if the user detached.
pub fn attachToExistingSession(
    io: std.Io,
    alloc: Allocator,
    session_id: []const u8,
    init_rows: u16,
    init_cols: u16,
) !?i32 {
    const socket_path = common.resolveSocketPathOrExit(alloc);
    defer alloc.free(socket_path);

    var stream = ensure.ensureServer(alloc, io, socket_path, .{}) catch {
        try common.printErr("hty run --attach: cannot connect to server");
        std.process.exit(common.ExitCode.generic);
    };

    var request_buf: std.Io.Writer.Allocating = .init(alloc);
    defer request_buf.deinit();
    try request_buf.writer.writeAll("{\"op\":\"attach\",\"session\":");
    try common.writeJsonString(&request_buf.writer, session_id);
    try request_buf.writer.print(",\"rows\":{d},\"cols\":{d}}}\n", .{ init_rows, init_cols });
    stream.writeAll(request_buf.writer.buffered()) catch {
        stream.close();
        try common.printErr("hty run --attach: failed to send attach request");
        std.process.exit(common.ExitCode.generic);
    };

    // Read the attach ack line.
    var ack_buf = std.array_list.Managed(u8).init(alloc);
    defer ack_buf.deinit();
    var ack_chunk: [512]u8 = undefined;
    while (true) {
        const n = stream.read(&ack_chunk) catch {
            stream.close();
            try common.printErr("hty run --attach: server hung up before ack");
            std.process.exit(common.ExitCode.generic);
        };
        if (n == 0) {
            stream.close();
            try common.printErr("hty run --attach: server closed connection before ack");
            std.process.exit(common.ExitCode.generic);
        }
        try ack_buf.appendSlice(ack_chunk[0..n]);
        if (std.mem.indexOfScalar(u8, ack_buf.items, '\n') != null) break;
    }
    const nl = std.mem.indexOfScalar(u8, ack_buf.items, '\n').?;
    const ack_line = ack_buf.items[0..nl];
    {
        var parsed = std.json.parseFromSlice(std.json.Value, alloc, ack_line, .{}) catch {
            stream.close();
            try common.printErr("hty run --attach: malformed ack");
            std.process.exit(common.ExitCode.generic);
        };
        defer parsed.deinit();
        const obj = switch (parsed.value) {
            .object => |o| o,
            else => {
                stream.close();
                try common.printErr("hty run --attach: malformed ack");
                std.process.exit(common.ExitCode.generic);
            },
        };
        const ok = obj.get("ok") orelse {
            stream.close();
            try common.printErr("hty run --attach: ack missing ok field");
            std.process.exit(common.ExitCode.generic);
        };
        if (ok != .bool or !ok.bool) {
            // Most likely SessionNotFound because --remove reaped a
            // very short-lived child before we could attach. That's OK
            // for `run --attach --remove -- echo hello` because the
            // immediate `run` response already confirmed the spawn
            // succeeded; just surface exit 0 and return.
            stream.close();
            return 0;
        }
    }

    const preload: []u8 = if (nl + 1 < ack_buf.items.len)
        try alloc.dupe(u8, ack_buf.items[nl + 1 ..])
    else
        &[_]u8{};
    defer if (preload.len > 0) alloc.free(preload);

    var shared = AttachClientState{ .stream = stream };
    const stdout_is_tty = sys.isatty(std.posix.STDOUT_FILENO);
    try runInteractive(alloc, &shared, .{
        .preload = preload,
        .send_initial_resize = false,
        .use_alt_screen = true,
        .init_rows = init_rows,
        .init_cols = init_cols,
        .suppress_initial_snapshot = !stdout_is_tty,
    });

    const code = shared.getExitCode();
    stream.close();
    return code;
}
