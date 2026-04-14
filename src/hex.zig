//! Lowercase-hex encode/decode. Used for the `bytes_hex` field in the wire
//! protocol (input/output events in the session log, raw byte sends).

const std = @import("std");
const Allocator = std.mem.Allocator;

pub fn encodeHex(arena: Allocator, bytes: []const u8) ![]const u8 {
    const out = try arena.alloc(u8, bytes.len * 2);
    const chars = "0123456789abcdef";
    for (bytes, 0..) |byte, index| {
        out[index * 2] = chars[byte >> 4];
        out[index * 2 + 1] = chars[byte & 0x0f];
    }
    return out;
}

pub fn decodeHex(arena: Allocator, text: []const u8) ![]const u8 {
    if (text.len % 2 != 0) return error.InvalidHex;

    const bytes = try arena.alloc(u8, text.len / 2);
    for (bytes, 0..) |*byte, index| {
        const hi = try fromHexNibble(text[index * 2]);
        const lo = try fromHexNibble(text[index * 2 + 1]);
        byte.* = (hi << 4) | lo;
    }
    return bytes;
}

fn fromHexNibble(ch: u8) !u8 {
    return switch (ch) {
        '0'...'9' => ch - '0',
        'a'...'f' => ch - 'a' + 10,
        'A'...'F' => ch - 'A' + 10,
        else => error.InvalidHex,
    };
}
