//! `hty attach` — interactively attach to a running session (CLI side).
//! This is the client half; the server broadcast lives in `../attach.zig`.

const std = @import("std");
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

fn attachSigwinchHandler(_: i32) callconv(.c) void {
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
    stream: std.net.Stream,
    done: std.atomic.Value(bool) = .init(false),
    waiting: std.atomic.Value(bool) = .init(false),
    started: std.atomic.Value(bool) = .init(false),
};

pub fn run(alloc: Allocator, args: []const []const u8) !void {
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
    const stdin_is_tty = std.posix.isatty(stdin_fd);

    // Read observer terminal dimensions so we can resize the PTY to match.
    var winsize = std.mem.zeroes(c.winsize);
    if (stdin_is_tty) {
        _ = c.ioctl(stdout_fd, c.TIOCGWINSZ, &winsize);
    }
    const init_rows: u16 = if (winsize.ws_row > 0) winsize.ws_row else 24;
    const init_cols: u16 = if (winsize.ws_col > 0) winsize.ws_col else 80;

    // Connect and issue the attach request before flipping the terminal
    // into raw mode so errors land on the user's normal terminal.
    const socket_path = try paths.resolveSocketPath(alloc);
    defer alloc.free(socket_path);

    var stream = ensure.ensureServer(alloc, socket_path, .{}) catch {
        try common.printErr("hty attach: cannot connect to server");
        std.process.exit(common.ExitCode.generic);
    };

    var request_buf = std.array_list.Managed(u8).init(alloc);
    defer request_buf.deinit();
    try request_buf.appendSlice("{\"op\":\"attach\"");
    if (session_ref) |s| {
        try request_buf.appendSlice(",\"session\":");
        try common.writeJsonString(request_buf.writer().any(), s);
    }
    try request_buf.writer().any().print(",\"rows\":{d},\"cols\":{d}}}\n", .{ init_rows, init_cols });
    stream.writeAll(request_buf.items) catch {
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
                        std.posix.shutdown(stream.handle, .both) catch {};
                        reader_thread.join();
                        stream.close();
                        return;
                    }
                }
            } else {
                std.Thread.sleep(25 * std.time.ns_per_ms);
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
    std.posix.shutdown(stream.handle, .both) catch {};
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
            _ = std.posix.write(stdout_fd, "\x1b[2J\x1b[H") catch {};
        }
        return;
    }

    if (std.mem.eql(u8, kind, "output")) {
        const hex_val = obj.get("bytes_hex") orelse return;
        if (hex_val != .string) return;
        const bytes = hex.decodeHex(alloc, hex_val.string) catch return;
        defer alloc.free(bytes);
        _ = std.posix.write(stdout_fd, bytes) catch {};
        return;
    }

    if (std.mem.eql(u8, kind, "exited")) {
        shared.done.store(true, .release);
        return;
    }
}
