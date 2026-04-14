//! `hty watch` — paint a session's rendered screen live to the user's
//! terminal. Read-only; Ctrl-C or Ctrl-Q detaches.

const std = @import("std");
const Allocator = std.mem.Allocator;

const common = @import("common.zig");
const paths = @import("../paths.zig");
const ensure = @import("../ensure.zig");
const getString = @import("../json.zig").getString;

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

pub fn run(alloc: Allocator, args: []const []const u8) !void {
    const session_ref: ?[]const u8 = if (args.len > 0 and !std.mem.startsWith(u8, args[0], "--")) args[0] else null;

    // Build a reusable request payload once.
    var payload_buf = std.array_list.Managed(u8).init(alloc);
    defer payload_buf.deinit();
    try payload_buf.appendSlice("{\"op\":\"snapshot\"");
    if (session_ref) |s| {
        try payload_buf.appendSlice(",\"session\":");
        try common.writeJsonString(payload_buf.writer().any(), s);
    }
    try payload_buf.appendSlice("}\n");
    const request_payload = payload_buf.items;

    // Setup: alt-screen, raw mode on stdin (for Ctrl-C detection). When stdin
    // isn't a TTY (e.g. piped or redirected), skip the raw-mode dance entirely.
    const stdin_fd = std.posix.STDIN_FILENO;
    const stdout_fd = std.posix.STDOUT_FILENO;
    const stdin_is_tty = std.posix.isatty(stdin_fd);

    // Register the process.exit defer FIRST so it runs LAST (defers are
    // LIFO). Otherwise it would fire before the alt-screen restore below
    // and std.process.exit would prevent the terminal cleanup from ever
    // running — the user gets stranded with vim's private modes still
    // active. The exit_code var is mutated later in the loop.
    var exit_code: u8 = common.ExitCode.ok;
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

    const socket_path = try paths.resolveSocketPath(alloc);
    defer alloc.free(socket_path);

    var input_buf: [32]u8 = undefined;

    while (true) {
        // Non-blocking check for Ctrl-C / Ctrl-Q — only meaningful when stdin
        // is a real terminal. Otherwise we rely on the session-exit path to
        // break out of the loop.
        if (stdin_is_tty) {
            var poll_fd: c.pollfd = .{
                .fd = stdin_fd,
                .events = c.POLLIN,
                .revents = 0,
            };
            if (c.poll(&poll_fd, 1, 0) > 0 and (poll_fd.revents & c.POLLIN) != 0) {
                const n = std.posix.read(stdin_fd, &input_buf) catch 0;
                for (input_buf[0..n]) |b| {
                    if (b == 0x03 or b == 0x11) return; // Ctrl-C or Ctrl-Q
                }
            }
        }

        // Connect and send snapshot request.
        var stream = ensure.ensureServer(alloc, socket_path, .{}) catch {
            break;
        };
        stream.writeAll(request_payload) catch {
            stream.close();
            break;
        };

        var resp_buf = std.array_list.Managed(u8).init(alloc);
        defer resp_buf.deinit();

        var chunk: [4096]u8 = undefined;
        while (true) {
            const n = stream.read(&chunk) catch 0;
            if (n == 0) break;
            resp_buf.appendSlice(chunk[0..n]) catch break;
            if (std.mem.indexOfScalar(u8, resp_buf.items, '\n') != null) break;
        }
        stream.close();

        const newline = std.mem.indexOfScalar(u8, resp_buf.items, '\n') orelse resp_buf.items.len;
        const line = resp_buf.items[0..newline];

        // Parse and paint.
        var parsed = std.json.parseFromSlice(std.json.Value, alloc, line, .{}) catch {
            std.Thread.sleep(50 * std.time.ns_per_ms);
            continue;
        };
        defer parsed.deinit();

        if (parsed.value != .object) {
            std.Thread.sleep(50 * std.time.ns_per_ms);
            continue;
        }
        const object = parsed.value.object;

        const ok = object.get("ok") orelse {
            std.Thread.sleep(50 * std.time.ns_per_ms);
            continue;
        };
        if (ok != .bool or !ok.bool) {
            // Treat the first ok=false as fatal — most likely the target
            // session doesn't exist, so mirror the exit code the `send` or
            // `kill` subcommands would return for the same situation.
            if (object.get("error")) |err_val| {
                if (err_val == .string) {
                    exit_code = common.errorToExitCode(err_val.string);
                }
            }
            if (exit_code == common.ExitCode.ok) exit_code = common.ExitCode.not_found;
            return;
        }

        const snap_val = object.get("snapshot") orelse {
            std.Thread.sleep(50 * std.time.ns_per_ms);
            continue;
        };
        const snap_obj = switch (snap_val) {
            .object => |o| o,
            else => {
                std.Thread.sleep(50 * std.time.ns_per_ms);
                continue;
            },
        };
        const screen_ansi = getString(snap_obj, "screen_ansi") orelse "";

        _ = std.posix.write(stdout_fd, "\x1b[H") catch {};
        _ = std.posix.write(stdout_fd, screen_ansi) catch {};

        // If the session has exited, paint the final frame once and bail.
        const status = getString(snap_obj, "status") orelse "running";
        if (!std.mem.eql(u8, status, "running")) {
            std.Thread.sleep(100 * std.time.ns_per_ms);
            return;
        }

        std.Thread.sleep(50 * std.time.ns_per_ms);
    }
}
