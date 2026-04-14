//! `hty send` — send text, a key, hex bytes, or a mixed `--seq` sequence
//! to a session.

const std = @import("std");
const Allocator = std.mem.Allocator;

const common = @import("common.zig");

pub fn helpText() []const u8 {
    return
    \\hty send [SESSION] --text "..." | --key NAME | --seq "..." | --bytes-hex HEX
    \\
    \\Send input to a session. Exactly one of --text, --key, --seq,
    \\--bytes-hex is required.
    \\
    \\Flags:
    \\  --text STRING        UTF-8 text with C-style escapes (\n \t \r \\ \e).
    \\  --key NAME           Named key with optional modifiers.
    \\                       Supports ctrl-, alt-/meta-, shift- prefixes,
    \\                       function keys (f1-f12), and combinations like
    \\                       ctrl-alt-f or shift-up. Run `hty keys` for details.
    \\  --seq STRING         Send a sequence of keys, text, and delays in one call.
    \\                       Quoted strings are text, durations (e.g. 200ms, 1s)
    \\                       are pauses, and bare words are key names.
    \\                       Example: --seq '"hello" 200ms enter 500ms "world"'
    \\  --bytes-hex HEX      Raw bytes encoded as hex.
    \\
    \\Delay flags (optional, combine with any mode above):
    \\  --delay-before DUR   Sleep before sending (e.g. 200ms, 1s).
    \\  --delay-after DUR    Sleep after sending.
    \\  --delay-char DUR     Send text character-by-character with a delay
    \\                       between each. Only works with --text or --seq.
    \\
    ;
}

pub fn run(alloc: Allocator, args: []const []const u8) !void {
    var session_ref: ?[]const u8 = null;
    var text: ?[]const u8 = null;
    var key: ?[]const u8 = null;
    var bytes_hex: ?[]const u8 = null;
    var seq: ?[]const u8 = null;
    var delay_before: ?[]const u8 = null;
    var delay_after: ?[]const u8 = null;
    var delay_char: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--text")) {
            i += 1;
            if (i >= args.len) return common.printUsageAndExit("--text requires a value");
            text = args[i];
        } else if (std.mem.eql(u8, arg, "--key")) {
            i += 1;
            if (i >= args.len) return common.printUsageAndExit("--key requires a value");
            key = args[i];
        } else if (std.mem.eql(u8, arg, "--bytes-hex")) {
            i += 1;
            if (i >= args.len) return common.printUsageAndExit("--bytes-hex requires a value");
            bytes_hex = args[i];
        } else if (std.mem.eql(u8, arg, "--seq")) {
            i += 1;
            if (i >= args.len) return common.printUsageAndExit("--seq requires a value");
            seq = args[i];
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

    var op_count: u8 = 0;
    if (text != null) op_count += 1;
    if (key != null) op_count += 1;
    if (bytes_hex != null) op_count += 1;
    if (seq != null) op_count += 1;
    if (op_count != 1) {
        try common.printErr("hty send requires exactly one of --text, --key, --bytes-hex, --seq");
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

    if (char_ms > 0 and text == null and seq == null) {
        try common.printErr("--delay-char only applies to --text or --seq");
        std.process.exit(common.ExitCode.generic);
    }

    // Build token list — everything becomes a sequence internally.
    var token_list: SeqTokenList = undefined;

    if (seq) |s| {
        token_list = parseSeqTokens(s) catch {
            try common.printErr("invalid --seq syntax: unmatched quote");
            std.process.exit(common.ExitCode.generic);
            unreachable;
        };
        if (token_list.len == 0) {
            try common.printErr("--seq requires at least one token");
            std.process.exit(common.ExitCode.generic);
        }
    } else if (text) |t| {
        token_list = .{};
        const unescaped = unescapeText(alloc, t) catch {
            try common.printErr("invalid escape sequence in --text value");
            std.process.exit(common.ExitCode.generic);
            unreachable;
        };
        token_list.tokens[0] = .{ .kind = .text, .value = unescaped };
        token_list.len = 1;
    } else if (key) |k| {
        token_list = .{};
        token_list.tokens[0] = .{ .kind = .key, .value = k };
        token_list.len = 1;
    } else if (bytes_hex) |b| {
        token_list = .{};
        token_list.tokens[0] = .{ .kind = .bytes_hex, .value = b };
        token_list.len = 1;
    } else unreachable;

    // Expand --delay-char: split text tokens into per-character tokens
    // with delay tokens interleaved.
    if (char_ms > 0) {
        var expanded: SeqTokenList = .{};
        for (token_list.slice()) |token| {
            if (token.kind == .text and token.value.len > 1) {
                // Split into individual characters with delays between them.
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
                    // Add delay between characters (not after the last one).
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
        token_list = expanded;
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
            std.Thread.sleep(token.delay_ms * std.time.ns_per_ms);
            continue;
        }

        var payload_buf = std.array_list.Managed(u8).init(alloc);
        defer payload_buf.deinit();
        var writer = payload_buf.writer();

        switch (token.kind) {
            .text => {
                try writer.writeAll("{\"op\":\"send_text\",\"text\":");
                try common.writeJsonString(writer.any(), token.value);
            },
            .key => {
                try writer.writeAll("{\"op\":\"send_key\",\"key\":");
                try common.writeJsonString(writer.any(), token.value);
            },
            .bytes_hex => {
                try writer.writeAll("{\"op\":\"send_bytes_hex\",\"bytes_hex\":");
                try common.writeJsonString(writer.any(), token.value);
            },
            .delay => unreachable,
        }

        if (session_ref) |sr| {
            try writer.writeAll(",\"session\":");
            try common.writeJsonString(writer.any(), sr);
        }
        try writer.writeAll("}");

        const response_line = try common.sendRawRequest(alloc, payload_buf.items);
        defer alloc.free(response_line);

        var parsed = try std.json.parseFromSlice(std.json.Value, alloc, response_line, .{});
        defer parsed.deinit();
        _ = try common.expectOkOrExit(parsed);
    }
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
/// All other bare words become key tokens.
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
/// Supports: \n \t \r \\ \e (ESC). A trailing backslash or an
/// unrecognised escape like \z is an error.
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
                else => return error.InvalidEscape,
            }
        } else {
            try buf.append(input[i]);
        }
        i += 1;
    }
    return buf.toOwnedSlice();
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

test "unescapeText: unknown escape is an error" {
    try std.testing.expectError(error.InvalidEscape, unescapeText(std.testing.allocator, "hello\\z"));
}

test "unescapeText: multiple escapes in one string" {
    const result = try unescapeText(std.testing.allocator, "line1\\nline2\\ttab\\\\backslash");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("line1\nline2\ttab\\backslash", result);
}
