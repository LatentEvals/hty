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

        // Everything the child needs is prepared before forking: the full
        // envp block and the PATH-resolved program path. The parent may be
        // multithreaded (the server), so between fork and execve the child
        // is only allowed async-signal-safe calls — no malloc (setenv) and
        // no PATH search (execvp).
        const envp = try buildEnvp(alloc, config.env);
        defer freeEnvp(alloc, envp);

        const exec_path = try resolveProgram(alloc, command.program, envp);
        defer alloc.free(exec_path);

        var winsize = std.mem.zeroes(c.winsize);
        winsize.ws_row = config.rows;
        winsize.ws_col = config.cols;
        winsize.ws_xpixel = @intCast(config.cols * config.cell_width);
        winsize.ws_ypixel = @intCast(config.rows * config.cell_height);

        var master: c_int = -1;
        const pid = c.forkpty(&master, null, null, &winsize);
        if (pid < 0) return error.ForkPtyFailed;

        if (pid == 0) {
            // Child: async-signal-safe calls only (chdir/execve/_exit) —
            // another thread of the parent may hold the malloc lock at
            // fork time, so anything that allocates can deadlock here.
            if (cwd_z) |cwd| {
                _ = c.chdir(cwd.ptr);
            }
            _ = c.execve(exec_path.ptr, @ptrCast(argv.ptr), @ptrCast(envp.ptr));
            c._exit(127);
        }

        // On the success path `deinit` (via `kill`) closes the master fd
        // and the reader thread reaps the child. These errdefers mirror
        // that cleanup for every parent-side failure below (issue #59).
        // errdefers run in reverse order: kill+reap fires before close so
        // the child is gone before we drop the master end of its pty.
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
        errdefer self.events.deinit(alloc);

        self.handler = self.terminal.vtHandler();
        self.stream = .initAlloc(alloc, self.handler);
        errdefer self.stream.deinit();

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
            if (written == 0) return error.ShortWrite;
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

/// Build the null-terminated `envp` block for `execve`, entirely in the
/// parent so the forked child never allocates. Reproduces what the old
/// fork-then-setenv dance produced: the parent's environment, with
/// `env` entries overriding parent values, plus `TERM=xterm-256color`
/// forced in unless `env` supplies its own TERM. When `env` repeats a
/// key the last occurrence wins, matching sequential setenv calls.
fn buildEnvp(
    alloc: std.mem.Allocator,
    env: []const EnvVar,
) ![]?[*:0]u8 {
    const has_term = hasEnvKey(env, "TERM");

    var list: std.ArrayListUnmanaged(?[*:0]u8) = .{};
    errdefer {
        for (list.items) |maybe_ptr| {
            if (maybe_ptr) |ptr| alloc.free(std.mem.span(ptr));
        }
        list.deinit(alloc);
    }

    var i: usize = 0;
    while (std.c.environ[i]) |parent_entry| : (i += 1) {
        const entry = std.mem.span(parent_entry);
        const key_len = std.mem.indexOfScalar(u8, entry, '=') orelse entry.len;
        const key = entry[0..key_len];
        if (hasEnvKey(env, key)) continue;
        if (!has_term and std.mem.eql(u8, key, "TERM")) continue;
        try list.ensureUnusedCapacity(alloc, 1);
        const duped = try alloc.dupeZ(u8, entry);
        list.appendAssumeCapacity(duped.ptr);
    }

    for (env, 0..) |entry, idx| {
        if (hasEnvKey(env[idx + 1 ..], entry.key)) continue;
        try list.ensureUnusedCapacity(alloc, 1);
        const joined = try std.fmt.allocPrintSentinel(alloc, "{s}={s}", .{ entry.key, entry.value }, 0);
        list.appendAssumeCapacity(joined.ptr);
    }

    if (!has_term) {
        try list.ensureUnusedCapacity(alloc, 1);
        const term = try alloc.dupeZ(u8, "TERM=xterm-256color");
        list.appendAssumeCapacity(term.ptr);
    }

    try list.append(alloc, null);
    return list.toOwnedSlice(alloc);
}

fn freeEnvp(alloc: std.mem.Allocator, envp: []?[*:0]u8) void {
    for (envp) |maybe_ptr| {
        if (maybe_ptr) |ptr| alloc.free(std.mem.span(ptr));
    }
    alloc.free(envp);
}

fn hasEnvKey(env: []const EnvVar, needle: []const u8) bool {
    for (env) |entry| {
        if (std.mem.eql(u8, entry.key, needle)) return true;
    }
    return false;
}

/// Look up `key` in an envp block built by `buildEnvp`.
fn envpGet(envp: []const ?[*:0]u8, key: []const u8) ?[]const u8 {
    for (envp) |maybe_ptr| {
        const entry = std.mem.span(maybe_ptr orelse continue);
        if (entry.len > key.len and entry[key.len] == '=' and
            std.mem.eql(u8, entry[0..key.len], key))
        {
            return entry[key.len + 1 ..];
        }
    }
    return null;
}

/// Resolve `program` against PATH the way execvp would, but in the parent
/// before forking, so the child can call execve directly. PATH is taken
/// from the merged envp (an `env` override of PATH is honored, exactly as
/// setenv-then-execvp honored it). If nothing matches, the bare name is
/// returned unchanged: the child's execve then fails and it exits 127,
/// preserving the old execvp failure behavior. Caller frees the result.
fn resolveProgram(
    alloc: std.mem.Allocator,
    program: []const u8,
    envp: []const ?[*:0]u8,
) ![:0]u8 {
    if (std.mem.indexOfScalar(u8, program, '/') != null or program.len == 0) {
        return alloc.dupeZ(u8, program);
    }

    const path = envpGet(envp, "PATH") orelse "/usr/bin:/bin";
    var it = std.mem.splitScalar(u8, path, ':');
    while (it.next()) |dir| {
        // POSIX: an empty PATH component means the current directory.
        const base = if (dir.len == 0) "." else dir;
        const candidate = try std.fmt.allocPrintSentinel(alloc, "{s}/{s}", .{ base, program }, 0);
        std.posix.accessZ(candidate, std.posix.X_OK) catch {
            alloc.free(candidate);
            continue;
        };
        return candidate;
    }
    return alloc.dupeZ(u8, program);
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

test "buildEnvp merges parent environ, applies overrides, injects TERM" {
    const alloc = std.testing.allocator;

    _ = c.setenv("HTY_ENVP_TEST_PARENT", "from-parent", 1);
    defer _ = c.unsetenv("HTY_ENVP_TEST_PARENT");
    _ = c.setenv("HTY_ENVP_TEST_OVERRIDE", "parent-value", 1);
    defer _ = c.unsetenv("HTY_ENVP_TEST_OVERRIDE");

    const envp = try buildEnvp(alloc, &.{
        .{ .key = "HTY_ENVP_TEST_OVERRIDE", .value = "stale" },
        .{ .key = "HTY_ENVP_TEST_OVERRIDE", .value = "child-value" },
    });
    defer freeEnvp(alloc, envp);

    // Terminated by exactly one null, and nothing before it is null.
    try std.testing.expect(envp[envp.len - 1] == null);
    for (envp[0 .. envp.len - 1]) |entry| try std.testing.expect(entry != null);

    // Parent entries survive; overridden keys appear exactly once with the
    // last duplicate winning; TERM is injected since no override set it.
    try std.testing.expectEqualStrings("from-parent", envpGet(envp, "HTY_ENVP_TEST_PARENT").?);
    try std.testing.expectEqualStrings("child-value", envpGet(envp, "HTY_ENVP_TEST_OVERRIDE").?);
    try std.testing.expectEqualStrings("xterm-256color", envpGet(envp, "TERM").?);

    var override_count: usize = 0;
    for (envp) |maybe_ptr| {
        const entry = std.mem.span(maybe_ptr orelse continue);
        if (std.mem.startsWith(u8, entry, "HTY_ENVP_TEST_OVERRIDE=")) override_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), override_count);
}

test "buildEnvp keeps a caller-supplied TERM instead of the default" {
    const alloc = std.testing.allocator;
    const envp = try buildEnvp(alloc, &.{
        .{ .key = "TERM", .value = "vt100" },
    });
    defer freeEnvp(alloc, envp);
    try std.testing.expectEqualStrings("vt100", envpGet(envp, "TERM").?);
}

test "resolveProgram searches PATH pre-fork and passes through paths and misses" {
    const alloc = std.testing.allocator;

    // A program containing '/' is used verbatim, no PATH search.
    const absolute = try resolveProgram(alloc, "/bin/sh", &.{null});
    defer alloc.free(absolute);
    try std.testing.expectEqualStrings("/bin/sh", absolute);

    // A bare name resolves against PATH from the envp.
    var path_entry = "PATH=/nonexistent-dir:/bin".*;
    const envp = [_]?[*:0]u8{ @ptrCast(&path_entry), null };
    const resolved = try resolveProgram(alloc, "sh", &envp);
    defer alloc.free(resolved);
    try std.testing.expectEqualStrings("/bin/sh", resolved);

    // A miss returns the bare name so the child still exits 127 via execve.
    const missing = try resolveProgram(alloc, "hty-no-such-program", &envp);
    defer alloc.free(missing);
    try std.testing.expectEqualStrings("hty-no-such-program", missing);
}

test "spawn: child inherits parent env and gets the TERM default" {
    _ = c.setenv("HTY_SPAWN_ENV_TEST", "inherited-ok", 1);
    defer _ = c.unsetenv("HTY_SPAWN_ENV_TEST");

    var terminal = try InteractiveTerminal.spawn(std.heap.c_allocator, .{
        .program = "/bin/sh",
        .args = &.{ "-c", "printf \"var=$HTY_SPAWN_ENV_TEST term=$TERM\"" },
    }, .{
        .rows = 10,
        .cols = 60,
        .emit_raw_bytes = false,
    });
    defer terminal.deinit();

    try waitForText(terminal, "var=inherited-ok term=xterm-256color", 2_000);
}

test "spawn: config env overrides parent env and TERM" {
    _ = c.setenv("HTY_SPAWN_ENV_TEST", "parent-value", 1);
    defer _ = c.unsetenv("HTY_SPAWN_ENV_TEST");

    var terminal = try InteractiveTerminal.spawn(std.heap.c_allocator, .{
        .program = "/bin/sh",
        .args = &.{ "-c", "printf \"var=$HTY_SPAWN_ENV_TEST term=$TERM\"" },
    }, .{
        .rows = 10,
        .cols = 60,
        .emit_raw_bytes = false,
        .env = &.{
            .{ .key = "HTY_SPAWN_ENV_TEST", .value = "override" },
            .{ .key = "TERM", .value = "vt100" },
        },
    });
    defer terminal.deinit();

    try waitForText(terminal, "var=override term=vt100", 2_000);
}

test "spawn: bare program name resolves against PATH" {
    var terminal = try InteractiveTerminal.spawn(std.heap.c_allocator, .{
        .program = "sh",
        .args = &.{ "-c", "printf 'resolved-via-path'" },
    }, .{
        .rows = 10,
        .cols = 40,
        .emit_raw_bytes = false,
    });
    defer terminal.deinit();

    try waitForText(terminal, "resolved-via-path", 2_000);
}

test "spawn: nonexistent program still exits 127" {
    var terminal = try InteractiveTerminal.spawn(std.heap.c_allocator, .{
        .program = "hty-definitely-not-a-real-program",
    }, .{
        .rows = 10,
        .cols = 40,
        .emit_raw_bytes = false,
    });
    defer terminal.deinit();

    const deadline = std.time.milliTimestamp() + 2_000;
    while (std.time.milliTimestamp() < deadline) {
        if (terminal.pollEvent()) |event| {
            defer {
                var owned = event;
                owned.deinit(std.heap.c_allocator);
            }
            switch (event) {
                .exited => |code| {
                    try std.testing.expectEqual(@as(?i32, 127), code);
                    return;
                },
                else => {},
            }
        }
        std.Thread.sleep(25 * std.time.ns_per_ms);
    }
    return error.Timeout;
}

test "spawn: failure on any parent-side error path leaks no memory, fd, or child" {
    // Drain zombies left by earlier tests so the ECHILD check below only
    // sees children created here.
    while (c.waitpid(-1, null, c.WNOHANG) > 0) {}

    const fds_before = try countOpenFds();

    // Walk the failure through every allocation spawn makes, from the
    // first (pre-fork argv/envp building) to the last (post-fork terminal
    // setup, the paths issue #59 is about), until a spawn finally
    // succeeds. After each induced failure the child must already be
    // killed and reaped (waitpid reports ECHILD) and, at the end, no fd
    // or memory may have leaked. Backed by std.testing.allocator so any
    // leak on any path fails the test.
    var spawned = false;
    var fail_index: usize = 0;
    while (fail_index < 10_000) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{
            .fail_index = fail_index,
        });
        if (InteractiveTerminal.spawn(failing.allocator(), .{
            .program = "/bin/sh",
            .args = &.{ "-c", "sleep 5" },
        }, .{
            .rows = 4,
            .cols = 20,
            .scrollback = 0,
            .emit_raw_bytes = false,
            .emit_screen_updates = false,
        })) |terminal| {
            terminal.deinit();
            spawned = true;
            break;
        } else |err| {
            if (err != error.OutOfMemory) return err;
            // spawn's errdefer reaps the child synchronously before the
            // error is returned, so the kernel must report no children at
            // all. 0 (a live child) or a pid (a zombie) means we leaked.
            try std.testing.expectEqual(@as(c.pid_t, -1), c.waitpid(-1, null, c.WNOHANG));
        }
    }
    try std.testing.expect(spawned);

    const fds_after = try countOpenFds();
    try std.testing.expectEqual(fds_before, fds_after);
}

fn countOpenFds() !usize {
    var dir = try std.fs.openDirAbsolute("/dev/fd", .{ .iterate = true });
    defer dir.close();
    var it = dir.iterate();
    var count: usize = 0;
    while (try it.next()) |_| count += 1;
    return count;
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
