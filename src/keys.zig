//! Symbolic key name → terminal byte sequence encoder.
//!
//! Accepts inputs like `"enter"`, `"ctrl-c"`, `"shift-f1"`, `"alt-shift-up"`,
//! or single printable characters (`"a"`, `"?"`). Returns the byte sequence
//! a real terminal would generate for the equivalent keystroke — CSI
//! sequences for arrows/function keys, SS3 for F1-F4, control-chord bytes
//! for `ctrl-X`, and `ESC`-prefixed for `alt-X`.
//!
//! Used by the `send_key` RPC op (server side via `keyToBytes`) and by the
//! `hty send --key` command (client side, same function).

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Modifiers = struct {
    ctrl: bool = false,
    alt: bool = false,
    shift: bool = false,

    fn param(self: Modifiers) u8 {
        var bits: u8 = 0;
        if (self.shift) bits |= 1;
        if (self.alt) bits |= 2;
        if (self.ctrl) bits |= 4;
        return bits + 1;
    }

    fn any(self: Modifiers) bool {
        return self.ctrl or self.alt or self.shift;
    }
};

const BaseKeyKind = enum { arrow, tilde, function_ss3, function_tilde, simple, printable };

const BaseKey = struct {
    kind: BaseKeyKind,
    // For arrow: the final letter (A/B/C/D/H/F).
    // For tilde/function_tilde: the numeric code.
    // For function_ss3: the final letter (P/Q/R/S).
    // For simple: the byte value.
    // For printable: the character.
    code: u8,
};

pub fn parseModifiers(input: []const u8) !struct { mods: Modifiers, rest: []const u8 } {
    var mods: Modifiers = .{};
    var remaining = input;

    while (remaining.len > 0) {
        const prefix_result = matchModifierPrefix(remaining);
        if (prefix_result.kind == .none) break;

        switch (prefix_result.kind) {
            .ctrl => {
                if (mods.ctrl) return error.InvalidKey;
                mods.ctrl = true;
            },
            .alt => {
                if (mods.alt) return error.InvalidKey;
                mods.alt = true;
            },
            .shift => {
                if (mods.shift) return error.InvalidKey;
                mods.shift = true;
            },
            .none => unreachable,
        }
        remaining = remaining[prefix_result.len..];
    }

    return .{ .mods = mods, .rest = remaining };
}

const ModifierKind = enum { ctrl, alt, shift, none };

fn matchModifierPrefix(input: []const u8) struct { kind: ModifierKind, len: usize } {
    const prefixes = [_]struct { text: []const u8, kind: ModifierKind }{
        .{ .text = "ctrl-", .kind = .ctrl },
        .{ .text = "ctrl+", .kind = .ctrl },
        .{ .text = "c-", .kind = .ctrl },
        .{ .text = "alt-", .kind = .alt },
        .{ .text = "meta-", .kind = .alt },
        .{ .text = "m-", .kind = .alt },
        .{ .text = "shift-", .kind = .shift },
        .{ .text = "s-", .kind = .shift },
    };

    for (prefixes) |p| {
        if (startsWithIgnoreCase(input, p.text)) {
            // Disambiguate: if the remainder after this prefix is empty, this
            // isn't a modifier — it's the base key (e.g. "s-" with nothing
            // after is invalid, but we shouldn't match "s" as shift prefix
            // when input is exactly "s-"). However, "s-" alone would leave
            // an empty remainder which resolveBaseKey will reject. The real
            // ambiguity is single-char prefixes like "c-" or "m-" or "s-"
            // where the hyphen could be part of a longer base key name.
            // Since we check longest prefixes first (ctrl- before c-), and
            // the parser always tries the longest match, this is fine.
            return .{ .kind = p.kind, .len = p.text.len };
        }
    }
    return .{ .kind = .none, .len = 0 };
}

pub fn resolveBaseKey(name: []const u8) ?BaseKey {
    // Arrow keys
    if (std.ascii.eqlIgnoreCase(name, "up")) return .{ .kind = .arrow, .code = 'A' };
    if (std.ascii.eqlIgnoreCase(name, "down")) return .{ .kind = .arrow, .code = 'B' };
    if (std.ascii.eqlIgnoreCase(name, "right")) return .{ .kind = .arrow, .code = 'C' };
    if (std.ascii.eqlIgnoreCase(name, "left")) return .{ .kind = .arrow, .code = 'D' };
    if (std.ascii.eqlIgnoreCase(name, "home")) return .{ .kind = .arrow, .code = 'H' };
    if (std.ascii.eqlIgnoreCase(name, "end")) return .{ .kind = .arrow, .code = 'F' };

    // Tilde keys
    if (std.ascii.eqlIgnoreCase(name, "insert")) return .{ .kind = .tilde, .code = 2 };
    if (std.ascii.eqlIgnoreCase(name, "delete")) return .{ .kind = .tilde, .code = 3 };
    if (std.ascii.eqlIgnoreCase(name, "pageup")) return .{ .kind = .tilde, .code = 5 };
    if (std.ascii.eqlIgnoreCase(name, "pagedown")) return .{ .kind = .tilde, .code = 6 };

    // Simple keys
    if (std.ascii.eqlIgnoreCase(name, "enter") or std.ascii.eqlIgnoreCase(name, "return")) return .{ .kind = .simple, .code = '\r' };
    if (std.ascii.eqlIgnoreCase(name, "tab")) return .{ .kind = .simple, .code = '\t' };
    if (std.ascii.eqlIgnoreCase(name, "esc") or std.ascii.eqlIgnoreCase(name, "escape")) return .{ .kind = .simple, .code = '\x1b' };
    if (std.ascii.eqlIgnoreCase(name, "space")) return .{ .kind = .simple, .code = ' ' };
    if (std.ascii.eqlIgnoreCase(name, "backspace")) return .{ .kind = .simple, .code = '\x7f' };

    // Function keys F1-F4 (SS3 encoding)
    if (std.ascii.eqlIgnoreCase(name, "f1")) return .{ .kind = .function_ss3, .code = 'P' };
    if (std.ascii.eqlIgnoreCase(name, "f2")) return .{ .kind = .function_ss3, .code = 'Q' };
    if (std.ascii.eqlIgnoreCase(name, "f3")) return .{ .kind = .function_ss3, .code = 'R' };
    if (std.ascii.eqlIgnoreCase(name, "f4")) return .{ .kind = .function_ss3, .code = 'S' };

    // Function keys F5-F12 (tilde encoding)
    if (std.ascii.eqlIgnoreCase(name, "f5")) return .{ .kind = .function_tilde, .code = 15 };
    if (std.ascii.eqlIgnoreCase(name, "f6")) return .{ .kind = .function_tilde, .code = 17 };
    if (std.ascii.eqlIgnoreCase(name, "f7")) return .{ .kind = .function_tilde, .code = 18 };
    if (std.ascii.eqlIgnoreCase(name, "f8")) return .{ .kind = .function_tilde, .code = 19 };
    if (std.ascii.eqlIgnoreCase(name, "f9")) return .{ .kind = .function_tilde, .code = 20 };
    if (std.ascii.eqlIgnoreCase(name, "f10")) return .{ .kind = .function_tilde, .code = 21 };
    if (std.ascii.eqlIgnoreCase(name, "f11")) return .{ .kind = .function_tilde, .code = 23 };
    if (std.ascii.eqlIgnoreCase(name, "f12")) return .{ .kind = .function_tilde, .code = 24 };

    // Single printable character
    if (name.len == 1) return .{ .kind = .printable, .code = name[0] };

    return null;
}

pub fn keyToBytes(arena: Allocator, key: []const u8) ![]const u8 {
    const parsed = try parseModifiers(key);
    const mods = parsed.mods;
    const base = resolveBaseKey(parsed.rest) orelse return error.InvalidKey;
    const param = mods.param();

    switch (base.kind) {
        .printable => {
            const char = std.ascii.toLower(base.code);

            if (mods.shift) {
                // shift on a printable char is meaningless — just type the uppercase letter
                return error.InvalidKey;
            }

            if (mods.ctrl and mods.alt) {
                // ESC + ctrl-char
                const bytes = try arena.alloc(u8, 2);
                bytes[0] = '\x1b';
                if (std.ascii.isAlphanumeric(char) or char == '[' or char == '\\' or char == ']' or char == '^' or char == '_') {
                    bytes[1] = char & 0x1f;
                } else {
                    return error.InvalidKey;
                }
                return bytes;
            }

            if (mods.ctrl) {
                if (!std.ascii.isAlphanumeric(char) and char != '[' and char != '\\' and char != ']' and char != '^' and char != '_') {
                    return error.InvalidKey;
                }
                const bytes = try arena.alloc(u8, 1);
                bytes[0] = char & 0x1f;
                return bytes;
            }

            if (mods.alt) {
                // ESC + char (preserve original case)
                const bytes = try arena.alloc(u8, 2);
                bytes[0] = '\x1b';
                bytes[1] = base.code;
                return bytes;
            }

            // No modifiers — return the character as-is
            const bytes = try arena.alloc(u8, 1);
            bytes[0] = base.code;
            return bytes;
        },

        .simple => {
            // Special case: shift-tab = backtab
            if (base.code == '\t' and mods.shift and !mods.ctrl and !mods.alt) {
                return "\x1b[Z";
            }

            if (!mods.any()) return try arena.dupe(u8, &[_]u8{base.code});

            // For other simple keys with modifiers, only alt makes sense
            // (e.g. alt-enter = ESC + \r, alt-space = ESC + space)
            if (mods.alt and !mods.ctrl and !mods.shift) {
                const bytes = try arena.alloc(u8, 2);
                bytes[0] = '\x1b';
                bytes[1] = base.code;
                return bytes;
            }

            // Other modifier combos on simple keys aren't standard
            return error.InvalidKey;
        },

        .arrow => {
            if (!mods.any()) {
                // \x1b[A
                return try std.fmt.allocPrint(arena, "\x1b[{c}", .{base.code});
            }
            // \x1b[1;{param}{letter}
            return try std.fmt.allocPrint(arena, "\x1b[1;{d}{c}", .{ param, base.code });
        },

        .tilde => {
            if (!mods.any()) {
                // \x1b[{code}~
                return try std.fmt.allocPrint(arena, "\x1b[{d}~", .{base.code});
            }
            // \x1b[{code};{param}~
            return try std.fmt.allocPrint(arena, "\x1b[{d};{d}~", .{ base.code, param });
        },

        .function_ss3 => {
            if (!mods.any()) {
                // \x1bO{letter}
                return try std.fmt.allocPrint(arena, "\x1bO{c}", .{base.code});
            }
            // With modifiers: \x1b[1;{param}{letter}
            return try std.fmt.allocPrint(arena, "\x1b[1;{d}{c}", .{ param, base.code });
        },

        .function_tilde => {
            if (!mods.any()) {
                // \x1b[{code}~
                return try std.fmt.allocPrint(arena, "\x1b[{d}~", .{base.code});
            }
            // \x1b[{code};{param}~
            return try std.fmt.allocPrint(arena, "\x1b[{d};{d}~", .{ base.code, param });
        },
    }
}

fn startsWithIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    return std.ascii.eqlIgnoreCase(haystack[0..needle.len], needle);
}

test "key encoding covers arrows and control chords" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Existing behavior (regression)
    try std.testing.expectEqualStrings("\x1b[B", try keyToBytes(arena, "down"));
    try std.testing.expectEqualStrings("\x1b[A", try keyToBytes(arena, "up"));
    try std.testing.expectEqualStrings("\r", try keyToBytes(arena, "enter"));
    try std.testing.expectEqualStrings("\r", try keyToBytes(arena, "return"));
    try std.testing.expectEqualStrings("\t", try keyToBytes(arena, "tab"));
    try std.testing.expectEqualStrings("\x1b", try keyToBytes(arena, "esc"));
    try std.testing.expectEqualStrings(" ", try keyToBytes(arena, "space"));
    try std.testing.expectEqualStrings("\x7f", try keyToBytes(arena, "backspace"));
    try std.testing.expectEqualStrings("\x1b[H", try keyToBytes(arena, "home"));
    try std.testing.expectEqualStrings("\x1b[F", try keyToBytes(arena, "end"));
    try std.testing.expectEqualStrings("\x1b[5~", try keyToBytes(arena, "pageup"));
    try std.testing.expectEqualStrings("\x1b[6~", try keyToBytes(arena, "pagedown"));
    try std.testing.expectEqualStrings("\x1b[2~", try keyToBytes(arena, "insert"));
    try std.testing.expectEqualStrings("\x1b[3~", try keyToBytes(arena, "delete"));
    try std.testing.expectEqualStrings("\x18", try keyToBytes(arena, "ctrl-x"));
    try std.testing.expectEqualStrings("\x01", try keyToBytes(arena, "c-a"));
    try std.testing.expectEqualStrings("i", try keyToBytes(arena, "i"));
}

test "key encoding: function keys" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expectEqualStrings("\x1bOP", try keyToBytes(arena, "f1"));
    try std.testing.expectEqualStrings("\x1bOQ", try keyToBytes(arena, "f2"));
    try std.testing.expectEqualStrings("\x1bOR", try keyToBytes(arena, "f3"));
    try std.testing.expectEqualStrings("\x1bOS", try keyToBytes(arena, "f4"));
    try std.testing.expectEqualStrings("\x1b[15~", try keyToBytes(arena, "f5"));
    try std.testing.expectEqualStrings("\x1b[17~", try keyToBytes(arena, "f6"));
    try std.testing.expectEqualStrings("\x1b[18~", try keyToBytes(arena, "f7"));
    try std.testing.expectEqualStrings("\x1b[19~", try keyToBytes(arena, "f8"));
    try std.testing.expectEqualStrings("\x1b[20~", try keyToBytes(arena, "f9"));
    try std.testing.expectEqualStrings("\x1b[21~", try keyToBytes(arena, "f10"));
    try std.testing.expectEqualStrings("\x1b[23~", try keyToBytes(arena, "f11"));
    try std.testing.expectEqualStrings("\x1b[24~", try keyToBytes(arena, "f12"));
    // Case insensitive
    try std.testing.expectEqualStrings("\x1bOP", try keyToBytes(arena, "F1"));
}

test "key encoding: alt/meta modifier" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expectEqualStrings("\x1bx", try keyToBytes(arena, "alt-x"));
    try std.testing.expectEqualStrings("\x1bf", try keyToBytes(arena, "meta-f"));
    try std.testing.expectEqualStrings("\x1bb", try keyToBytes(arena, "m-b"));
    // Alt + arrow
    try std.testing.expectEqualStrings("\x1b[1;3C", try keyToBytes(arena, "alt-right"));
    // Alt + function key
    try std.testing.expectEqualStrings("\x1b[1;3R", try keyToBytes(arena, "alt-f3"));
    // Alt + tilde key
    try std.testing.expectEqualStrings("\x1b[5;3~", try keyToBytes(arena, "alt-pageup"));
    // Alt + enter
    try std.testing.expectEqualStrings("\x1b\r", try keyToBytes(arena, "alt-enter"));
}

test "key encoding: shift modifier" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Backtab
    try std.testing.expectEqualStrings("\x1b[Z", try keyToBytes(arena, "shift-tab"));
    try std.testing.expectEqualStrings("\x1b[Z", try keyToBytes(arena, "s-tab"));
    // Shift + arrows
    try std.testing.expectEqualStrings("\x1b[1;2A", try keyToBytes(arena, "shift-up"));
    try std.testing.expectEqualStrings("\x1b[1;2D", try keyToBytes(arena, "s-left"));
    // Shift + home/end
    try std.testing.expectEqualStrings("\x1b[1;2H", try keyToBytes(arena, "shift-home"));
    try std.testing.expectEqualStrings("\x1b[1;2F", try keyToBytes(arena, "shift-end"));
    // Shift + function key
    try std.testing.expectEqualStrings("\x1b[1;2P", try keyToBytes(arena, "shift-f1"));
    // Shift on printable is an error
    try std.testing.expectError(error.InvalidKey, keyToBytes(arena, "shift-a"));
}

test "key encoding: multi-modifier combos" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // ctrl-alt on printable: ESC + ctrl-char
    try std.testing.expectEqualStrings("\x1b\x06", try keyToBytes(arena, "ctrl-alt-f"));
    // ctrl-shift on arrow (param = 1 + 4 + 1 = 6)
    try std.testing.expectEqualStrings("\x1b[1;6A", try keyToBytes(arena, "ctrl-shift-up"));
    // alt-shift on arrow (param = 1 + 2 + 1 = 4)
    try std.testing.expectEqualStrings("\x1b[1;4B", try keyToBytes(arena, "alt-shift-down"));
    // ctrl-alt on arrow (param = 1 + 4 + 2 = 7)
    try std.testing.expectEqualStrings("\x1b[1;7C", try keyToBytes(arena, "ctrl-alt-right"));
    // All three on arrow (param = 1 + 4 + 2 + 1 = 8)
    try std.testing.expectEqualStrings("\x1b[1;8D", try keyToBytes(arena, "ctrl-alt-shift-left"));
    // Order shouldn't matter
    try std.testing.expectEqualStrings("\x1b[1;7C", try keyToBytes(arena, "alt-ctrl-right"));
    // Duplicate modifier is an error
    try std.testing.expectError(error.InvalidKey, keyToBytes(arena, "ctrl-ctrl-x"));
}
