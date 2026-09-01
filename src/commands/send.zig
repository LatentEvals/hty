//! `hty send` — send text, a key, hex bytes, or a mixed `--seq` sequence
//! to a session.

const std = @import("std");
const sys = @import("hty").sys;
const Allocator = std.mem.Allocator;

const common = @import("common.zig");
const keyToBytes = @import("../keys.zig").keyToBytes;

pub fn helpText() []const u8 {
    return
    \\hty send [SESSION] --text "..." | --raw-text "..." | --key NAME | --seq "..." | --bytes-hex HEX
    \\                   | --click ROW COL | --scroll up|down
    \\
    \\Send input to a session. At least one input flag is required.
    \\The keyboard input flags (--text, --raw-text, --key, --seq,
    \\--bytes-hex) may be repeated and combined; they execute in the
    \\order given, as one sequence. Example:
    \\  hty send S --key esc --text ':wq' --key enter
    \\Mouse input (--click, --scroll) cannot be combined with keyboard
    \\input flags or with each other.
    \\
    \\Flags:
    \\  --text STRING        UTF-8 text with C-style escapes (\n \t \r \\ \e).
    \\  --raw-text STRING    UTF-8 bytes sent verbatim. No escape processing —
    \\                       `\n` stays as literal backslash-n. Use this when
    \\                       you want to type source code or other content that
    \\                       contains backslashes you don't want interpreted.
    \\                       Prefer over --text when shell quoting gets hairy.
    \\  --key NAME           Named key with optional modifiers.
    \\                       Supports ctrl-, alt-/meta-, shift- prefixes,
    \\                       function keys (f1-f12), and combinations like
    \\                       ctrl-alt-f or shift-up. Run `hty keys` for details.
    \\                       May be repeated; the keys are sent in order,
    \\                       equivalent to the same names in --seq.
    \\  --seq STRING         Send a sequence of keys, text, and delays in one call.
    \\                       Quoted strings are text, durations (e.g. 200ms, 1s)
    \\                       are pauses, and bare words are key names. A bare
    \\                       word that is not a key name is typed literally
    \\                       (tmux send-keys convention) — key names win, so
    \\                       quote a literal "enter".
    \\                       Quoted strings are literal — backslash escapes
    \\                       like \n are rejected (use --text for C-style
    \\                       escapes, or --raw-text to send backslashes
    \\                       verbatim).
    \\                       Example: --seq '"hello" 200ms enter 500ms "world"'
    \\  --bytes-hex HEX      Raw bytes encoded as hex.
    \\
    \\Mouse input (issue #24). Rows and columns are 1-indexed, matching
    \\snapshot conventions. The target app must have enabled mouse mode
    \\(the usual `CSI ?1000/1002/1003 h` sequences); otherwise the
    \\command fails with "target app has not enabled mouse input". Check
    \\`hty snapshot --json`'s `mouse.enabled` to verify.
    \\  --click ROW COL      Click at ROW/COL. Defaults to left button;
    \\                       combine with --button to change.
    \\  --scroll up|down     Scroll at the cursor (or --at ROW COL); emits
    \\                       --amount N events (default 1).
    \\  --button B           Button for --click: left (default),
    \\                       right, middle.
    \\  --at ROW COL         Row/col for --scroll. Defaults to 1 1.
    \\  --amount N           Repeat count for --scroll. Default 1.
    \\
    \\Delay flags (optional, combine with any mode above):
    \\  --delay-before DUR   Sleep before sending (e.g. 200ms, 1s).
    \\  --delay-after DUR    Sleep after sending.
    \\  --delay-char DUR     Send text character-by-character with a delay
    \\                       between each. Only works with --text, --raw-text,
    \\                       or --seq.
    \\
    \\Wait + snapshot flags (fuse send + wait + snapshot into one round-trip):
    \\  --snapshot           Include the post-action snapshot in the response.
    \\                       Combines with --json and --ansi like `hty snapshot`.
    \\                       Without an explicit --wait-* flag this implies
    \\                       --wait-until-idle 100 so the frame reflects the
    \\                       input just sent; pass --no-wait for the immediate
    \\                       (possibly stale) frame.
    \\  --no-wait            With --snapshot, capture the frame immediately
    \\                       instead of the implied --wait-until-idle 100.
    \\  --wait-duration DUR  Sleep DUR after sending, then snapshot. Requires
    \\                       --snapshot (otherwise use --delay-after).
    \\  --wait-until-idle [MS]
    \\                       Block until the screen has been quiet for MS
    \\                       milliseconds (default 100). The idle window is
    \\                       measured from the moment this op begins on the
    \\                       server, so a session that was already quiet
    \\                       before the send won't trip the check immediately.
    \\  --wait-until-text STR    Block until STR appears in the rendered buffer.
    \\  --wait-until-regex RE    Block until RE (POSIX extended) matches.
    \\  --wait-until-exit        Block until the child process exits.
    \\  --timeout DUR        Cap on any --wait-until-* (default 30s; 0 = none).
    \\  --diff               With --snapshot, print only rows changed since
    \\                       the previous --diff snapshot of the session
    \\                       (`hty snapshot --diff` format and baseline).
    \\  --json               With --snapshot, emit `{ok, matched, elapsed_ms,
    \\                       snapshot, ...}` instead of the plain buffer.
    \\  --ansi               With --snapshot, print the styled ANSI rendering
    \\                       instead of the plain buffer.
    \\  --lines N:M          With --snapshot, print only rows N through M
    \\                       (1-indexed, inclusive). Open ends allowed: `N:`
    \\                       reads to the last row, `:M` from the first. Rows
    \\                       past the end of the screen are clamped. Not
    \\                       valid with --json. Tip: editors show status
    \\                       lines and prompts on the LAST rows — `1:12`
    \\                       misses a prompt on row 24; prefer `N:`.
    \\
    ;
}

/// Assign a single-value flag slot, rejecting a second occurrence so a
/// repeated flag never silently overwrites the first value.
pub fn run(alloc: Allocator, io: std.Io, args: []const []const u8) !void {
    var session_ref: ?[]const u8 = null;
    var inputs_buf: [256]InputSpec = undefined;
    var inputs_len: usize = 0;
    var delay_before: ?[]const u8 = null;
    var delay_after: ?[]const u8 = null;
    var delay_char: ?[]const u8 = null;

    // Mouse input flags. Coordinate pairs are stored as parsed u32s;
    // --click and --scroll consume 2 positional values each. See issue #24.
    var click_row: ?u32 = null;
    var click_col: ?u32 = null;
    var scroll_dir: ?[]const u8 = null;
    var scroll_at_row: u32 = 1;
    var scroll_at_col: u32 = 1;
    var scroll_amount: u32 = 1;
    var mouse_button: []const u8 = "left";

    var snapshot_flag = false;
    var no_wait = false;
    var diff_flag = false;
    var json_output = false;
    var ansi_output = false;
    var lines_range: ?common.LineRange = null;
    var wait_duration_str: ?[]const u8 = null;
    var wait_until_idle = false;
    var wait_until_idle_ms_str: ?[]const u8 = null;
    var wait_until_text: ?[]const u8 = null;
    var wait_until_regex: ?[]const u8 = null;
    var wait_until_exit = false;
    var timeout_str: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        const input_kind: ?InputKind = if (std.mem.eql(u8, arg, "--text"))
            .text
        else if (std.mem.eql(u8, arg, "--raw-text"))
            .raw_text
        else if (std.mem.eql(u8, arg, "--key"))
            .key
        else if (std.mem.eql(u8, arg, "--bytes-hex"))
            .bytes_hex
        else if (std.mem.eql(u8, arg, "--seq"))
            .seq
        else
            null;
        if (input_kind) |kind| {
            i += 1;
            if (i >= args.len) {
                try common.printErrFmt("{s} requires a value", .{arg});
                std.process.exit(common.ExitCode.generic);
            }
            if (inputs_len >= inputs_buf.len) return common.printUsageAndExit("too many input flags in one call");
            inputs_buf[inputs_len] = .{ .kind = kind, .value = args[i] };
            inputs_len += 1;
        } else if (std.mem.eql(u8, arg, "--delay-before")) {
            i += 1;
            if (i >= args.len) return common.printUsageAndExit("--delay-before requires a value");
            delay_before = args[i];
        } else if (std.mem.eql(u8, arg, "--delay-after")) {
            i += 1;
            if (i >= args.len) return common.printUsageAndExit("--delay-after requires a value");
            delay_after = args[i];
        } else if (std.mem.eql(u8, arg, "--delay-char")) {
            i += 1;
            if (i >= args.len) return common.printUsageAndExit("--delay-char requires a value");
            delay_char = args[i];
        } else if (std.mem.eql(u8, arg, "--snapshot")) {
            snapshot_flag = true;
        } else if (std.mem.eql(u8, arg, "--no-wait")) {
            no_wait = true;
        } else if (std.mem.eql(u8, arg, "--diff")) {
            diff_flag = true;
        } else if (std.mem.eql(u8, arg, "--json")) {
            json_output = true;
        } else if (std.mem.eql(u8, arg, "--ansi")) {
            ansi_output = true;
        } else if (std.mem.eql(u8, arg, "--lines")) {
            i += 1;
            if (i >= args.len) return common.printUsageAndExit("--lines requires a value (N:M, N:, or :M)");
            lines_range = common.parseLineRange(args[i]) catch
                return common.printUsageAndExit("invalid --lines range: expected N:M, N:, or :M with 1-indexed rows and N <= M");
        } else if (std.mem.eql(u8, arg, "--wait-duration")) {
            i += 1;
            if (i >= args.len) return common.printUsageAndExit("--wait-duration requires a value");
            wait_duration_str = args[i];
        } else if (std.mem.eql(u8, arg, "--wait-until-idle")) {
            wait_until_idle = true;
            // Optional positional value: consume the next arg only if it
            // looks like a duration (digit-prefixed). Otherwise leave it
            // for the next flag/positional slot.
            if (i + 1 < args.len and looksLikeDurationArg(args[i + 1])) {
                i += 1;
                wait_until_idle_ms_str = args[i];
            }
        } else if (std.mem.eql(u8, arg, "--wait-until-text")) {
            i += 1;
            if (i >= args.len) return common.printUsageAndExit("--wait-until-text requires a value");
            wait_until_text = args[i];
        } else if (std.mem.eql(u8, arg, "--wait-until-regex")) {
            i += 1;
            if (i >= args.len) return common.printUsageAndExit("--wait-until-regex requires a value");
            wait_until_regex = args[i];
        } else if (std.mem.eql(u8, arg, "--wait-until-exit")) {
            wait_until_exit = true;
        } else if (std.mem.eql(u8, arg, "--timeout")) {
            i += 1;
            if (i >= args.len) return common.printUsageAndExit("--timeout requires a value");
            timeout_str = args[i];
        } else if (std.mem.eql(u8, arg, "--click")) {
            if (i + 2 >= args.len) return common.printUsageAndExit("--click requires ROW and COL");
            click_row = parseUInt(args[i + 1]) catch return common.printUsageAndExit("--click ROW must be a positive integer");
            click_col = parseUInt(args[i + 2]) catch return common.printUsageAndExit("--click COL must be a positive integer");
            i += 2;
        } else if (std.mem.eql(u8, arg, "--scroll")) {
            i += 1;
            if (i >= args.len) return common.printUsageAndExit("--scroll requires up|down");
            if (!std.mem.eql(u8, args[i], "up") and !std.mem.eql(u8, args[i], "down")) {
                return common.printUsageAndExit("--scroll argument must be 'up' or 'down'");
            }
            scroll_dir = args[i];
        } else if (std.mem.eql(u8, arg, "--at")) {
            if (i + 2 >= args.len) return common.printUsageAndExit("--at requires ROW and COL");
            scroll_at_row = parseUInt(args[i + 1]) catch return common.printUsageAndExit("--at ROW must be a positive integer");
            scroll_at_col = parseUInt(args[i + 2]) catch return common.printUsageAndExit("--at COL must be a positive integer");
            i += 2;
        } else if (std.mem.eql(u8, arg, "--amount")) {
            i += 1;
            if (i >= args.len) return common.printUsageAndExit("--amount requires a value");
            scroll_amount = parseUInt(args[i]) catch return common.printUsageAndExit("--amount must be a positive integer");
        } else if (std.mem.eql(u8, arg, "--button")) {
            i += 1;
            if (i >= args.len) return common.printUsageAndExit("--button requires a value");
            if (!std.mem.eql(u8, args[i], "left") and !std.mem.eql(u8, args[i], "right") and !std.mem.eql(u8, args[i], "middle")) {
                return common.printUsageAndExit("--button must be one of left, right, middle");
            }
            mouse_button = args[i];
        } else if (std.mem.startsWith(u8, arg, "--")) {
            try common.printErrFmt("unknown flag: {s}", .{arg});
            std.process.exit(common.ExitCode.generic);
        } else if (session_ref == null) {
            session_ref = arg;
        } else {
            try common.printErrFmt("unexpected argument: {s}", .{arg});
            std.process.exit(common.ExitCode.generic);
        }
    }

    // Validate the new wait/snapshot flag combinations before doing any I/O.
    var wait_kind_count: u8 = 0;
    if (wait_until_idle) wait_kind_count += 1;
    if (wait_until_text != null) wait_kind_count += 1;
    if (wait_until_regex != null) wait_kind_count += 1;
    if (wait_until_exit) wait_kind_count += 1;
    if (wait_kind_count > 1) {
        try common.printErr("at most one of --wait-until-idle, --wait-until-text, --wait-until-regex, --wait-until-exit may be supplied");
        std.process.exit(common.ExitCode.generic);
    }
    if (wait_duration_str != null and wait_kind_count > 0) {
        try common.printErr("--wait-duration is incompatible with --wait-until-*");
        std.process.exit(common.ExitCode.generic);
    }
    if (wait_duration_str != null and !snapshot_flag) {
        try common.printErr("--wait-duration without --snapshot is just a delay; use --delay-after, or add --snapshot");
        std.process.exit(common.ExitCode.generic);
    }
    if (no_wait and (wait_kind_count > 0 or wait_duration_str != null)) {
        try common.printErr("--no-wait is incompatible with --wait-duration/--wait-until-*");
        std.process.exit(common.ExitCode.generic);
    }
    if (no_wait and !snapshot_flag) {
        try common.printErr("--no-wait requires --snapshot");
        std.process.exit(common.ExitCode.generic);
    }
    if ((json_output or ansi_output) and !snapshot_flag) {
        try common.printErr("--json and --ansi require --snapshot");
        std.process.exit(common.ExitCode.generic);
    }
    if (lines_range != null and !snapshot_flag) {
        try common.printErr("--lines requires --snapshot");
        std.process.exit(common.ExitCode.generic);
    }
    if (lines_range != null and json_output) {
        try common.printErr("--lines is incompatible with --json (the JSON response always carries the full snapshot)");
        std.process.exit(common.ExitCode.generic);
    }

    // A fused snapshot with no explicit wait races the program's redraw and
    // can return a stale frame (issue #96). Imply the default idle settle so
    // the frame reflects the input just sent; --no-wait restores the
    // immediate capture.
    if (shouldImplyIdleSettle(snapshot_flag, no_wait, wait_kind_count, wait_duration_str != null)) {
        wait_until_idle = true;
        wait_kind_count = 1;
    }
    if (json_output and ansi_output) {
        try common.printErr("--json and --ansi are mutually exclusive");
        std.process.exit(common.ExitCode.generic);
    }
    if (diff_flag and !snapshot_flag) {
        try common.printErr("--diff requires --snapshot");
        std.process.exit(common.ExitCode.generic);
    }
    if (diff_flag and (json_output or ansi_output)) {
        try common.printErr("--diff is incompatible with --json and --ansi");
        std.process.exit(common.ExitCode.generic);
    }
    if (diff_flag and lines_range != null) {
        try common.printErr("--lines with --diff is only supported on `hty snapshot`");
        std.process.exit(common.ExitCode.generic);
    }

    // Count mouse-mode flags separately: they're mutually exclusive with
    // the keyboard/text input modes and with each other.
    var mouse_mode_count: u8 = 0;
    if (click_row != null) mouse_mode_count += 1;
    if (scroll_dir != null) mouse_mode_count += 1;

    if (mouse_mode_count == 0 and inputs_len == 0) {
        try common.printErr("hty send requires at least one of --text, --raw-text, --key, --bytes-hex, --seq, --click, --scroll");
        std.process.exit(common.ExitCode.generic);
    }
    if (mouse_mode_count > 1) {
        try common.printErr("hty send: --click and --scroll are mutually exclusive");
        std.process.exit(common.ExitCode.generic);
    }
    if (mouse_mode_count > 0 and inputs_len > 0) {
        try common.printErr("hty send: --click/--scroll cannot be combined with keyboard input flags");
        std.process.exit(common.ExitCode.generic);
    }

    // Mouse-mode path: dispatch send_mouse RPCs and we're done (no fused
    // wait/snapshot for now; those still compose with keyboard modes the
    // same way they did before). We return before the keyboard token
    // pipeline below.
    if (mouse_mode_count == 1) {
        try runMouseMode(alloc, io, session_ref, .{
            .click_row = click_row,
            .click_col = click_col,
            .scroll_dir = scroll_dir,
            .scroll_at_row = scroll_at_row,
            .scroll_at_col = scroll_at_col,
            .scroll_amount = scroll_amount,
            .button = mouse_button,
            .delay_before_ms = if (delay_before) |d| common.parseDurationMs(d) catch 0 else 0,
            .delay_after_ms = if (delay_after) |d| common.parseDurationMs(d) catch 0 else 0,
        });

        // Mouse modes still compose with --snapshot / --wait-* the same way
        // keyboard modes do.
        if (snapshot_flag or wait_kind_count > 0 or wait_duration_str != null) {
            const wait_kind: []const u8 = if (wait_until_idle)
                "idle"
            else if (wait_until_text != null)
                "text"
            else if (wait_until_regex != null)
                "regex"
            else if (wait_until_exit)
                "exit"
            else if (wait_duration_str != null)
                "duration"
            else
                "none";
            const timeout_ms: u64 = if (timeout_str) |t| common.parseDurationMs(t) catch 30_000 else 30_000;
            const idle_ms: u64 = if (wait_until_idle_ms_str) |s| parseIdleArg(s) catch 100 else 100;
            const duration_ms: u64 = if (wait_duration_str) |d| common.parseDurationMs(d) catch 0 else 0;
            const needle: ?[]const u8 = wait_until_text orelse wait_until_regex;
            try issueFusedWait(alloc, io, .{
                .session_ref = session_ref,
                .wait_kind = wait_kind,
                .needle = needle,
                .idle_ms = idle_ms,
                .duration_ms = duration_ms,
                .timeout_ms = timeout_ms,
                .snapshot = snapshot_flag,
                .diff = diff_flag,
                .json_output = json_output,
                .ansi_output = ansi_output,
                .lines = lines_range,
            });
        }
        return;
    }

    if (inputs_len == 0) {
        try common.printErr("hty send requires at least one of --text, --raw-text, --key, --bytes-hex, --seq");
        std.process.exit(common.ExitCode.generic);
    }

    // Parse delay flags.
    const before_ms: u64 = if (delay_before) |d| common.parseDurationMs(d) catch {
        try common.printErr("invalid --delay-before value");
        std.process.exit(common.ExitCode.generic);
        unreachable;
    } else 0;
    const after_ms: u64 = if (delay_after) |d| common.parseDurationMs(d) catch {
        try common.printErr("invalid --delay-after value");
        std.process.exit(common.ExitCode.generic);
        unreachable;
    } else 0;
    const char_ms: u64 = if (delay_char) |d| common.parseDurationMs(d) catch {
        try common.printErr("invalid --delay-char value");
        std.process.exit(common.ExitCode.generic);
        unreachable;
    } else 0;

    const has_text_like = blk: {
        for (inputs_buf[0..inputs_len]) |spec| switch (spec.kind) {
            .text, .raw_text, .seq => break :blk true,
            .key, .bytes_hex => {},
        };
        break :blk false;
    };
    if (char_ms > 0 and !has_text_like) {
        try common.printErr("--delay-char only applies to --text, --raw-text, or --seq");
        std.process.exit(common.ExitCode.generic);
    }

    // Build token list — every input flag appends to one sequence,
    // executed in argv order.
    var token_list = buildInputTokens(alloc, inputs_buf[0..inputs_len]) catch |err| {
        const msg: []const u8 = switch (err) {
            error.InvalidSeq => "invalid --seq syntax: unmatched quote",
            error.EmptySeq => "--seq requires at least one token",
            error.SeqEscaped => "quoted --seq strings are literal; backslash sequences like \\n are NOT interpreted, so nothing was sent. Use --text for C-style escapes, or --text with \\\\n (escaped backslash) / --raw-text to intentionally send a literal backslash sequence.",
            error.TooManyTokens => "too much input in one hty send call",
            error.InvalidEscape => "invalid escape sequence in --text value",
            error.OutOfMemory => return err,
        };
        try common.printErr(msg);
        std.process.exit(common.ExitCode.generic);
        unreachable;
    };

    // Validate key tokens client-side (issue #102): reject before anything
    // is sent, naming the offending token. --seq key tokens are already
    // validated by bareWordsToText, so any invalid key came from --key.
    if (try findInvalidKeyToken(alloc, token_list)) |bad_key| {
        const msg = try invalidKeyMessage(alloc, "--key", bad_key);
        defer alloc.free(msg);
        try common.printErr(msg);
        std.process.exit(common.ExitCode.generic);
    }

    // Expand --delay-char: split text tokens into per-character tokens
    // with delay tokens interleaved.
    if (char_ms > 0) {
        token_list = expandDelayChar(token_list, char_ms);
    }

    // Prepend delay-before, append delay-after.
    if (before_ms > 0 or after_ms > 0) {
        var final: SeqTokenList = .{};
        if (before_ms > 0) {
            final.tokens[final.len] = .{ .kind = .delay, .value = "", .delay_ms = before_ms };
            final.len += 1;
        }
        for (token_list.slice()) |token| {
            if (final.len >= final.tokens.len) break;
            final.tokens[final.len] = token;
            final.len += 1;
        }
        if (after_ms > 0 and final.len < final.tokens.len) {
            final.tokens[final.len] = .{ .kind = .delay, .value = "", .delay_ms = after_ms };
            final.len += 1;
        }
        token_list = final;
    }

    // Execute the token list.
    for (token_list.slice()) |token| {
        if (token.kind == .delay) {
            sys.sleep(token.delay_ms * std.time.ns_per_ms);
            continue;
        }

        var payload_buf: std.Io.Writer.Allocating = .init(alloc);
        defer payload_buf.deinit();
        const writer = &payload_buf.writer;

        switch (token.kind) {
            .text => {
                try writer.writeAll("{\"op\":\"send_text\",\"text\":");
                try common.writeJsonString(writer, token.value);
            },
            .key => {
                try writer.writeAll("{\"op\":\"send_key\",\"key\":");
                try common.writeJsonString(writer, token.value);
            },
            .bytes_hex => {
                try writer.writeAll("{\"op\":\"send_bytes_hex\",\"bytes_hex\":");
                try common.writeJsonString(writer, token.value);
            },
            .delay => unreachable,
        }

        if (session_ref) |sr| {
            try writer.writeAll(",\"session\":");
            try common.writeJsonString(writer, sr);
        }
        try writer.writeAll("}");

        const response_line = try common.sendRawRequest(alloc, io, payload_buf.writer.buffered());
        defer alloc.free(response_line);

        var parsed = try std.json.parseFromSlice(std.json.Value, alloc, response_line, .{});
        defer parsed.deinit();
        _ = try common.expectOkOrExit(parsed);
    }

    // Fused wait + snapshot. After the input tokens have all landed in the
    // PTY, optionally issue one wait_and_snapshot RPC. The new server op
    // measures idle from the moment the request begins (not from the last
    // raw screen change), which is at-or-after the moment the previous
    // send_text RPCs returned — so a session that was already idle before
    // the send won't immediately satisfy --wait-until-idle.
    if (snapshot_flag or wait_kind_count > 0 or wait_duration_str != null) {
        const wait_kind: []const u8 = if (wait_until_idle)
            "idle"
        else if (wait_until_text != null)
            "text"
        else if (wait_until_regex != null)
            "regex"
        else if (wait_until_exit)
            "exit"
        else if (wait_duration_str != null)
            "duration"
        else
            "none";

        const timeout_ms: u64 = if (timeout_str) |t| common.parseDurationMs(t) catch {
            try common.printErr("invalid --timeout value");
            std.process.exit(common.ExitCode.generic);
            unreachable;
        } else 30_000;

        const idle_ms: u64 = if (wait_until_idle_ms_str) |s| parseIdleArg(s) catch {
            try common.printErr("invalid --wait-until-idle value");
            std.process.exit(common.ExitCode.generic);
            unreachable;
        } else 100;

        const duration_ms: u64 = if (wait_duration_str) |d| common.parseDurationMs(d) catch {
            try common.printErr("invalid --wait-duration value");
            std.process.exit(common.ExitCode.generic);
            unreachable;
        } else 0;

        const needle: ?[]const u8 = wait_until_text orelse wait_until_regex;

        try issueFusedWait(alloc, io, .{
            .session_ref = session_ref,
            .wait_kind = wait_kind,
            .needle = needle,
            .idle_ms = idle_ms,
            .duration_ms = duration_ms,
            .timeout_ms = timeout_ms,
            .snapshot = snapshot_flag,
            .diff = diff_flag,
            .json_output = json_output,
            .ansi_output = ansi_output,
            .lines = lines_range,
        });
    }
}

fn parseUInt(s: []const u8) !u32 {
    if (s.len == 0) return error.InvalidInt;
    const n = try std.fmt.parseInt(u32, s, 10);
    if (n == 0) return error.InvalidInt;
    return n;
}

const MouseModeParams = struct {
    click_row: ?u32,
    click_col: ?u32,
    scroll_dir: ?[]const u8,
    scroll_at_row: u32,
    scroll_at_col: u32,
    scroll_amount: u32,
    button: []const u8,
    delay_before_ms: u64,
    delay_after_ms: u64,
};

/// Execute the mouse-mode send. Issues one send_mouse RPC per underlying
/// event: --click = press + release; --scroll = N wheel presses. The
/// server picks the wire encoding based on the session's observed mouse
/// modes. The first RPC may fail with `MouseNotEnabled` — surface the
/// error identically to other send ops and exit with the generic error
/// code.
fn runMouseMode(alloc: Allocator, io: std.Io, session_ref: ?[]const u8, p: MouseModeParams) !void {
    if (p.delay_before_ms > 0) sys.sleep(p.delay_before_ms * std.time.ns_per_ms);

    if (p.click_row) |row| {
        const col = p.click_col.?;
        try sendMouseEvent(alloc, io, session_ref, "press", p.button, row, col);
        try sendMouseEvent(alloc, io, session_ref, "release", p.button, row, col);
    } else if (p.scroll_dir) |dir| {
        const wheel_btn: []const u8 = if (std.mem.eql(u8, dir, "up")) "wheel_up" else "wheel_down";
        var n: u32 = 0;
        while (n < p.scroll_amount) : (n += 1) {
            try sendMouseEvent(alloc, io, session_ref, "press", wheel_btn, p.scroll_at_row, p.scroll_at_col);
        }
    }

    if (p.delay_after_ms > 0) sys.sleep(p.delay_after_ms * std.time.ns_per_ms);
}

fn sendMouseEvent(
    alloc: Allocator,
    io: std.Io,
    session_ref: ?[]const u8,
    event: []const u8,
    button: []const u8,
    row: u32,
    col: u32,
) !void {
    var buf: std.Io.Writer.Allocating = .init(alloc);
    defer buf.deinit();
    const writer = &buf.writer;
    try writer.writeAll("{\"op\":\"send_mouse\",\"event\":");
    try common.writeJsonString(writer, event);
    try writer.writeAll(",\"button\":");
    try common.writeJsonString(writer, button);
    try writer.print(",\"row\":{d},\"col\":{d}", .{ row, col });
    if (session_ref) |s| {
        try writer.writeAll(",\"session\":");
        try common.writeJsonString(writer, s);
    }
    try writer.writeAll("}");

    const response_line = try common.sendRawRequest(alloc, io, buf.writer.buffered());
    defer alloc.free(response_line);

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, response_line, .{});
    defer parsed.deinit();
    _ = try common.expectOkOrExit(parsed);
}

/// `--wait-until-idle` takes an optional MS positional value. To decide
/// whether the next argv token belongs to the flag or to a different
/// position, peek at the first byte: durations always start with a digit.
/// (Session names are alphabetic in the natural usage `hty send NAME --...`.)
fn looksLikeDurationArg(arg: []const u8) bool {
    if (arg.len == 0) return false;
    return arg[0] >= '0' and arg[0] <= '9';
}

/// Parse the `--wait-until-idle` value. The flag is documented as taking
/// `MS`, matching `hty wait --idle MS` — so a bare integer means
/// milliseconds (not seconds, as `parseDurationMs` would have it). A
/// suffixed value (e.g. `200ms`, `1s`) falls through to `parseDurationMs`
/// for parity with `--timeout` / `--wait-duration`.
pub fn parseIdleArg(text: []const u8) !u64 {
    if (text.len == 0) return error.InvalidDuration;
    var i: usize = 0;
    while (i < text.len and text[i] >= '0' and text[i] <= '9') i += 1;
    if (i == 0) return error.InvalidDuration;
    if (i == text.len) return try std.fmt.parseInt(u64, text, 10);
    return try common.parseDurationMs(text);
}

/// Decide whether a fused `--snapshot` should get the implied idle settle
/// (issue #96): a snapshot with no explicit wait flag races the program's
/// redraw and can capture a stale frame, so unless the caller picked a wait
/// condition — or opted out with --no-wait — we default to
/// `--wait-until-idle` with the standard 100ms window.
pub fn shouldImplyIdleSettle(snapshot: bool, no_wait: bool, wait_kind_count: u8, has_wait_duration: bool) bool {
    return snapshot and !no_wait and wait_kind_count == 0 and !has_wait_duration;
}

pub const FusedRequest = struct {
    session_ref: ?[]const u8,
    wait_kind: []const u8,
    needle: ?[]const u8 = null,
    idle_ms: u64 = 100,
    duration_ms: u64 = 0,
    timeout_ms: u64 = 30_000,
    snapshot: bool = false,
    /// Ask the server for the row-diff payload instead of the full
    /// snapshot payload (same baseline as `hty snapshot --diff`).
    diff: bool = false,
};

/// Build and send the wait_and_snapshot RPC. Returns the parsed JSON
/// response; caller is responsible for `parsed.deinit()` and for inspecting
/// the response (success / timeout / error) and formatting the output.
pub fn sendFusedWait(alloc: Allocator, io: std.Io, req: FusedRequest) !std.json.Parsed(std.json.Value) {
    var payload_buf: std.Io.Writer.Allocating = .init(alloc);
    defer payload_buf.deinit();
    const writer = &payload_buf.writer;

    try writer.writeAll("{\"op\":\"wait_and_snapshot\",\"wait_kind\":");
    try common.writeJsonString(writer, req.wait_kind);
    try writer.print(",\"timeout_ms\":{d},\"snapshot\":{s}", .{
        req.timeout_ms,
        if (req.snapshot) "true" else "false",
    });
    if (req.diff) try writer.writeAll(",\"diff\":true");
    if (std.mem.eql(u8, req.wait_kind, "idle")) {
        try writer.print(",\"idle_ms\":{d}", .{req.idle_ms});
    } else if (std.mem.eql(u8, req.wait_kind, "duration")) {
        try writer.print(",\"duration_ms\":{d}", .{req.duration_ms});
    } else if (std.mem.eql(u8, req.wait_kind, "text") or std.mem.eql(u8, req.wait_kind, "regex")) {
        try writer.writeAll(",\"text\":");
        try common.writeJsonString(writer, req.needle.?);
    }
    if (req.session_ref) |s| {
        try writer.writeAll(",\"session\":");
        try common.writeJsonString(writer, s);
    }
    try writer.writeAll("}");

    const response_line = try common.sendRawRequest(alloc, io, payload_buf.writer.buffered());
    defer alloc.free(response_line);

    return std.json.parseFromSlice(std.json.Value, alloc, response_line, .{});
}

const FusedWaitParams = struct {
    session_ref: ?[]const u8,
    wait_kind: []const u8,
    needle: ?[]const u8,
    idle_ms: u64,
    duration_ms: u64,
    timeout_ms: u64,
    snapshot: bool,
    diff: bool = false,
    json_output: bool,
    ansi_output: bool,
    lines: ?common.LineRange = null,
};

/// Build and issue the wait_and_snapshot RPC, then format the response
/// according to --json / --ansi / default flags. Exits the process on
/// timeout (code 3) or server-reported error.
pub fn issueFusedWait(alloc: Allocator, io: std.Io, params: FusedWaitParams) !void {
    var parsed = try sendFusedWait(alloc, io, .{
        .session_ref = params.session_ref,
        .wait_kind = params.wait_kind,
        .needle = params.needle,
        .idle_ms = params.idle_ms,
        .duration_ms = params.duration_ms,
        .timeout_ms = params.timeout_ms,
        .snapshot = params.snapshot,
        .diff = params.diff,
    });
    defer parsed.deinit();
    const object = try common.expectOkOrExit(parsed);

    const timed_out = readTimedOut(object);

    if (params.json_output) {
        try emitFusedJson(alloc, object, params.snapshot, null);
        if (timed_out) std.process.exit(common.ExitCode.wait_timeout);
        return;
    }

    if (params.snapshot) {
        if (params.diff)
            try common.printDiffBody(alloc, object)
        else
            try printSnapshotBody(object, params.ansi_output, params.lines);
    }

    if (timed_out) {
        try common.printErr("timed out");
        std.process.exit(common.ExitCode.wait_timeout);
    }
}

/// Read `timed_out` from the top-level response (server sets it on the
/// envelope alongside the `wait` payload).
pub fn readTimedOut(object: std.json.ObjectMap) bool {
    if (object.get("timed_out")) |to_val| {
        if (to_val == .bool and to_val.bool) return true;
    }
    return false;
}

/// Print either the plain `buffer` field or the styled `screen_ansi` field
/// from the response's `snapshot` sub-object, with a trailing newline.
/// Plain output strips per-line trailing padding (LatentEvals/hty#97).
/// `lines` (from `--lines N:M`) restricts the output to that row range,
/// applied before the strip.
pub fn printSnapshotBody(object: std.json.ObjectMap, ansi_output: bool, lines: ?common.LineRange) !void {
    const snap_val = object.get("snapshot") orelse return;
    if (snap_val != .object) return;
    const field = if (ansi_output) "screen_ansi" else "buffer";
    const body = snap_val.object.get(field) orelse return;
    if (body != .string) return;
    const text = if (lines) |r| common.sliceLines(body.string, r) else body.string;
    if (ansi_output) {
        try common.printRaw(text);
        try common.printRaw("\n");
    } else {
        try common.printPlainSnapshot(text);
    }
}

/// Reshape the server response into the issue's documented `--json` shape:
/// `{ok, matched, elapsed_ms, snapshot?, timeout?}`. The server returns
/// matched/elapsed_ms inside a `wait` sub-object alongside the snapshot,
/// matching the existing `hty wait --json` contract; this function pulls
/// them up to the top level so the fused commands have a flat envelope.
/// `extra_session_field` (used by `hty run`) prepends a `session: {...}`
/// entry so the freshly-spawned session id is part of the JSON response.
pub fn emitFusedJson(
    alloc: Allocator,
    object: std.json.ObjectMap,
    include_snapshot: bool,
    extra_session_field: ?[]const u8,
) !void {
    var buf: std.Io.Writer.Allocating = .init(alloc);
    defer buf.deinit();
    const writer = &buf.writer;

    try writer.writeAll("{\"ok\":true");

    if (extra_session_field) |sess_json| {
        try writer.writeAll(",\"session\":");
        try writer.writeAll(sess_json);
    }

    var matched_val: ?std.json.Value = null;
    var elapsed_ms: i64 = 0;
    var timeout: bool = false;
    if (object.get("wait")) |wait_val| {
        if (wait_val == .object) {
            const w = wait_val.object;
            if (w.get("matched")) |m| matched_val = m;
            if (w.get("elapsed_ms")) |e| {
                if (e == .integer) elapsed_ms = e.integer;
            }
            if (w.get("timeout")) |t| {
                if (t == .bool) timeout = t.bool;
            }
        }
    }

    try writer.writeAll(",\"matched\":");
    if (matched_val) |m| {
        switch (m) {
            .string => |s| try common.writeJsonString(writer, s),
            else => try writer.writeAll("null"),
        }
    } else {
        try writer.writeAll("null");
    }
    try writer.print(",\"elapsed_ms\":{d}", .{elapsed_ms});
    if (timeout) try writer.writeAll(",\"timeout\":true");

    if (include_snapshot) {
        if (object.get("snapshot")) |snap_val| {
            const snap_json = try std.json.Stringify.valueAlloc(alloc, snap_val, .{});
            defer alloc.free(snap_json);
            try writer.writeAll(",\"snapshot\":");
            try writer.writeAll(snap_json);
        }
    }

    try writer.writeAll("}");
    try common.printLine(buf.writer.buffered());
}

const SeqToken = struct {
    kind: enum { text, key, bytes_hex, delay },
    value: []const u8,
    delay_ms: u64 = 0, // only meaningful when kind == .delay
};

const SeqTokenList = struct {
    tokens: [256]SeqToken = undefined,
    len: usize = 0,

    fn slice(self: *const SeqTokenList) []const SeqToken {
        return self.tokens[0..self.len];
    }
};

/// Parse a --seq string into tokens.
/// Quoted strings ("..." or '...') become text tokens.
/// Bare words that look like durations (e.g. 200ms, 1s) become delay tokens.
/// All other bare words become key tokens; `bareWordsToText` then
/// reclassifies the ones that are not recognized key names as text.
/// Token values are slices into the input string (no allocation needed for values).
fn parseSeqTokens(input: []const u8) error{InvalidSeq}!SeqTokenList {
    var result: SeqTokenList = .{};
    var pos: usize = 0;

    while (pos < input.len) {
        // Skip whitespace
        while (pos < input.len and (input[pos] == ' ' or input[pos] == '\t')) : (pos += 1) {}
        if (pos >= input.len) break;

        if (result.len >= result.tokens.len) return error.InvalidSeq;

        if (input[pos] == '"' or input[pos] == '\'') {
            // Quoted text token
            const quote = input[pos];
            pos += 1;
            const start = pos;
            while (pos < input.len and input[pos] != quote) : (pos += 1) {}
            if (pos >= input.len) return error.InvalidSeq; // unmatched quote
            result.tokens[result.len] = .{ .kind = .text, .value = input[start..pos] };
            result.len += 1;
            pos += 1; // skip closing quote
        } else {
            // Bare word — could be a key name or a delay
            const start = pos;
            while (pos < input.len and input[pos] != ' ' and input[pos] != '\t') : (pos += 1) {}
            const word = input[start..pos];
            if (looksLikeDuration(word)) {
                if (common.parseDurationMs(word)) |ms| {
                    result.tokens[result.len] = .{ .kind = .delay, .value = word, .delay_ms = ms };
                    result.len += 1;
                } else |_| {
                    // Looked like a duration but failed to parse — treat as key
                    result.tokens[result.len] = .{ .kind = .key, .value = word };
                    result.len += 1;
                }
            } else {
                result.tokens[result.len] = .{ .kind = .key, .value = word };
                result.len += 1;
            }
        }
    }

    return result;
}

/// Returns true if any quoted text token contains a backslash escape
/// (`\n`, `\t`, `\e`) that `--text` would decode but `--seq` sends
/// literally (issue #102). Such sequences are rejected before anything is
/// sent. Keys and delay tokens never trigger this.
fn seqTextLooksEscaped(list: SeqTokenList) bool {
    for (list.slice()) |token| {
        if (token.kind != .text) continue;
        if (std.mem.indexOf(u8, token.value, "\\n") != null) return true;
        if (std.mem.indexOf(u8, token.value, "\\t") != null) return true;
        if (std.mem.indexOf(u8, token.value, "\\e") != null) return true;
    }
    return false;
}

/// Returns the first `.key` token whose name `keyToBytes` rejects, or null
/// when every key token is valid. Covers both `--seq` bare words and the
/// single `--key` token. Runs before anything is sent so an invalid key
/// aborts the whole command instead of failing mid-send with earlier
/// tokens already delivered.
fn findInvalidKeyToken(alloc: Allocator, list: SeqTokenList) error{OutOfMemory}!?[]const u8 {
    for (list.slice()) |token| {
        if (token.kind != .key) continue;
        _ = keyToBytes(alloc, token.value) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return token.value,
        };
    }
    return null;
}

/// Build the invalid-key error for `token` (from `flag`, "--seq" or
/// "--key"). Names the offending token (truncated past 40 bytes). --seq
/// adds a bare-words-vs-quoted hint; a token containing a space adds a
/// tail pointing --key users at --seq. Caller frees.
fn invalidKeyMessage(alloc: Allocator, flag: []const u8, token: []const u8) ![]const u8 {
    const max_shown = 40;
    const shown = if (token.len > max_shown) token[0..max_shown] else token;
    const ellipsis: []const u8 = if (token.len > max_shown) "..." else "";
    const seq_hint: []const u8 = if (std.mem.eql(u8, flag, "--seq"))
        "; bare words are key names — quote free text (\"like this\")"
    else
        "";
    const space_hint: []const u8 = if (std.mem.indexOfScalar(u8, token, ' ') != null)
        ". --key sends a single key; use --seq for a sequence (e.g. --seq 'ctrl-x \"u\"')"
    else
        "";
    return std.fmt.allocPrint(alloc, "invalid key name \"{s}{s}\" in {s}{s}; run `hty keys` for the list{s}", .{ shown, ellipsis, flag, seq_hint, space_hint });
}

/// tmux send-keys parity: reclassify any bare `--seq` word that is not a
/// recognized key name as literal text instead of letting it fail as a
/// key. Key names win over text — bare "enter" is the key; quote it to
/// type the word. Runs on the parsed token list before anything is sent;
/// after this pass every `--seq` key token is valid, so
/// `findInvalidKeyToken` only fires for the `--key` path.
fn bareWordsToText(alloc: Allocator, list: *SeqTokenList) error{OutOfMemory}!void {
    for (list.tokens[0..list.len]) |*token| {
        if (token.kind != .key) continue;
        if (keyToBytes(alloc, token.value)) |_| {
            // Recognized key name — keep it a key token.
        } else |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                token.kind = .text;
            },
        }
    }
}

/// Returns true if the word starts with a digit and ends with a duration
/// suffix (ms, s, m, h). This avoids misinterpreting key names like "f1"
/// as durations.
fn looksLikeDuration(word: []const u8) bool {
    if (word.len < 2) return false;
    if (word[0] < '0' or word[0] > '9') return false;
    if (std.mem.endsWith(u8, word, "ms")) return true;
    if (std.mem.endsWith(u8, word, "s")) return true;
    if (std.mem.endsWith(u8, word, "m")) return true;
    if (std.mem.endsWith(u8, word, "h")) return true;
    return false;
}

/// Process C-style escape sequences in --text values.
/// Supports: \n \t \r \\ \e (ESC). An unrecognised escape like \< passes
/// through verbatim (backslash + char, issue #102); a trailing backslash
/// is an error.
/// If the input contains no backslashes the original slice is returned
/// (no allocation).
fn unescapeText(alloc: Allocator, input: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, input, '\\') == null) return input;

    var buf = std.array_list.Managed(u8).init(alloc);
    errdefer buf.deinit();

    var i: usize = 0;
    while (i < input.len) {
        if (input[i] == '\\') {
            i += 1;
            if (i >= input.len) return error.InvalidEscape;
            switch (input[i]) {
                'n' => try buf.append('\n'),
                't' => try buf.append('\t'),
                'r' => try buf.append('\r'),
                'e' => try buf.append(0x1B),
                '\\' => try buf.append('\\'),
                else => {
                    try buf.append('\\');
                    try buf.append(input[i]);
                },
            }
        } else {
            try buf.append(input[i]);
        }
        i += 1;
    }
    return buf.toOwnedSlice();
}

/// Split every `.text` token in `input` into one text token per UTF-8
/// codepoint, interleaving `.delay` tokens of `char_ms` between adjacent
/// characters. Non-text tokens (keys, hex-bytes, existing delays) pass
/// through unchanged. Shared between `--text`, `--raw-text`, and `--seq`
/// text tokens — `--raw-text` reaches this path the same way `--text`
/// does, so `--delay-char` composes identically for both.
fn expandDelayChar(input: SeqTokenList, char_ms: u64) SeqTokenList {
    var expanded: SeqTokenList = .{};
    for (input.slice()) |token| {
        if (token.kind == .text and token.value.len > 1) {
            var offset: usize = 0;
            while (offset < token.value.len) {
                if (expanded.len >= expanded.tokens.len) break;
                // Handle multi-byte UTF-8: find the end of this codepoint.
                const byte = token.value[offset];
                const cp_len: usize = if (byte < 0x80) 1 else if (byte < 0xE0) 2 else if (byte < 0xF0) 3 else 4;
                const end = @min(offset + cp_len, token.value.len);
                expanded.tokens[expanded.len] = .{ .kind = .text, .value = token.value[offset..end] };
                expanded.len += 1;
                offset = end;
                if (offset < token.value.len and expanded.len < expanded.tokens.len) {
                    expanded.tokens[expanded.len] = .{ .kind = .delay, .value = "", .delay_ms = char_ms };
                    expanded.len += 1;
                }
            }
        } else {
            if (expanded.len >= expanded.tokens.len) break;
            expanded.tokens[expanded.len] = token;
            expanded.len += 1;
        }
    }
    return expanded;
}

/// The five keyboard input flags accepted by `hty send`. They may be
/// repeated and combined; each occurrence appends to one input sequence
/// executed in argv order.
const InputKind = enum { text, raw_text, key, bytes_hex, seq };

const InputSpec = struct {
    kind: InputKind,
    value: []const u8,
};

/// Expand the parsed input flags, in argv order, into one flat token list.
/// Per-flag semantics are unchanged: --text processes C-style escapes,
/// --raw-text is verbatim, --seq tokenizes, --key and --bytes-hex map to
/// single tokens.
fn buildInputTokens(
    alloc: Allocator,
    inputs: []const InputSpec,
) error{ InvalidSeq, EmptySeq, SeqEscaped, TooManyTokens, InvalidEscape, OutOfMemory }!SeqTokenList {
    var result: SeqTokenList = .{};
    for (inputs) |spec| {
        switch (spec.kind) {
            .seq => {
                var sub = try parseSeqTokens(spec.value);
                if (sub.len == 0) return error.EmptySeq;
                // Quoted-string escape reject (issue #102) runs before the
                // bare-word fallback so it only sees quoted text tokens.
                if (seqTextLooksEscaped(sub)) return error.SeqEscaped;
                try bareWordsToText(alloc, &sub);
                for (sub.slice()) |token| {
                    if (result.len >= result.tokens.len) return error.TooManyTokens;
                    result.tokens[result.len] = token;
                    result.len += 1;
                }
            },
            .text => {
                const unescaped = unescapeText(alloc, spec.value) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => return error.InvalidEscape,
                };
                if (result.len >= result.tokens.len) return error.TooManyTokens;
                result.tokens[result.len] = .{ .kind = .text, .value = unescaped };
                result.len += 1;
            },
            .raw_text => {
                if (result.len >= result.tokens.len) return error.TooManyTokens;
                result.tokens[result.len] = .{ .kind = .text, .value = spec.value };
                result.len += 1;
            },
            .key => {
                if (result.len >= result.tokens.len) return error.TooManyTokens;
                result.tokens[result.len] = .{ .kind = .key, .value = spec.value };
                result.len += 1;
            },
            .bytes_hex => {
                if (result.len >= result.tokens.len) return error.TooManyTokens;
                result.tokens[result.len] = .{ .kind = .bytes_hex, .value = spec.value };
                result.len += 1;
            },
        }
    }
    return result;
}

// ============================================================================
// Tests
// ============================================================================

test "parseSeqTokens: keys only" {
    const result = try parseSeqTokens("ctrl-c ctrl-t");
    const tokens = result.slice();
    try std.testing.expectEqual(@as(usize, 2), tokens.len);
    try std.testing.expectEqual(.key, tokens[0].kind);
    try std.testing.expectEqualStrings("ctrl-c", tokens[0].value);
    try std.testing.expectEqual(.key, tokens[1].kind);
    try std.testing.expectEqualStrings("ctrl-t", tokens[1].value);
}

test "parseSeqTokens: mixed text and keys" {
    const result = try parseSeqTokens("ctrl-s \"TODO Learn\" enter");
    const tokens = result.slice();
    try std.testing.expectEqual(@as(usize, 3), tokens.len);
    try std.testing.expectEqual(.key, tokens[0].kind);
    try std.testing.expectEqualStrings("ctrl-s", tokens[0].value);
    try std.testing.expectEqual(.text, tokens[1].kind);
    try std.testing.expectEqualStrings("TODO Learn", tokens[1].value);
    try std.testing.expectEqual(.key, tokens[2].kind);
    try std.testing.expectEqualStrings("enter", tokens[2].value);
}

test "parseSeqTokens: single-quoted text" {
    const result = try parseSeqTokens("'hello world' enter");
    const tokens = result.slice();
    try std.testing.expectEqual(@as(usize, 2), tokens.len);
    try std.testing.expectEqual(.text, tokens[0].kind);
    try std.testing.expectEqualStrings("hello world", tokens[0].value);
    try std.testing.expectEqual(.key, tokens[1].kind);
}

test "parseSeqTokens: text-only sequence" {
    const result = try parseSeqTokens("\"yes\"");
    const tokens = result.slice();
    try std.testing.expectEqual(@as(usize, 1), tokens.len);
    try std.testing.expectEqual(.text, tokens[0].kind);
    try std.testing.expectEqualStrings("yes", tokens[0].value);
}

test "parseSeqTokens: empty input" {
    const result = try parseSeqTokens("");
    try std.testing.expectEqual(@as(usize, 0), result.len);
}

test "parseSeqTokens: whitespace only" {
    const result = try parseSeqTokens("   ");
    try std.testing.expectEqual(@as(usize, 0), result.len);
}

test "parseSeqTokens: delay tokens" {
    const result = try parseSeqTokens("\"hello\" 200ms enter 1s \"world\"");
    const tokens = result.slice();
    try std.testing.expectEqual(@as(usize, 5), tokens.len);
    try std.testing.expectEqual(.text, tokens[0].kind);
    try std.testing.expectEqualStrings("hello", tokens[0].value);
    try std.testing.expectEqual(.delay, tokens[1].kind);
    try std.testing.expectEqual(@as(u64, 200), tokens[1].delay_ms);
    try std.testing.expectEqual(.key, tokens[2].kind);
    try std.testing.expectEqualStrings("enter", tokens[2].value);
    try std.testing.expectEqual(.delay, tokens[3].kind);
    try std.testing.expectEqual(@as(u64, 1000), tokens[3].delay_ms);
    try std.testing.expectEqual(.text, tokens[4].kind);
}

test "parseSeqTokens: f-keys are not durations" {
    const result = try parseSeqTokens("f1 f12");
    const tokens = result.slice();
    try std.testing.expectEqual(@as(usize, 2), tokens.len);
    try std.testing.expectEqual(.key, tokens[0].kind);
    try std.testing.expectEqualStrings("f1", tokens[0].value);
    try std.testing.expectEqual(.key, tokens[1].kind);
    try std.testing.expectEqualStrings("f12", tokens[1].value);
}

test "parseSeqTokens: unmatched quote is an error" {
    try std.testing.expectError(error.InvalidSeq, parseSeqTokens("\"hello"));
    try std.testing.expectError(error.InvalidSeq, parseSeqTokens("'hello"));
}

test "unescapeText: no escapes returns original slice" {
    const input = "hello";
    const result = try unescapeText(std.testing.allocator, input);
    try std.testing.expectEqualStrings("hello", result);
    try std.testing.expect(result.ptr == input.ptr); // no allocation
}

test "unescapeText: newline, tab, carriage return" {
    const result = try unescapeText(std.testing.allocator, "y\\n");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("y\n", result);

    const result2 = try unescapeText(std.testing.allocator, "a\\tb\\rc");
    defer std.testing.allocator.free(result2);
    try std.testing.expectEqualStrings("a\tb\rc", result2);
}

test "unescapeText: escaped backslash" {
    const result = try unescapeText(std.testing.allocator, "a\\\\b");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("a\\b", result);
}

test "unescapeText: escape for ESC (0x1B)" {
    const result = try unescapeText(std.testing.allocator, "\\e[31m");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqual(@as(u8, 0x1B), result[0]);
    try std.testing.expectEqualStrings("[31m", result[1..]);
}

test "unescapeText: trailing backslash is an error" {
    try std.testing.expectError(error.InvalidEscape, unescapeText(std.testing.allocator, "hello\\"));
}

test "unescapeText: unknown escape passes through verbatim" {
    const result = try unescapeText(std.testing.allocator, "hello\\z");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("hello\\z", result);
}

test "unescapeText: vim-style escapes pass through verbatim" {
    // issue #102: `--text '/\<word\>'` used to fail with "invalid escape
    // sequence"; vim regex atoms must survive untouched.
    const result = try unescapeText(std.testing.allocator, "/\\<word\\>");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("/\\<word\\>", result);
}

test "unescapeText: known and unknown escapes mixed" {
    const result = try unescapeText(std.testing.allocator, "a\\n\\<b");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("a\n\\<b", result);
}

test "seqTextLooksEscaped: quoted backslash-n is rejected" {
    const tokens = try parseSeqTokens("ctrl-x \"line1\\nline2\" enter");
    try std.testing.expect(seqTextLooksEscaped(tokens));
}

test "seqTextLooksEscaped: backslash-t and backslash-e are rejected" {
    try std.testing.expect(seqTextLooksEscaped(try parseSeqTokens("\"a\\tb\"")));
    try std.testing.expect(seqTextLooksEscaped(try parseSeqTokens("\"\\e[31m\"")));
}

test "seqTextLooksEscaped: plain tokens pass" {
    const tokens = try parseSeqTokens("\"hello\" 200ms enter \"world\"");
    try std.testing.expect(!seqTextLooksEscaped(tokens));
}

test "seqTextLooksEscaped: bare key words never trigger the check" {
    // Only quoted text tokens are checked; key tokens are exempt.
    const tokens = try parseSeqTokens("enter tab escape");
    try std.testing.expect(!seqTextLooksEscaped(tokens));
}

test "findInvalidKeyToken: names the offending token" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const tokens = try parseSeqTokens("ctrl-x notakey enter");
    const bad = try findInvalidKeyToken(arena.allocator(), tokens);
    try std.testing.expectEqualStrings("notakey", bad.?);
}

test "findInvalidKeyToken: all-valid sequence returns null" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const tokens = try parseSeqTokens("\"hello\" 200ms ctrl-alt-f shift-up f12 enter");
    try std.testing.expectEqual(@as(?[]const u8, null), try findInvalidKeyToken(arena.allocator(), tokens));
}

test "findInvalidKeyToken: quoted text is never treated as a key" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // "notakey" would be invalid as a bare word, but quoted it is text.
    const tokens = try parseSeqTokens("\"notakey definitely not a key\" enter");
    try std.testing.expectEqual(@as(?[]const u8, null), try findInvalidKeyToken(arena.allocator(), tokens));
}

test "findInvalidKeyToken: single --key-shaped token" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // What run() builds for `--key "ctrl-x u"` — one key token.
    var list: SeqTokenList = .{};
    list.tokens[0] = .{ .kind = .key, .value = "ctrl-x u" };
    list.len = 1;
    const bad = try findInvalidKeyToken(arena.allocator(), list);
    try std.testing.expectEqualStrings("ctrl-x u", bad.?);
}

test "invalidKeyMessage: --seq names token and adds quoting hint" {
    const msg = try invalidKeyMessage(std.testing.allocator, "--seq", "notakey");
    defer std.testing.allocator.free(msg);
    try std.testing.expectEqualStrings("invalid key name \"notakey\" in --seq; bare words are key names — quote free text (\"like this\"); run `hty keys` for the list", msg);
}

test "invalidKeyMessage: --key names token, no seq hint, no space tail" {
    const msg = try invalidKeyMessage(std.testing.allocator, "--key", "notakey");
    defer std.testing.allocator.free(msg);
    try std.testing.expectEqualStrings("invalid key name \"notakey\" in --key; run `hty keys` for the list", msg);
}

test "invalidKeyMessage: --key token with space adds --seq suggestion tail" {
    const msg = try invalidKeyMessage(std.testing.allocator, "--key", "ctrl-x u");
    defer std.testing.allocator.free(msg);
    try std.testing.expectEqualStrings("invalid key name \"ctrl-x u\" in --key; run `hty keys` for the list. --key sends a single key; use --seq for a sequence (e.g. --seq 'ctrl-x \"u\"')", msg);
}

test "invalidKeyMessage: huge token is truncated" {
    const long = "x" ** 60;
    const msg = try invalidKeyMessage(std.testing.allocator, "--seq", long);
    defer std.testing.allocator.free(msg);
    try std.testing.expect(std.mem.indexOf(u8, msg, "\"" ++ ("x" ** 40) ++ "...\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "x" ** 41) == null);
}

test "unescapeText: multiple escapes in one string" {
    const result = try unescapeText(std.testing.allocator, "line1\\nline2\\ttab\\\\backslash");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("line1\nline2\ttab\\backslash", result);
}

// --raw-text semantics: --raw-text passes bytes verbatim to the `.text`
// token without running unescapeText. The tests below pin down the byte
// equality between what the shell hands us and what goes on the wire.
// This is what distinguishes --raw-text from --text: --text would decode
// `\n` into a real LF (0x0A); --raw-text keeps those as two separate
// bytes (0x5C, 0x6E).

test "raw-text: literal backslash-n stays two bytes" {
    // What the shell passes when the user types `--raw-text 'hello\n'`.
    const raw: []const u8 = "hello\\n";
    // --raw-text skips unescapeText entirely: the value IS the byte slice.
    try std.testing.expectEqual(@as(usize, 7), raw.len);
    try std.testing.expectEqual(@as(u8, 'o'), raw[4]);
    try std.testing.expectEqual(@as(u8, '\\'), raw[5]);
    try std.testing.expectEqual(@as(u8, 'n'), raw[6]);
    // Sanity check: --text would have collapsed the last two bytes into one.
    const unescaped = try unescapeText(std.testing.allocator, raw);
    defer std.testing.allocator.free(unescaped);
    try std.testing.expectEqual(@as(usize, 6), unescaped.len);
    try std.testing.expectEqual(@as(u8, '\n'), unescaped[5]);
}

test "raw-text: common C-style escape-looking sequences stay literal" {
    // User intent: send the 8 bytes `\t\n\\\e` verbatim. --raw-text does
    // zero translation; each of those backslashes/letters is its own byte.
    const raw: []const u8 = "\\t\\n\\\\\\e";
    try std.testing.expectEqual(@as(usize, 8), raw.len);
    try std.testing.expectEqualStrings("\\t\\n\\\\\\e", raw);
    // No LF, no TAB, no ESC — every byte is either '\\' or an ASCII letter.
    for (raw) |b| try std.testing.expect(b == '\\' or (b >= 'a' and b <= 'z'));
}

test "bareWordsToText: bare non-key word becomes text" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tokens = try parseSeqTokens("alt-x replace-string enter");
    try bareWordsToText(arena.allocator(), &tokens);
    const list = tokens.slice();
    try std.testing.expectEqual(@as(usize, 3), list.len);
    try std.testing.expectEqual(.key, list[0].kind);
    try std.testing.expectEqualStrings("alt-x", list[0].value);
    try std.testing.expectEqual(.text, list[1].kind);
    try std.testing.expectEqualStrings("replace-string", list[1].value);
    try std.testing.expectEqual(.key, list[2].kind);
    try std.testing.expectEqualStrings("enter", list[2].value);
}

test "bareWordsToText: key names still win over text" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tokens = try parseSeqTokens("ctrl-c enter f1 up space ctrl-alt-f");
    try bareWordsToText(arena.allocator(), &tokens);
    for (tokens.slice()) |token| {
        try std.testing.expectEqual(.key, token.kind);
    }
}

test "bareWordsToText: mixed sequence produces expected op kinds" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tokens = try parseSeqTokens("alt-x replace-string enter \"with space\" 300ms ctrl-s");
    try bareWordsToText(arena.allocator(), &tokens);
    const list = tokens.slice();
    try std.testing.expectEqual(@as(usize, 6), list.len);
    try std.testing.expectEqual(.key, list[0].kind); // alt-x
    try std.testing.expectEqual(.text, list[1].kind); // replace-string
    try std.testing.expectEqual(.key, list[2].kind); // enter
    try std.testing.expectEqual(.text, list[3].kind); // "with space" (quoted)
    try std.testing.expectEqual(.delay, list[4].kind); // 300ms
    try std.testing.expectEqual(@as(u64, 300), list[4].delay_ms);
    try std.testing.expectEqual(.key, list[5].kind); // ctrl-s
}

test "bareWordsToText: vim ex command tokens" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // ":e" is no key name -> text; "." is a single printable -> stays a
    // key that types "." — same bytes on the wire either way.
    var tokens = try parseSeqTokens(":e . enter");
    try bareWordsToText(arena.allocator(), &tokens);
    const list = tokens.slice();
    try std.testing.expectEqual(.text, list[0].kind);
    try std.testing.expectEqualStrings(":e", list[0].value);
    try std.testing.expectEqual(.key, list[1].kind);
    try std.testing.expectEqual(.key, list[2].kind);
}

test "bareWordsToText: quoted tokens are untouched" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // A quoted "enter" is text before and after the pass.
    var tokens = try parseSeqTokens("\"enter\" enter");
    try bareWordsToText(arena.allocator(), &tokens);
    const list = tokens.slice();
    try std.testing.expectEqual(.text, list[0].kind);
    try std.testing.expectEqual(.key, list[1].kind);
}

test "helpText documents --seq bare-word text fallback" {
    const text = helpText();
    try std.testing.expect(std.mem.indexOf(u8, text, "typed literally") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "tmux send-keys convention") != null);
}

test "helpText documents --raw-text" {
    const text = helpText();
    try std.testing.expect(std.mem.indexOf(u8, text, "--raw-text") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "verbatim") != null);
}

test "buildInputTokens: flags compose in argv order" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // --key ctrl-x --text hello --key enter
    const inputs = [_]InputSpec{
        .{ .kind = .key, .value = "ctrl-x" },
        .{ .kind = .text, .value = "hello" },
        .{ .kind = .key, .value = "enter" },
    };
    const result = try buildInputTokens(arena, &inputs);
    const tokens = result.slice();
    try std.testing.expectEqual(@as(usize, 3), tokens.len);
    try std.testing.expectEqual(.key, tokens[0].kind);
    try std.testing.expectEqualStrings("ctrl-x", tokens[0].value);
    try std.testing.expectEqual(.text, tokens[1].kind);
    try std.testing.expectEqualStrings("hello", tokens[1].value);
    try std.testing.expectEqual(.key, tokens[2].kind);
    try std.testing.expectEqualStrings("enter", tokens[2].value);
}

test "buildInputTokens: single flags behave as before" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // --text still processes C-style escapes.
    const text_result = try buildInputTokens(arena, &.{.{ .kind = .text, .value = "a\\nb" }});
    try std.testing.expectEqual(@as(usize, 1), text_result.slice().len);
    try std.testing.expectEqualStrings("a\nb", text_result.slice()[0].value);

    // --raw-text stays verbatim.
    const raw_result = try buildInputTokens(arena, &.{.{ .kind = .raw_text, .value = "a\\nb" }});
    try std.testing.expectEqualStrings("a\\nb", raw_result.slice()[0].value);

    // --key and --bytes-hex map to single tokens.
    const key_result = try buildInputTokens(arena, &.{.{ .kind = .key, .value = "enter" }});
    try std.testing.expectEqual(.key, key_result.slice()[0].kind);
    const hex_result = try buildInputTokens(arena, &.{.{ .kind = .bytes_hex, .value = "2020" }});
    try std.testing.expectEqual(.bytes_hex, hex_result.slice()[0].kind);
}

test "buildInputTokens: --seq expands inline between other flags" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // --key esc --seq '"hi" enter' --text bye
    const inputs = [_]InputSpec{
        .{ .kind = .key, .value = "esc" },
        .{ .kind = .seq, .value = "\"hi\" enter" },
        .{ .kind = .text, .value = "bye" },
    };
    const result = try buildInputTokens(arena, &inputs);
    const tokens = result.slice();
    try std.testing.expectEqual(@as(usize, 4), tokens.len);
    try std.testing.expectEqual(.key, tokens[0].kind);
    try std.testing.expectEqualStrings("esc", tokens[0].value);
    try std.testing.expectEqual(.text, tokens[1].kind);
    try std.testing.expectEqualStrings("hi", tokens[1].value);
    try std.testing.expectEqual(.key, tokens[2].kind);
    try std.testing.expectEqualStrings("enter", tokens[2].value);
    try std.testing.expectEqual(.text, tokens[3].kind);
    try std.testing.expectEqualStrings("bye", tokens[3].value);
}

test "buildInputTokens: seq errors surface" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expectError(error.InvalidSeq, buildInputTokens(arena, &.{.{ .kind = .seq, .value = "\"unclosed" }}));
    try std.testing.expectError(error.EmptySeq, buildInputTokens(arena, &.{.{ .kind = .seq, .value = "  " }}));
    try std.testing.expectError(error.InvalidEscape, buildInputTokens(arena, &.{.{ .kind = .text, .value = "bad\\" }}));
    try std.testing.expectError(error.SeqEscaped, buildInputTokens(arena, &.{.{ .kind = .seq, .value = "\"a\\nb\"" }}));
}

test "expandDelayChar: raw-text composes with --delay-char" {
    // Simulate the token list --raw-text "ab" builds: one .text token with
    // the two raw bytes. expandDelayChar should turn that into
    // [text "a", delay 50, text "b"] — same as --text would.
    var input: SeqTokenList = .{};
    input.tokens[0] = .{ .kind = .text, .value = "ab" };
    input.len = 1;

    const out = expandDelayChar(input, 50);
    const tokens = out.slice();
    try std.testing.expectEqual(@as(usize, 3), tokens.len);
    try std.testing.expectEqual(.text, tokens[0].kind);
    try std.testing.expectEqualStrings("a", tokens[0].value);
    try std.testing.expectEqual(.delay, tokens[1].kind);
    try std.testing.expectEqual(@as(u64, 50), tokens[1].delay_ms);
    try std.testing.expectEqual(.text, tokens[2].kind);
    try std.testing.expectEqualStrings("b", tokens[2].value);
}

test "expandDelayChar: raw-text keeps literal backslash-n as two separate steps" {
    // --raw-text 'a\n' --delay-char 50ms should split into [a] delay [\] delay [n].
    var input: SeqTokenList = .{};
    input.tokens[0] = .{ .kind = .text, .value = "a\\n" };
    input.len = 1;

    const out = expandDelayChar(input, 50);
    const tokens = out.slice();
    try std.testing.expectEqual(@as(usize, 5), tokens.len);
    try std.testing.expectEqualStrings("a", tokens[0].value);
    try std.testing.expectEqual(.delay, tokens[1].kind);
    try std.testing.expectEqualStrings("\\", tokens[2].value);
    try std.testing.expectEqual(.delay, tokens[3].kind);
    try std.testing.expectEqualStrings("n", tokens[4].value);
}

test "buildInputTokens: --raw-text composes with other input flags" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const inputs = [_]InputSpec{
        .{ .kind = .raw_text, .value = "x" },
        .{ .kind = .key, .value = "enter" },
        .{ .kind = .bytes_hex, .value = "2020" },
    };
    const result = try buildInputTokens(arena, &inputs);
    const tokens = result.slice();
    try std.testing.expectEqual(@as(usize, 3), tokens.len);
    try std.testing.expectEqual(.text, tokens[0].kind);
    try std.testing.expectEqual(.key, tokens[1].kind);
    try std.testing.expectEqual(.bytes_hex, tokens[2].kind);
}
test "shouldImplyIdleSettle: bare --snapshot gets the settle" {
    try std.testing.expect(shouldImplyIdleSettle(true, false, 0, false));
}

test "shouldImplyIdleSettle: --no-wait opts out" {
    try std.testing.expect(!shouldImplyIdleSettle(true, true, 0, false));
}

test "shouldImplyIdleSettle: explicit wait flags are left alone" {
    // Any --wait-until-* (wait_kind_count > 0) or --wait-duration suppresses
    // the implied settle; without --snapshot there is nothing to settle.
    try std.testing.expect(!shouldImplyIdleSettle(true, false, 1, false));
    try std.testing.expect(!shouldImplyIdleSettle(true, false, 0, true));
    try std.testing.expect(!shouldImplyIdleSettle(false, false, 0, false));
}
