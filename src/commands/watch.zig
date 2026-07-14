//! `hty watch` — subscribe to a session's live output and paint it to the
//! user's terminal. Read-only; Ctrl-C or Ctrl-Q detaches. If the target
//! session doesn't exist yet, the watch socket is parked on the server
//! until a `hty run --name <ref>` creates a matching session, at which
//! point it's promoted and the client receives an initial snapshot plus
//! live frames. See LatentEvals/hty#29.

const std = @import("std");
const Allocator = std.mem.Allocator;

const common = @import("common.zig");
const paths = @import("../paths.zig");
const ensure = @import("../ensure.zig");
const hex = @import("../hex.zig");

const c = @cImport({
    @cInclude("poll.h");
});

pub fn helpText() []const u8 {
    return
    \\hty watch [SESSION]
    \\
    \\Attach to a session read-only and paint its rendered screen live to
    \\your terminal. Ctrl-C or Ctrl-Q to detach.
    \\
    \\SESSION may be a UUID prefix or the session's --name. If omitted and
    \\exactly one session is running, that one is used.
    \\
    \\If SESSION is a name that doesn't exist yet, watch will wait for it
    \\to be created by a later `hty run --name SESSION -- …` and start
    \\streaming the moment that session spawns.
    \\
    ;
}

// ============================================================================
// Terminal state helpers (shared by watch, replay, and attach)
// ============================================================================

/// Sequence to switch into the alt-screen, hide the cursor, clear, and home.
pub const alt_screen_enter = "\x1b[?1049h\x1b[?25l\x1b[2J\x1b[H";

/// Comprehensive restore sequence. Programs like vim enable a zoo of DEC
/// private modes (bracketed paste, mouse tracking, focus events,
/// application cursor keys, application keypad) and if we leave the
/// alt-screen without undoing them the user's terminal is stranded — Ctrl-K
/// and similar shortcuts stop working because the terminal is still in
/// mouse / app-keys mode. Reset all of them explicitly in addition to
/// exiting the alt-screen itself.
pub const alt_screen_exit =
    "\x1b[?1049l" ++ // exit alt screen
    "\x1b[?25h" ++ // show cursor
    "\x1b[0m" ++ // reset SGR
    "\x1b[?2004l" ++ // bracketed paste off
    "\x1b[?1004l" ++ // focus events off
    "\x1b[?1000l" ++ // mouse button tracking off
    "\x1b[?1002l" ++ // mouse motion tracking off
    "\x1b[?1006l" ++ // SGR mouse mode off
    "\x1b[?1l" ++ // cursor keys → normal
    "\x1b>" ++ // keypad → numeric
    "\x1b[?7h"; // autowrap back on

pub fn enterAltScreen(stdout_fd: std.posix.fd_t) !void {
    _ = try std.posix.write(stdout_fd, alt_screen_enter);
}

pub fn leaveAltScreen(stdout_fd: std.posix.fd_t) void {
    _ = std.posix.write(stdout_fd, alt_screen_exit) catch {};
}

/// Paint a centered "Waiting for session <name>…" frame to stdout.
/// Shared by `hty watch` and `hty attach` while they're in the
/// pre-creation waiting state. Clears the screen first so repeated
/// paints don't stack. Safe to call when stdout isn't a TTY — the
/// sequences degrade to gibberish in a pipe, which is acceptable
/// because `hty watch` is an interactive command.
pub fn paintWaitingFrame(stdout_fd: std.posix.fd_t, name: []const u8) void {
    var buf: [512]u8 = undefined;
    const msg = std.fmt.bufPrint(
        &buf,
        "\x1b[2J\x1b[H\x1b[2mWaiting for session '{s}'… (Ctrl-C to cancel)\x1b[0m",
        .{name},
    ) catch return;
    _ = std.posix.write(stdout_fd, msg) catch {};
}

// ============================================================================
// Watch client
// ============================================================================

/// Shared state between the watch main thread and its reader thread.
/// Mirrors `AttachClientState` in commands/attach.zig minus input plumbing.
const WatchClientState = struct {
    stream: std.net.Stream,
    done: std.atomic.Value(bool) = .init(false),
    /// Set true by the reader when a `{"kind":"started"}` frame arrives.
    /// The main thread doesn't use this — it only matters inside the
    /// reader loop so it can clear the "Waiting…" paint before the first
    /// output frame lands — but storing it lets tests observe the
    /// transition.
    started: std.atomic.Value(bool) = .init(false),
    waiting: bool = false,
};

pub fn run(alloc: Allocator, args: []const []const u8) !void {
    const session_ref: ?[]const u8 = if (args.len > 0 and !std.mem.startsWith(u8, args[0], "--")) args[0] else null;

    const stdin_fd = std.posix.STDIN_FILENO;
    const stdout_fd = std.posix.STDOUT_FILENO;
    const stdin_is_tty = std.posix.isatty(stdin_fd);

    const socket_path = common.resolveSocketPathOrExit(alloc);
    defer alloc.free(socket_path);

    // Connect and send the subscribe op before flipping the terminal into
    // raw mode so parse errors land on the user's normal terminal.
    var stream = ensure.ensureServer(alloc, socket_path, .{}) catch {
        try common.printErr("hty watch: cannot connect to server");
        std.process.exit(common.ExitCode.generic);
    };

    var request_buf = std.array_list.Managed(u8).init(alloc);
    defer request_buf.deinit();
    try request_buf.appendSlice("{\"op\":\"watch\"");
    if (session_ref) |s| {
        try request_buf.appendSlice(",\"session\":");
        try common.writeJsonString(request_buf.writer().any(), s);
    }
    try request_buf.appendSlice("}\n");
    stream.writeAll(request_buf.items) catch {
        stream.close();
        try common.printErr("hty watch: failed to send watch request");
        std.process.exit(common.ExitCode.generic);
    };

    // Read the ack line before going into raw mode.
    var ack_buf = std.array_list.Managed(u8).init(alloc);
    defer ack_buf.deinit();
    var ack_chunk: [512]u8 = undefined;
    while (true) {
        const n = stream.read(&ack_chunk) catch {
            stream.close();
            try common.printErr("hty watch: server hung up before ack");
            std.process.exit(common.ExitCode.generic);
        };
        if (n == 0) {
            stream.close();
            try common.printErr("hty watch: server closed connection before ack");
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
            try common.printErr("hty watch: malformed ack");
            std.process.exit(common.ExitCode.generic);
        };
        defer parsed.deinit();
        const obj = switch (parsed.value) {
            .object => |o| o,
            else => {
                stream.close();
                try common.printErr("hty watch: malformed ack");
                std.process.exit(common.ExitCode.generic);
            },
        };
        const ok = obj.get("ok") orelse {
            stream.close();
            try common.printErr("hty watch: ack missing ok field");
            std.process.exit(common.ExitCode.generic);
        };
        if (ok != .bool or !ok.bool) {
            const err_msg = if (obj.get("error")) |em| switch (em) {
                .string => em.string,
                else => "watch refused",
            } else "watch refused";
            stream.close();
            const code = common.errorToExitCode(err_msg);
            try common.printErrFmt("hty watch: {s}", .{err_msg});
            std.process.exit(code);
        }
        if (obj.get("waiting")) |w| {
            if (w == .bool) is_waiting = w.bool;
        }
    }

    // Bytes that arrived after the ack newline are early server frames;
    // hand them to the reader as a preload.
    const preload = if (nl + 1 < ack_buf.items.len)
        try alloc.dupe(u8, ack_buf.items[nl + 1 ..])
    else
        &[_]u8{};
    defer if (preload.len > 0) alloc.free(preload);

    // Register the process.exit defer FIRST so it runs LAST (LIFO).
    // Otherwise it would fire before the alt-screen restore below and
    // prevent terminal cleanup from ever running.
    const exit_code: u8 = common.ExitCode.ok;
    defer std.process.exit(exit_code);

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

    // If the server parked us, paint the waiting frame. Pass the user-
    // provided ref through as the display name. Empty/null ref can only
    // happen in sole-session mode, which never parks (the server
    // fail-fasts when there's no sole session).
    if (is_waiting) {
        const display = session_ref orelse "";
        paintWaitingFrame(stdout_fd, display);
    }

    // Spawn reader thread, wire up shared state.
    var shared = WatchClientState{ .stream = stream, .waiting = is_waiting };
    const reader_thread = std.Thread.spawn(.{}, watchClientReaderLoop, .{ alloc, &shared, preload }) catch {
        stream.close();
        try common.printErr("hty watch: failed to spawn reader thread");
        std.process.exit(common.ExitCode.generic);
    };

    // Main thread: poll stdin for Ctrl-C / Ctrl-Q and the reader's done
    // flag. Watch is read-only so we never send input frames.
    var input_buf: [32]u8 = undefined;
    while (!shared.done.load(.acquire)) {
        if (stdin_is_tty) {
            var poll_fd: c.pollfd = .{
                .fd = stdin_fd,
                .events = c.POLLIN,
                .revents = 0,
            };
            const nr = c.poll(&poll_fd, 1, 25);
            if (nr > 0 and (poll_fd.revents & c.POLLIN) != 0) {
                const n = std.posix.read(stdin_fd, &input_buf) catch 0;
                var want_detach = false;
                for (input_buf[0..n]) |b| {
                    if (b == 0x03 or b == 0x11) {
                        want_detach = true;
                        break;
                    }
                }
                if (want_detach) break;
            }
        } else {
            // No TTY: can't poll for Ctrl-C. Sleep briefly so we don't
            // busy-loop and let the reader signal `done` on its own.
            std.Thread.sleep(25 * std.time.ns_per_ms);
        }
    }

    // Shut down the reader and clean up.
    shared.done.store(true, .release);
    _ = stream.writeAll("{\"op\":\"detach\"}\n") catch {};
    std.posix.shutdown(stream.handle, .both) catch {};
    reader_thread.join();
    stream.close();
}

fn watchClientReaderLoop(alloc: Allocator, shared: *WatchClientState, preload: []const u8) void {
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
            handleWatchServerFrame(alloc, shared, stdout_fd, line);
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

fn handleWatchServerFrame(
    alloc: Allocator,
    shared: *WatchClientState,
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
        // Promotion signal. Clear the waiting paint so the initial
        // snapshot lands on a clean screen.
        shared.started.store(true, .release);
        if (shared.waiting) {
            shared.waiting = false;
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
