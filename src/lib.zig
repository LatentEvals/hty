const std = @import("std");
const builtin = @import("builtin");
pub const ghostty_vt = @import("ghostty-vt");
pub const Normalize = @import("Normalize");

// forkpty lives in <util.h> on macOS / BSD and <pty.h> on Linux.
// Pick the right header at comptime based on the target OS.
const c = @cImport({
    @cInclude("errno.h");
    @cInclude("signal.h");
    @cInclude("stdlib.h");
    @cInclude("sys/ioctl.h");
    @cInclude("sys/types.h");
    @cInclude("sys/wait.h");
    @cInclude("termios.h");
    @cInclude("unistd.h");
    if (builtin.os.tag == .linux) {
        @cInclude("pty.h");
    } else {
        @cInclude("util.h");
    }
});

pub const EnvVar = struct {
    key: []const u8,
    value: []const u8,
};

pub const CommandSpec = struct {
    program: []const u8,
    args: []const []const u8 = &.{},
};

pub const TerminalConfig = struct {
    rows: u16 = 24,
    cols: u16 = 80,
    scrollback: usize = 10_000,
    env: []const EnvVar = &.{},
    cwd: ?[]const u8 = null,
    emit_raw_bytes: bool = true,
    emit_screen_updates: bool = true,
    cell_width: u32 = 9,
    cell_height: u32 = 18,
};

pub const InputEvent = union(enum) {
    bytes: []const u8,
    text: []const u8,
    resize: struct {
        rows: u16,
        cols: u16,
    },
    close_stdin,
};

pub const OutputEvent = union(enum) {
    started,
    raw_bytes: []u8,
    screen_update,
    title_changed: []u8,
    bell,
    exited: ?i32,
    failure: []u8,

    pub fn deinit(self: *OutputEvent, alloc: std.mem.Allocator) void {
        switch (self.*) {
            .raw_bytes => |bytes| alloc.free(bytes),
            .title_changed => |title| alloc.free(title),
            .failure => |message| alloc.free(message),
            else => {},
        }
        self.* = undefined;
    }
};

pub const ScreenSnapshot = struct {
    rows: u16,
    cols: u16,
    cursor_row: u16,
    cursor_col: u16,
    title: ?[]u8,
    buffer: []const u8,
    screen_ansi: []const u8,
    lines: [][]const u8,
    /// Column-accurate grid. Always rectangular: `cells.len == rows` and
    /// every `cells[r].len == cols`. Each entry is a heap-allocated UTF-8
    /// grapheme string. Blank cells are `" "`, spacer tails of wide chars
    /// are `""`. Grapheme strings are NFC-normalized so combining
    /// sequences collapse to their precomposed form (e.g. `e + U+0301`
    /// becomes `"é"`, 2 bytes).
    cells: [][]const []const u8,

    pub fn deinit(self: *ScreenSnapshot, alloc: std.mem.Allocator) void {
        if (self.title) |title| alloc.free(title);
        for (self.cells) |row| {
            for (row) |cell| alloc.free(cell);
            alloc.free(row);
        }
        alloc.free(self.cells);
        alloc.free(self.lines);
        alloc.free(self.screen_ansi);
        alloc.free(self.buffer);
        self.* = undefined;
    }
};

pub const InteractiveTerminal = struct {
    alloc: std.mem.Allocator,
    terminal: ghostty_vt.Terminal,
    handler: ghostty_vt.TerminalStream.Handler,
    stream: ghostty_vt.TerminalStream,
    config: TerminalConfig,
    master_fd: std.posix.fd_t,
    child_pid: std.posix.pid_t,
    reader_thread: ?std.Thread = null,
    mutex: std.Thread.Mutex = .{},
    write_mutex: std.Thread.Mutex = .{},
    events: std.ArrayListUnmanaged(OutputEvent) = .{},
    closed: bool = false,
    exit_code: ?i32 = null,
    last_title: ?[]u8 = null,

    pub fn spawn(
        alloc: std.mem.Allocator,
        command: CommandSpec,
        config: TerminalConfig,
    ) !*InteractiveTerminal {
        const argv = try buildArgv(alloc, command);
        defer freeArgv(alloc, argv);

        const cwd_z = if (config.cwd) |cwd| try alloc.dupeZ(u8, cwd) else null;
        defer if (cwd_z) |cwd| alloc.free(cwd);

        const env_z = try buildEnv(alloc, config.env);
        defer freeEnv(alloc, env_z);

        var winsize = std.mem.zeroes(c.winsize);
        winsize.ws_row = config.rows;
        winsize.ws_col = config.cols;
        winsize.ws_xpixel = @intCast(config.cols * config.cell_width);
        winsize.ws_ypixel = @intCast(config.rows * config.cell_height);

        var master: c_int = -1;
        const pid = c.forkpty(&master, null, null, &winsize);
        if (pid < 0) return error.ForkPtyFailed;

        if (pid == 0) {
            if (cwd_z) |cwd| {
                _ = c.chdir(cwd.ptr);
            }
            for (env_z) |entry| {
                _ = c.setenv(entry.key.ptr, entry.value.ptr, 1);
            }
            _ = c.execvp(argv[0].?, @ptrCast(argv.ptr));
            c._exit(127);
        }

        // On the success path `deinit` (via `kill`) closes the fd and
        // reaps the child. These errdefers mirror that cleanup for any
        // parent-side failure below. Order matters: errdefers run in
        // reverse, so kill+reap must be registered *after* close so it
        // runs *before* close — we want the child gone before we drop
        // the master end.
        const child_pid: std.posix.pid_t = @intCast(pid);
        errdefer std.posix.close(master);
        errdefer {
            _ = c.kill(child_pid, c.SIGKILL);
            _ = std.posix.waitpid(child_pid, 0);
        }

        var self = try alloc.create(InteractiveTerminal);
        errdefer alloc.destroy(self);

        self.* = .{
            .alloc = alloc,
            .terminal = try ghostty_vt.Terminal.init(alloc, .{
                .cols = config.cols,
                .rows = config.rows,
                .max_scrollback = config.scrollback,
            }),
            .handler = undefined,
            .stream = undefined,
            .config = config,
            .master_fd = master,
            .child_pid = child_pid,
        };
        errdefer self.terminal.deinit(alloc);

        self.handler = self.terminal.vtHandler();
        self.stream = .initAlloc(alloc, self.handler);

        self.pushEvent(.started);
        self.reader_thread = try std.Thread.spawn(.{}, readerThreadMain, .{self});
        return self;
    }

    pub fn deinit(self: *InteractiveTerminal) void {
        _ = self.kill() catch {};
        if (self.reader_thread) |thread| {
            thread.join();
        }

        self.stream.deinit();
        self.terminal.deinit(self.alloc);
        if (self.last_title) |title| self.alloc.free(title);
        while (self.events.items.len > 0) {
            var event = self.events.pop().?;
            event.deinit(self.alloc);
        }
        self.events.deinit(self.alloc);
        self.alloc.destroy(self);
    }

    pub fn send(self: *InteractiveTerminal, input: InputEvent) !void {
        switch (input) {
            .bytes => |bytes| try self.writeAll(bytes),
            .text => |text| try self.writeAll(text),
            .resize => |size| try self.resize(size.rows, size.cols),
            .close_stdin => return error.CloseStdinUnsupported,
        }
    }

    pub fn resize(self: *InteractiveTerminal, rows: u16, cols: u16) !void {
        var winsize = std.mem.zeroes(c.winsize);
        winsize.ws_row = rows;
        winsize.ws_col = cols;
        winsize.ws_xpixel = @intCast(cols * self.config.cell_width);
        winsize.ws_ypixel = @intCast(rows * self.config.cell_height);

        if (c.ioctl(self.master_fd, c.TIOCSWINSZ, &winsize) == -1) {
            return error.ResizeFailed;
        }

        self.mutex.lock();
        defer self.mutex.unlock();
        try self.terminal.resize(self.alloc, cols, rows);
        self.config.rows = rows;
        self.config.cols = cols;
        if (self.config.emit_screen_updates) {
            self.pushEventUnlocked(.screen_update);
        }
    }

    pub fn snapshot(self: *InteractiveTerminal) !ScreenSnapshot {
        self.mutex.lock();
        defer self.mutex.unlock();

        const buffer = try self.terminal.plainString(self.alloc);
        errdefer self.alloc.free(buffer);

        const screen_ansi = try renderScreenAnsi(
            self.alloc,
            &self.terminal,
            self.config.rows,
            self.config.cols,
        );
        errdefer self.alloc.free(screen_ansi);

        const title = if (self.terminal.getTitle()) |value|
            try self.alloc.dupe(u8, value)
        else
            null;
        errdefer if (title) |owned| self.alloc.free(owned);

        var line_count: usize = 1;
        for (buffer) |ch| {
            if (ch == '\n') line_count += 1;
        }

        const lines = try self.alloc.alloc([]const u8, line_count);
        errdefer self.alloc.free(lines);

        var it = std.mem.splitScalar(u8, buffer, '\n');
        var index: usize = 0;
        while (it.next()) |line| : (index += 1) {
            lines[index] = line;
        }

        const cells = try buildCells(
            self.alloc,
            &self.terminal,
            self.config.rows,
            self.config.cols,
        );
        errdefer freeCells(self.alloc, cells);

        return .{
            .rows = self.config.rows,
            .cols = self.config.cols,
            .cursor_row = self.terminal.screens.active.cursor.y + 1,
            .cursor_col = self.terminal.screens.active.cursor.x + 1,
            .title = title,
            .buffer = buffer,
            .screen_ansi = screen_ansi,
            .lines = lines,
            .cells = cells,
        };
    }

    pub fn pollEvent(self: *InteractiveTerminal) ?OutputEvent {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.events.items.len == 0) return null;
        return self.events.orderedRemove(0);
    }

    pub fn kill(self: *InteractiveTerminal) !void {
        self.mutex.lock();
        const already_closed = self.closed;
        self.closed = true;
        self.mutex.unlock();

        if (!already_closed) {
            _ = c.kill(self.child_pid, c.SIGKILL);
            std.posix.close(self.master_fd);
        }
    }

    fn readerThreadMain(self: *InteractiveTerminal) void {
        self.readerLoop() catch |err| {
            self.pushErrorFmt("reader loop failed: {}", .{err});
        };
    }

    fn readerLoop(self: *InteractiveTerminal) !void {
        var buffer: [8192]u8 = undefined;

        while (true) {
            const n = std.posix.read(self.master_fd, &buffer) catch |err| switch (err) {
                error.InputOutput => break,
                error.NotOpenForReading => break,
                error.WouldBlock => continue,
                else => return err,
            };
            if (n == 0) break;

            if (self.config.emit_raw_bytes) {
                const bytes = try self.alloc.dupe(u8, buffer[0..n]);
                self.pushEvent(.{ .raw_bytes = bytes });
            }

            for (buffer[0..n]) |byte| {
                if (byte == 0x07) self.pushEvent(.bell);
            }

            self.mutex.lock();
            self.stream.nextSlice(buffer[0..n]);
            self.updateTitleEventUnlocked();
            if (self.config.emit_screen_updates) {
                self.pushEventUnlocked(.screen_update);
            }
            self.mutex.unlock();
        }

        const wait_result = std.posix.waitpid(self.child_pid, 0);
        const status = @as(c_int, @intCast(wait_result.status));
        const exit_code: ?i32 = if (c.WIFEXITED(status))
            c.WEXITSTATUS(status)
        else if (c.WIFSIGNALED(status))
            -c.WTERMSIG(status)
        else
            null;

        self.mutex.lock();
        self.exit_code = exit_code;
        self.closed = true;
        self.pushEventUnlocked(.{ .exited = exit_code });
        self.mutex.unlock();
    }

    fn writeAll(self: *InteractiveTerminal, bytes: []const u8) !void {
        self.write_mutex.lock();
        defer self.write_mutex.unlock();

        var index: usize = 0;
        while (index < bytes.len) {
            const written = try std.posix.write(self.master_fd, bytes[index..]);
            index += written;
        }
    }

    fn pushEvent(self: *InteractiveTerminal, event: OutputEvent) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.pushEventUnlocked(event);
    }

    fn pushEventUnlocked(self: *InteractiveTerminal, event: OutputEvent) void {
        self.events.append(self.alloc, event) catch {
            var dropped = event;
            dropped.deinit(self.alloc);
        };
    }

    fn pushErrorFmt(self: *InteractiveTerminal, comptime fmt: []const u8, args: anytype) void {
        const message = std.fmt.allocPrint(self.alloc, fmt, args) catch return;
        self.pushEvent(.{ .failure = message });
    }

    fn updateTitleEventUnlocked(self: *InteractiveTerminal) void {
        const current = self.terminal.getTitle() orelse "";
        const last = self.last_title orelse "";
        if (std.mem.eql(u8, current, last)) return;

        const owned = self.alloc.dupe(u8, current) catch return;
        if (self.last_title) |previous| self.alloc.free(previous);
        self.last_title = owned;

        const event_title = self.alloc.dupe(u8, current) catch return;
        self.pushEventUnlocked(.{ .title_changed = event_title });
    }
};

const SpawnEnv = struct {
    key: [:0]u8,
    value: [:0]u8,
};

fn buildArgv(
    alloc: std.mem.Allocator,
    command: CommandSpec,
) ![]?[*:0]u8 {
    const argv = try alloc.alloc(?[*:0]u8, command.args.len + 2);
    errdefer alloc.free(argv);

    const program = try alloc.dupeZ(u8, command.program);
    argv[0] = program.ptr;

    var built: usize = 1;
    errdefer {
        for (argv[0..built]) |maybe_ptr| {
            if (maybe_ptr) |ptr| {
                alloc.free(std.mem.span(ptr));
            }
        }
    }

    for (command.args, 0..) |arg, i| {
        const duped = try alloc.dupeZ(u8, arg);
        argv[i + 1] = duped.ptr;
        built += 1;
    }

    argv[command.args.len + 1] = null;
    return argv;
}

fn freeArgv(alloc: std.mem.Allocator, argv: []?[*:0]u8) void {
    for (argv) |maybe_ptr| {
        if (maybe_ptr) |ptr| {
            alloc.free(std.mem.span(ptr));
        }
    }
    alloc.free(argv);
}

fn buildEnv(
    alloc: std.mem.Allocator,
    env: []const EnvVar,
) ![]SpawnEnv {
    const has_term = hasEnvKey(env, "TERM");
    const extra_entries: usize = if (has_term) 0 else 1;
    const entries = try alloc.alloc(SpawnEnv, env.len + extra_entries);
    errdefer alloc.free(entries);

    var built: usize = 0;
    errdefer {
        for (entries[0..built]) |entry| {
            alloc.free(entry.key);
            alloc.free(entry.value);
        }
    }

    for (env, 0..) |entry, i| {
        entries[i] = .{
            .key = try alloc.dupeZ(u8, entry.key),
            .value = try alloc.dupeZ(u8, entry.value),
        };
        built += 1;
    }

    if (!has_term) {
        entries[built] = .{
            .key = try alloc.dupeZ(u8, "TERM"),
            .value = try alloc.dupeZ(u8, "xterm-256color"),
        };
        built += 1;
    }
    return entries;
}

fn freeEnv(alloc: std.mem.Allocator, env: []SpawnEnv) void {
    for (env) |entry| {
        alloc.free(entry.key);
        alloc.free(entry.value);
    }
    alloc.free(env);
}

fn hasEnvKey(env: []const EnvVar, needle: []const u8) bool {
    for (env) |entry| {
        if (std.mem.eql(u8, entry.key, needle)) return true;
    }
    return false;
}

/// Build a column-accurate `rows x cols` grid of UTF-8 grapheme strings.
///
/// Mirrors the iteration used by `renderScreenAnsi` but emits plain strings
/// instead of ANSI output. The caller owns every slice; free with
/// `freeCells`.
///
/// Per-cell rules (see the `cells` field on `SnapshotPayload` / the issue
/// acceptance criteria):
/// - Blank cell: `" "` (single space, one byte).
/// - Spacer tail/head of a wide character: `""` (empty string).
/// - `codepoint_grapheme`: concat all codepoints (base + combining marks)
///   and NFC-normalize the result, so `e + U+0301` folds into the
///   precomposed `"é"` (2 bytes: 0xc3 0xa9).
/// - Otherwise: the single codepoint encoded as UTF-8. Single-codepoint
///   cells are already in NFC by definition, so they aren't re-normalized.
///
/// Always rectangular: `result.len == rows`, every `result[r].len == cols`.
/// Rows that the engine doesn't have yet (beyond `render_rows.len`) and
/// columns that the row's cell slice doesn't cover are filled with `" "`.
pub fn buildCells(
    alloc: std.mem.Allocator,
    terminal: *ghostty_vt.Terminal,
    rows: u16,
    cols: u16,
) ![][]const []const u8 {
    var render_state: ghostty_vt.RenderState = .empty;
    defer render_state.deinit(alloc);
    try render_state.update(alloc, terminal);

    // Init the Unicode NFC normalizer once per snapshot. Per-cell init
    // would allocate the full Normalize tables on every grapheme, which
    // is orders of magnitude more expensive than the normalization itself.
    const normalize = try Normalize.init(alloc);
    defer normalize.deinit(alloc);

    const row_slice = render_state.row_data.slice();
    const render_rows = row_slice.items(.cells);

    var out = try alloc.alloc([]const []const u8, rows);
    var rows_built: usize = 0;
    errdefer {
        for (out[0..rows_built]) |row| {
            for (row) |cell| alloc.free(cell);
            alloc.free(row);
        }
        alloc.free(out);
    }

    for (0..rows) |y_usize| {
        var row = try alloc.alloc([]const u8, cols);
        var cells_built: usize = 0;
        errdefer {
            for (row[0..cells_built]) |cell| alloc.free(cell);
            alloc.free(row);
        }

        if (y_usize < render_rows.len) {
            const cell_slice = render_rows[y_usize].slice();
            const raw_cells = cell_slice.items(.raw);
            const graphemes = cell_slice.items(.grapheme);

            for (0..cols) |x_usize| {
                row[cells_built] = try renderCellString(alloc, &normalize, raw_cells, graphemes, x_usize);
                cells_built += 1;
            }
        } else {
            while (cells_built < cols) : (cells_built += 1) {
                row[cells_built] = try alloc.dupe(u8, " ");
            }
        }

        out[rows_built] = row;
        rows_built += 1;
    }

    return out;
}

fn renderCellString(
    alloc: std.mem.Allocator,
    normalize: *const Normalize,
    raw_cells: anytype,
    graphemes: anytype,
    x: usize,
) ![]u8 {
    if (x >= raw_cells.len) {
        return alloc.dupe(u8, " ");
    }
    const raw = raw_cells[x];
    if (raw.wide == .spacer_tail or raw.wide == .spacer_head) {
        return alloc.dupe(u8, "");
    }
    if (raw.content_tag == .codepoint_grapheme and graphemes[x].len > 0) {
        // `codepoint_grapheme` means the base char plus one or more
        // combining codepoints. Concat base + marks into the decomposed
        // form, then NFC-normalize so "e + U+0301" round-trips as the
        // precomposed "é" (2 bytes: 0xc3 0xa9) rather than 3 bytes of
        // decomposed `e` + combining acute. Agents comparing cell
        // contents to precomposed strings (the common case) need this.
        var buf = std.array_list.Managed(u8).init(alloc);
        defer buf.deinit();
        var tmp: [4]u8 = undefined;
        const base_cp = raw.codepoint();
        if (base_cp != 0) {
            const base_len = try std.unicode.utf8Encode(base_cp, &tmp);
            try buf.appendSlice(tmp[0..base_len]);
        }
        for (graphemes[x]) |cp| {
            const len = try std.unicode.utf8Encode(cp, &tmp);
            try buf.appendSlice(tmp[0..len]);
        }
        var result = try normalize.nfc(alloc, buf.items);
        defer result.deinit(alloc);
        return alloc.dupe(u8, result.slice);
    }
    const cp = raw.codepoint();
    if (cp == 0) return alloc.dupe(u8, " ");
    var tmp: [4]u8 = undefined;
    const len = try std.unicode.utf8Encode(cp, &tmp);
    return alloc.dupe(u8, tmp[0..len]);
}

pub fn freeCells(alloc: std.mem.Allocator, cells: [][]const []const u8) void {
    for (cells) |row| {
        for (row) |cell| alloc.free(cell);
        alloc.free(row);
    }
    alloc.free(cells);
}

pub fn renderScreenAnsi(
    alloc: std.mem.Allocator,
    terminal: *ghostty_vt.Terminal,
    rows: u16,
    cols: u16,
) ![]u8 {
    var render_state: ghostty_vt.RenderState = .empty;
    defer render_state.deinit(alloc);
    try render_state.update(alloc, terminal);

    var out = std.array_list.Managed(u8).init(alloc);
    defer out.deinit();

    const row_slice = render_state.row_data.slice();
    const render_rows = row_slice.items(.cells);

    for (0..rows) |y_usize| {
        const y: u16 = @intCast(y_usize);
        if (y_usize < render_rows.len) {
            try appendAnsiRenderedRow(&out, &render_state, render_rows[y_usize], y, cols);
        } else {
            try appendSpacesAnsi(&out, cols);
            try out.appendSlice("\x1b[0m");
        }

        if (y_usize + 1 < rows) try out.append('\n');
    }

    return out.toOwnedSlice();
}

fn appendAnsiRenderedRow(
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
    var current_style: ?AnsiStyleState = null;
    // Always render the full row width. Trimming to the last "significant"
    // column leaves the trailing cells unpainted, which shows through to
    // the observer's terminal background on rows with mostly-empty
    // content (vim's cursor row, status line, etc.), visually breaking
    // the screen into stripes of mismatched backgrounds.
    const effective_width = width;

    for (0..effective_width) |x_usize| {
        const x: u16 = @intCast(x_usize);
        if (x_usize >= raw_cells.len) {
            const next_style = ansiStyleState(
                render_state.colors.foreground,
                render_state.colors.background,
                .{},
            );
            try maybeAppendAnsiStyle(out, &current_style, next_style);
            try out.append(' ');
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

        const next_style = ansiStyleState(fg, bg, style.flags);
        try maybeAppendAnsiStyle(out, &current_style, next_style);

        if (raw.wide == .spacer_tail or raw.wide == .spacer_head or style.flags.invisible) {
            try out.append(' ');
            continue;
        }
        if (raw.content_tag == .codepoint_grapheme and graphemes[x_usize].len > 0) {
            for (graphemes[x_usize]) |cp| try appendCodepointAnsi(out, cp);
        } else if (raw.codepoint() != 0) {
            try appendCodepointAnsi(out, raw.codepoint());
        } else {
            try out.append(' ');
        }
    }

    if (effective_width > 0) {
        try out.appendSlice("\x1b[0m");
    }
}

const AnsiStyleState = struct {
    fg_r: u8,
    fg_g: u8,
    fg_b: u8,
    bg_r: u8,
    bg_g: u8,
    bg_b: u8,
    bold: bool,
    italic: bool,
    faint: bool,
    underline: bool,
    strikethrough: bool,
};

fn ansiStyleState(fg: anytype, bg: anytype, flags: anytype) AnsiStyleState {
    const FlagsType = @TypeOf(flags);
    return .{
        .fg_r = fg.r,
        .fg_g = fg.g,
        .fg_b = fg.b,
        .bg_r = bg.r,
        .bg_g = bg.g,
        .bg_b = bg.b,
        .bold = if (@hasField(FlagsType, "bold")) flags.bold else false,
        .italic = if (@hasField(FlagsType, "italic")) flags.italic else false,
        .faint = if (@hasField(FlagsType, "faint")) flags.faint else false,
        .underline = if (@hasField(FlagsType, "underline")) flags.underline != .none else false,
        .strikethrough = if (@hasField(FlagsType, "strikethrough")) flags.strikethrough else false,
    };
}

fn maybeAppendAnsiStyle(
    out: *std.array_list.Managed(u8),
    current: *?AnsiStyleState,
    next: AnsiStyleState,
) !void {
    if (current.*) |existing| {
        if (std.meta.eql(existing, next)) return;
    }
    current.* = next;
    try appendAnsiStyle(out, next);
}

fn appendAnsiStyle(out: *std.array_list.Managed(u8), style: AnsiStyleState) !void {
    try out.writer().print(
        "\x1b[0{s}{s}{s}{s}{s};38;2;{};{};{};48;2;{};{};{}m",
        .{
            if (style.bold) ";1" else "",
            if (style.italic) ";3" else "",
            if (style.faint) ";2" else "",
            if (style.underline) ";4" else "",
            if (style.strikethrough) ";9" else "",
            style.fg_r,
            style.fg_g,
            style.fg_b,
            style.bg_r,
            style.bg_g,
            style.bg_b,
        },
    );
}

fn appendCodepointAnsi(out: *std.array_list.Managed(u8), cp: u21) !void {
    var buf: [4]u8 = undefined;
    const len = try std.unicode.utf8Encode(cp, &buf);
    try out.appendSlice(buf[0..len]);
}

fn appendSpacesAnsi(out: *std.array_list.Managed(u8), count: u16) !void {
    for (0..count) |_| try out.append(' ');
}

test "spawn captures snapshot and exit" {
    var terminal = try InteractiveTerminal.spawn(std.heap.c_allocator, .{
        .program = "/bin/sh",
        .args = &.{ "-c", "printf 'hello from zig'" },
    }, .{
        .rows = 10,
        .cols = 40,
        .emit_raw_bytes = false,
    });
    defer terminal.deinit();

    try waitForText(terminal, "hello from zig", 2_000);
    var snapshot = try terminal.snapshot();
    defer snapshot.deinit(std.heap.c_allocator);

    try std.testing.expect(std.mem.indexOf(u8, snapshot.buffer, "hello from zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot.screen_ansi, "hello from zig") != null);
    try waitForExit(terminal, 2_000);
}

test "send forwards bytes through the pty" {
    var terminal = try InteractiveTerminal.spawn(std.heap.c_allocator, .{
        .program = "/bin/cat",
    }, .{
        .rows = 10,
        .cols = 40,
        .emit_raw_bytes = false,
    });
    defer terminal.deinit();

    try terminal.send(.{ .text = "ping from input\n" });
    try waitForText(terminal, "ping from input", 2_000);
}

test "title changes are emitted as events" {
    var terminal = try InteractiveTerminal.spawn(std.heap.c_allocator, .{
        .program = "/bin/sh",
        .args = &.{ "-c", "printf '\\033]2;zig-title\\033\\\\'; sleep 0.1" },
    }, .{
        .rows = 10,
        .cols = 40,
        .emit_raw_bytes = false,
    });
    defer terminal.deinit();

    try waitForTitleEvent(terminal, "zig-title", 2_000);
}

test "snapshot preserves ansi styling" {
    var terminal = try InteractiveTerminal.spawn(std.heap.c_allocator, .{
        .program = "/bin/sh",
        .args = &.{ "-c", "printf '\\033[31;47mhi\\033[0m'" },
    }, .{
        .rows = 5,
        .cols = 20,
        .emit_raw_bytes = false,
    });
    defer terminal.deinit();

    try waitForText(terminal, "hi", 2_000);
    var snapshot = try terminal.snapshot();
    defer snapshot.deinit(std.heap.c_allocator);

    try std.testing.expect(std.mem.indexOf(u8, snapshot.screen_ansi, "\x1b[") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot.screen_ansi, "38;2;") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot.screen_ansi, "48;2;") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot.screen_ansi, "hi") != null);
}

test "spawn: parent-side alloc failure reaps child and does not leak zombies" {
    // Reap anything the OS has queued for us from prior tests before we
    // start, so a later `waitpid(-1, ..., WNOHANG)` only sees children
    // this test itself produced.
    while (true) {
        var drain_status: c_int = 0;
        const drained = c.waitpid(-1, &drain_status, c.WNOHANG);
        if (drained <= 0) break;
    }

    // Count of successful allocations made *before* forkpty returns for
    // a `{ program: "/bin/sh", args: { "-c", "true" } }` spawn with an
    // empty env (buildEnv adds TERM since it's missing):
    //   buildArgv: argv slice + dupeZ("/bin/sh") + dupeZ("-c") + dupeZ("true") = 4
    //   buildEnv:  entries slice + dupeZ("TERM") + dupeZ("xterm-256color") = 3
    // fail_index = 7 lets forkpty run and then trips the very next
    // alloc, which is `alloc.create(InteractiveTerminal)` on the parent
    // side. That path is exactly what the new errdefers guard.
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{
        .fail_index = 7,
    });
    const alloc = failing.allocator();

    const result = InteractiveTerminal.spawn(alloc, .{
        .program = "/bin/sh",
        .args = &.{ "-c", "true" },
    }, .{
        .rows = 10,
        .cols = 40,
        .emit_raw_bytes = false,
        .emit_screen_updates = false,
    });
    try std.testing.expectError(error.OutOfMemory, result);

    // If the errdefer kill+waitpid ran, the child has already been
    // reaped and the OS reports ECHILD (waitpid returns -1). If the
    // errdefer *didn't* run, the child either (a) is still alive
    // (waitpid returns 0 with WNOHANG) or (b) has become a zombie
    // (waitpid returns pid > 0). Poll briefly so we don't race a
    // not-yet-dead child, but any positive return at all means we
    // leaked — we should never see the kernel hand us a reapable
    // child, because the errdefer should have already consumed it
    // inside `spawn`.
    const deadline = std.time.milliTimestamp() + 500;
    while (std.time.milliTimestamp() < deadline) {
        var status: c_int = 0;
        const waited = c.waitpid(-1, &status, c.WNOHANG);
        if (waited > 0) return error.ChildLeaked;
        if (waited == -1) return; // ECHILD — clean. Test passes.
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }
    return error.ChildNotReaped;
}

// ---------------------------------------------------------------------------
// `cells` tests (issue #25): column-accurate grid view in the snapshot.
// These feed fixed bytes into a fresh Terminal and assert on the grid
// directly, no PTY, no subprocess — deterministic across platforms.
// ---------------------------------------------------------------------------

const CellsHarness = struct {
    alloc: std.mem.Allocator,
    terminal: ghostty_vt.Terminal,
    stream: ghostty_vt.TerminalStream,
    cells: [][]const []const u8,

    fn init(alloc: std.mem.Allocator, rows: u16, cols: u16, input: []const u8) !CellsHarness {
        var terminal = try ghostty_vt.Terminal.init(alloc, .{
            .cols = cols,
            .rows = rows,
            .max_scrollback = 10_000,
        });
        errdefer terminal.deinit(alloc);
        var stream = ghostty_vt.TerminalStream.initAlloc(alloc, terminal.vtHandler());
        errdefer stream.deinit();
        stream.nextSlice(input);
        const cells = try buildCells(alloc, &terminal, rows, cols);
        return .{
            .alloc = alloc,
            .terminal = terminal,
            .stream = stream,
            .cells = cells,
        };
    }

    fn deinit(self: *CellsHarness) void {
        freeCells(self.alloc, self.cells);
        self.stream.deinit();
        self.terminal.deinit(self.alloc);
        self.* = undefined;
    }
};

test "cells: CJK occupies leading-cell + empty spacer tail" {
    const alloc = std.testing.allocator;
    var h = try CellsHarness.init(alloc, 24, 80, "日本語");
    defer h.deinit();

    try std.testing.expectEqual(@as(usize, 24), h.cells.len);
    try std.testing.expectEqual(@as(usize, 80), h.cells[0].len);

    try std.testing.expectEqualStrings("日", h.cells[0][0]);
    try std.testing.expectEqualStrings("", h.cells[0][1]);
    try std.testing.expectEqualStrings("本", h.cells[0][2]);
    try std.testing.expectEqualStrings("", h.cells[0][3]);
    try std.testing.expectEqualStrings("語", h.cells[0][4]);
    try std.testing.expectEqualStrings("", h.cells[0][5]);

    // Everything after the 6 visual columns is blank space.
    for (6..80) |col| try std.testing.expectEqualStrings(" ", h.cells[0][col]);
}

test "cells: combining marks fold into one cell" {
    const alloc = std.testing.allocator;
    // "e" + U+0301 (combining acute) — visually "é", a single grapheme.
    // The cell string is NFC-normalized, so what was stored as a base +
    // combining codepoint pair collapses to the 2-byte precomposed "é"
    // (0xc3 0xa9). This is the form agents naturally write in their
    // comparison strings.
    var h = try CellsHarness.init(alloc, 24, 80, "e\xcc\x81");
    defer h.deinit();

    try std.testing.expectEqualStrings("é", h.cells[0][0]);
    try std.testing.expectEqual(@as(usize, 2), h.cells[0][0].len);
    try std.testing.expectEqualStrings(" ", h.cells[0][1]);
}

test "cells: blank terminal is fully rectangular rows x cols of single-space cells" {
    const alloc = std.testing.allocator;
    var h = try CellsHarness.init(alloc, 8, 12, "");
    defer h.deinit();

    try std.testing.expectEqual(@as(usize, 8), h.cells.len);
    for (h.cells) |row| {
        try std.testing.expectEqual(@as(usize, 12), row.len);
        for (row) |cell| try std.testing.expectEqualStrings(" ", cell);
    }
}

test "cells: mixed ASCII + wide + ASCII keeps trailing ASCII at true visual column" {
    const alloc = std.testing.allocator;
    // "ASCII 日本語 END" — 19 bytes, 16 visual columns.
    // Visual layout (0-indexed):
    //   0:A 1:S 2:C 3:I 4:I 5:space
    //   6:日 7:"" 8:本 9:"" 10:語 11:""
    //   12:space 13:E 14:N 15:D
    var h = try CellsHarness.init(alloc, 24, 80, "ASCII 日本語 END");
    defer h.deinit();

    try std.testing.expectEqualStrings("A", h.cells[0][0]);
    try std.testing.expectEqualStrings("S", h.cells[0][1]);
    try std.testing.expectEqualStrings("C", h.cells[0][2]);
    try std.testing.expectEqualStrings("I", h.cells[0][3]);
    try std.testing.expectEqualStrings("I", h.cells[0][4]);
    try std.testing.expectEqualStrings(" ", h.cells[0][5]);
    try std.testing.expectEqualStrings("日", h.cells[0][6]);
    try std.testing.expectEqualStrings("", h.cells[0][7]);
    try std.testing.expectEqualStrings("本", h.cells[0][8]);
    try std.testing.expectEqualStrings("", h.cells[0][9]);
    try std.testing.expectEqualStrings("語", h.cells[0][10]);
    try std.testing.expectEqualStrings("", h.cells[0][11]);
    try std.testing.expectEqualStrings(" ", h.cells[0][12]);
    try std.testing.expectEqualStrings("E", h.cells[0][13]);
    try std.testing.expectEqualStrings("N", h.cells[0][14]);
    try std.testing.expectEqualStrings("D", h.cells[0][15]);
}

fn waitForText(
    terminal: *InteractiveTerminal,
    needle: []const u8,
    timeout_ms: u64,
) !void {
    const deadline = std.time.milliTimestamp() + @as(i64, @intCast(timeout_ms));
    while (std.time.milliTimestamp() < deadline) {
        var snapshot = try terminal.snapshot();
        defer snapshot.deinit(std.heap.c_allocator);
        if (std.mem.indexOf(u8, snapshot.buffer, needle) != null) return;
        std.Thread.sleep(25 * std.time.ns_per_ms);
    }
    return error.Timeout;
}

fn waitForExit(
    terminal: *InteractiveTerminal,
    timeout_ms: u64,
) !void {
    const deadline = std.time.milliTimestamp() + @as(i64, @intCast(timeout_ms));
    while (std.time.milliTimestamp() < deadline) {
        if (terminal.pollEvent()) |event| {
            defer {
                var owned = event;
                owned.deinit(std.heap.c_allocator);
            }
            if (event == .exited) return;
        }
        std.Thread.sleep(25 * std.time.ns_per_ms);
    }
    return error.Timeout;
}

fn waitForTitleEvent(
    terminal: *InteractiveTerminal,
    title: []const u8,
    timeout_ms: u64,
) !void {
    const deadline = std.time.milliTimestamp() + @as(i64, @intCast(timeout_ms));
    while (std.time.milliTimestamp() < deadline) {
        if (terminal.pollEvent()) |event| {
            defer {
                var owned = event;
                owned.deinit(std.heap.c_allocator);
            }
            switch (event) {
                .title_changed => |value| {
                    if (std.mem.eql(u8, value, title)) return;
                },
                else => {},
            }
        }
        std.Thread.sleep(25 * std.time.ns_per_ms);
    }
    return error.Timeout;
}
