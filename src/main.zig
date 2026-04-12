const std = @import("std");
const hty = @import("hty");
const ghostty_vt = hty.ghostty_vt;
const TerminalSize = struct {
    rows: u16,
    cols: u16,
};

const c = @cImport({
    @cInclude("poll.h");
    @cInclude("unistd.h");
});

const TerminalIo = struct {
    file: ?std.fs.File,
    input_fd: std.posix.fd_t,
    output_fd: std.posix.fd_t,

    fn deinit(self: *TerminalIo) void {
        if (self.file) |file| file.close();
        self.* = undefined;
    }
};

pub fn main() !void {
    const alloc = std.heap.c_allocator;
    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);

    var term_io = try openTerminalIo();
    defer term_io.deinit();

    const command = parseCommand(args[1..]);
    const outer_size = currentTerminalSize(term_io.output_fd);
    const inner_size: TerminalSize = .{
        .rows = if (outer_size.rows > 2) outer_size.rows - 2 else 1,
        .cols = if (outer_size.cols > 2) outer_size.cols - 2 else 1,
    };

    var terminal = try hty.InteractiveTerminal.spawn(alloc, command, .{
        .rows = inner_size.rows,
        .cols = inner_size.cols,
        .emit_raw_bytes = false,
        .emit_screen_updates = true,
    });
    defer terminal.deinit();

    _ = try std.posix.write(term_io.output_fd, "\x1b[?1049h\x1b[?25l\x1b[2J\x1b[H");
    defer _ = std.posix.write(term_io.output_fd, "\x1b[0m\x1b[?25h\x1b[?1049l") catch {};

    const saved_termios = try std.posix.tcgetattr(term_io.input_fd);
    var raw = saved_termios;
    raw.iflag.BRKINT = false;
    raw.iflag.ICRNL = false;
    raw.iflag.INPCK = false;
    raw.iflag.ISTRIP = false;
    raw.iflag.IXON = false;
    raw.cflag.CSIZE = .CS8;
    raw.lflag.ECHO = false;
    raw.lflag.ICANON = false;
    raw.lflag.IEXTEN = false;
    raw.lflag.ISIG = false;
    raw.cc[@intFromEnum(std.c.V.MIN)] = 1;
    raw.cc[@intFromEnum(std.c.V.TIME)] = 0;
    try std.posix.tcsetattr(term_io.input_fd, .FLUSH, raw);
    defer std.posix.tcsetattr(term_io.input_fd, .FLUSH, saved_termios) catch {};

    var running = std.atomic.Value(bool).init(true);
    var input = try std.Thread.spawn(.{}, inputThreadMain, .{ terminal, term_io.input_fd, &running });
    defer {
        running.store(false, .seq_cst);
        input.join();
    }
    var render_state: ghostty_vt.RenderState = .empty;
    defer render_state.deinit(alloc);

    var current_title = try alloc.dupe(u8, command.program);
    defer alloc.free(current_title);
    var last_failure: ?[]u8 = null;
    defer if (last_failure) |message| alloc.free(message);
    var needs_render = true;
    var exited = false;

    while (true) {
        if (terminal.pollEvent()) |event| {
            defer {
                var owned = event;
                owned.deinit(alloc);
            }

            switch (event) {
                .started, .screen_update => {
                    needs_render = true;
                },
                .bell => {
                    _ = try std.posix.write(term_io.output_fd, "\x07");
                },
                .title_changed => |title| {
                    alloc.free(current_title);
                    current_title = try alloc.dupe(u8, title);
                    needs_render = true;
                },
                .failure => |message| {
                    if (last_failure) |old| alloc.free(old);
                    last_failure = try alloc.dupe(u8, message);
                    needs_render = true;
                },
                .exited => {
                    exited = true;
                    needs_render = true;
                },
                else => {},
            }
            continue;
        }

        if (needs_render) {
            try renderFrame(
                alloc,
                term_io.output_fd,
                &render_state,
                terminal,
                outer_size,
                current_title,
                last_failure,
            );
            needs_render = false;
            if (exited) break;
        }

        std.Thread.sleep(10 * std.time.ns_per_ms);
    }
}

fn openTerminalIo() !TerminalIo {
    if (std.posix.isatty(std.posix.STDIN_FILENO) and std.posix.isatty(std.posix.STDOUT_FILENO)) {
        return .{
            .file = null,
            .input_fd = std.posix.STDIN_FILENO,
            .output_fd = std.posix.STDOUT_FILENO,
        };
    }

    const file = try std.fs.openFileAbsolute("/dev/tty", .{ .mode = .read_write });
    return .{
        .file = file,
        .input_fd = file.handle,
        .output_fd = file.handle,
    };
}

fn inputThreadMain(
    terminal: *hty.InteractiveTerminal,
    tty_fd: std.posix.fd_t,
    running: *std.atomic.Value(bool),
) void {
    var buffer: [1024]u8 = undefined;
    var poll_fd: c.pollfd = .{
        .fd = tty_fd,
        .events = c.POLLIN,
        .revents = 0,
    };

    while (running.load(.seq_cst)) {
        poll_fd.revents = 0;
        const ready = c.poll(&poll_fd, 1, 100);
        if (ready < 0) continue;
        if (ready == 0 or (poll_fd.revents & c.POLLIN) == 0) continue;

        const n = std.posix.read(tty_fd, &buffer) catch break;
        if (n == 0) break;

        if (std.mem.indexOfScalar(u8, buffer[0..n], 0x11)) |_| {
            terminal.kill() catch {};
            break;
        }

        terminal.send(.{ .bytes = buffer[0..n] }) catch break;
    }
}

fn parseCommand(args: []const []const u8) hty.CommandSpec {
    if (args.len == 0) {
        if (std.process.getEnvVarOwned(std.heap.c_allocator, "SHELL")) |shell| {
            return .{ .program = shell };
        } else |_| {}
        return .{ .program = "/bin/sh" };
    }

    return .{
        .program = args[0],
        .args = if (args.len > 1) args[1..] else &.{},
    };
}

fn currentTerminalSize(tty_fd: std.posix.fd_t) TerminalSize {
    var winsize = std.mem.zeroes(std.posix.winsize);
    if (std.posix.system.ioctl(tty_fd, std.posix.T.IOCGWINSZ, @intFromPtr(&winsize)) == 0) {
        if (winsize.row > 0 and winsize.col > 0) {
            return .{
                .rows = winsize.row,
                .cols = winsize.col,
            };
        }
    }

    return .{ .rows = 24, .cols = 80 };
}

fn renderFrame(
    alloc: std.mem.Allocator,
    stdout_fd: std.posix.fd_t,
    render_state: *ghostty_vt.RenderState,
    terminal: *hty.InteractiveTerminal,
    outer_size: TerminalSize,
    title: []const u8,
    failure: ?[]const u8,
) !void {
    terminal.mutex.lock();
    defer terminal.mutex.unlock();
    try render_state.update(alloc, &terminal.terminal);

    var out = std.array_list.Managed(u8).init(alloc);
    defer out.deinit();

    try out.appendSlice("\x1b[H");
    try appendBorderLine(&out, outer_size.cols, title);
    try out.append('\n');

    const row_slice = render_state.row_data.slice();
    const rows = row_slice.items(.cells);
    const inner_rows = if (outer_size.rows > 2) outer_size.rows - 2 else 1;
    const inner_cols = if (outer_size.cols > 2) outer_size.cols - 2 else 1;

    for (0..inner_rows) |y| {
        try out.append('|');
        if (y < rows.len) {
            try appendRenderedRow(&out, render_state, rows[y], @intCast(y), inner_cols);
        } else {
            try appendSpaces(&out, inner_cols);
        }
        try out.append('|');
        try out.append('\n');
    }

    try appendStatusLine(&out, outer_size.cols, failure);
    _ = try std.posix.write(stdout_fd, out.items);
}

fn appendBorderLine(out: *std.array_list.Managed(u8), cols: u16, title: []const u8) !void {
    if (cols <= 2) {
        try appendSpaces(out, cols);
        return;
    }

    const inner = cols - 2;
    const label = try std.fmt.allocPrint(out.allocator, " hty :: {s} ", .{title});
    defer out.allocator.free(label);

    try out.append('+');
    if (label.len >= inner) {
        try out.appendSlice(label[0..inner]);
    } else {
        try out.appendSlice(label);
        try appendRepeated(out, '-', inner - @as(u16, @intCast(label.len)));
    }
    try out.append('+');
}

fn appendStatusLine(out: *std.array_list.Managed(u8), cols: u16, failure: ?[]const u8) !void {
    if (cols <= 2) {
        try appendSpaces(out, cols);
        return;
    }

    const inner = cols - 2;
    const base = if (failure) |message|
        try std.fmt.allocPrint(out.allocator, " Ctrl-Q quit | {s} ", .{message})
    else
        try std.fmt.allocPrint(out.allocator, " Ctrl-Q quit | child is inside this frame ", .{});
    defer out.allocator.free(base);

    try out.append('+');
    if (base.len >= inner) {
        try out.appendSlice(base[0..inner]);
    } else {
        try out.appendSlice(base);
        try appendRepeated(out, '-', inner - @as(u16, @intCast(base.len)));
    }
    try out.append('+');
}

fn appendRenderedRow(
    out: *std.array_list.Managed(u8),
    render_state: *const ghostty_vt.RenderState,
    row_cells: std.MultiArrayList(ghostty_vt.RenderState.Cell),
    y: u16,
    width: u16,
) !void {
    const slice = row_cells.slice();
    const raw_cells = slice.items(.raw);
    const styles = slice.items(.style);
    const graphemes = slice.items(.grapheme);
    const cursor = render_state.cursor.viewport;

    for (0..width) |x_usize| {
        const x: u16 = @intCast(x_usize);
        if (x_usize >= raw_cells.len) {
            try appendStyledChar(
                out,
                render_state.colors.foreground,
                render_state.colors.background,
                .{},
                ' ',
            );
            continue;
        }

        const raw = raw_cells[x_usize];
        var style: ghostty_vt.Style = .{};
        if (raw.style_id > 0 or raw.content_tag == .bg_color_palette or raw.content_tag == .bg_color_rgb) {
            style = styles[x_usize];
        }

        var fg = style.fg(.{
            .default = render_state.colors.foreground,
            .palette = &render_state.colors.palette,
        });
        var bg = style.bg(&raw, &render_state.colors.palette) orelse render_state.colors.background;

        if (style.flags.inverse) {
            const swap = fg;
            fg = bg;
            bg = swap;
        }

        if (cursor) |cursor_pos| {
            if (cursor_pos.x == x and cursor_pos.y == y and render_state.cursor.visible) {
                const swap = fg;
                fg = bg;
                bg = swap;
            }
        }

        if (raw.wide == .spacer_tail or raw.wide == .spacer_head or style.flags.invisible) {
            try appendStyledChar(out, fg, bg, style.flags, ' ');
            continue;
        }

        try appendAnsiStyle(out, fg, bg, style.flags);
        if (raw.content_tag == .codepoint_grapheme and graphemes[x_usize].len > 0) {
            for (graphemes[x_usize]) |cp| try appendCodepoint(out, cp);
        } else if (raw.codepoint() != 0) {
            try appendCodepoint(out, raw.codepoint());
        } else {
            try out.append(' ');
        }
    }
    try out.appendSlice("\x1b[0m");
}

fn appendStyledChar(
    out: *std.array_list.Managed(u8),
    fg: anytype,
    bg: anytype,
    flags: anytype,
    ch: u8,
) !void {
    try appendAnsiStyle(out, fg, bg, flags);
    try out.append(ch);
}

fn appendAnsiStyle(out: *std.array_list.Managed(u8), fg: anytype, bg: anytype, flags: anytype) !void {
    const FlagsType = @TypeOf(flags);
    const bold = if (@hasField(FlagsType, "bold")) flags.bold else false;
    const italic = if (@hasField(FlagsType, "italic")) flags.italic else false;
    const faint = if (@hasField(FlagsType, "faint")) flags.faint else false;
    const underline = if (@hasField(FlagsType, "underline")) flags.underline != .none else false;
    const strikethrough = if (@hasField(FlagsType, "strikethrough")) flags.strikethrough else false;

    try out.writer().print(
        "\x1b[0{s}{s}{s}{s}{s};38;2;{};{};{};48;2;{};{};{}m",
        .{
            if (bold) ";1" else "",
            if (italic) ";3" else "",
            if (faint) ";2" else "",
            if (underline) ";4" else "",
            if (strikethrough) ";9" else "",
            fg.r,
            fg.g,
            fg.b,
            bg.r,
            bg.g,
            bg.b,
        },
    );
}

fn appendCodepoint(out: *std.array_list.Managed(u8), cp: u21) !void {
    var buf: [4]u8 = undefined;
    const len = try std.unicode.utf8Encode(cp, &buf);
    try out.appendSlice(buf[0..len]);
}

fn appendSpaces(out: *std.array_list.Managed(u8), count: u16) !void {
    try appendRepeated(out, ' ', count);
}

fn appendRepeated(out: *std.array_list.Managed(u8), ch: u8, count: u16) !void {
    for (0..count) |_| try out.append(ch);
}
