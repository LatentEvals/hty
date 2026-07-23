//! UUIDv7 generation and prefix-resolution helpers.
//!
//! UUIDv7 encodes a millisecond timestamp in the high 48 bits, making IDs
//! time-sortable. Combined with random low bits, two UUIDs created back-to-back
//! share a prefix that grows as the timestamps diverge — which is what
//! `shortestUniquePrefixLen` exploits to size the ID column in `hty list`.

const std = @import("std");
const sys = @import("hty").sys;

/// Generate a UUIDv7 into `out` as a 36-char hex-with-dashes string.
/// Layout: 48 bits unix-ms timestamp | 4 bits version=7 | 12 bits rand |
///         2 bits variant=10 | 62 bits rand.
pub fn generateUuidV7(out: *[36]u8) void {
    var bytes: [16]u8 = undefined;
    sys.random(&bytes);

    const ms: u64 = @intCast(sys.milliTimestamp());
    bytes[0] = @intCast((ms >> 40) & 0xff);
    bytes[1] = @intCast((ms >> 32) & 0xff);
    bytes[2] = @intCast((ms >> 24) & 0xff);
    bytes[3] = @intCast((ms >> 16) & 0xff);
    bytes[4] = @intCast((ms >> 8) & 0xff);
    bytes[5] = @intCast(ms & 0xff);

    // Version 7 in the high nibble of byte 6.
    bytes[6] = (bytes[6] & 0x0f) | 0x70;
    // Variant 10 in the top 2 bits of byte 8.
    bytes[8] = (bytes[8] & 0x3f) | 0x80;

    const chars = "0123456789abcdef";
    var idx: usize = 0;
    for (bytes, 0..) |b, i| {
        if (i == 4 or i == 6 or i == 8 or i == 10) {
            out[idx] = '-';
            idx += 1;
        }
        out[idx] = chars[b >> 4];
        out[idx + 1] = chars[b & 0x0f];
        idx += 2;
    }
}

/// Return the smallest prefix length at which every string in `ids` is unique,
/// clamped to [min_len, 36]. Used to size the ID column in `hty list` so that
/// UUIDv7 collisions within the same millisecond grow the display instead of
/// showing visually-duplicate rows.
pub fn shortestUniquePrefixLen(ids: []const []const u8, min_len: usize) usize {
    var len = min_len;
    while (len <= 36) : (len += 1) {
        var collision = false;
        for (ids, 0..) |a, i| {
            for (ids[i + 1 ..]) |b| {
                if (a.len >= len and b.len >= len and std.mem.eql(u8, a[0..len], b[0..len])) {
                    collision = true;
                    break;
                }
            }
            if (collision) break;
        }
        if (!collision) return len;
    }
    return 36;
}

test "uuidv7 is well-formed" {
    var id: [36]u8 = undefined;
    generateUuidV7(&id);

    try std.testing.expectEqual(@as(u8, '-'), id[8]);
    try std.testing.expectEqual(@as(u8, '-'), id[13]);
    try std.testing.expectEqual(@as(u8, '-'), id[18]);
    try std.testing.expectEqual(@as(u8, '-'), id[23]);
    try std.testing.expectEqual(@as(u8, '7'), id[14]); // version

    // Variant nibble (high nibble of byte 8 in string form = id[19]).
    const variant = id[19];
    try std.testing.expect(variant == '8' or variant == '9' or variant == 'a' or variant == 'b');
}

test "uuidv7 is unique across calls" {
    var a: [36]u8 = undefined;
    var b: [36]u8 = undefined;
    generateUuidV7(&a);
    generateUuidV7(&b);
    try std.testing.expect(!std.mem.eql(u8, &a, &b));
}

test "shortestUniquePrefixLen grows past collisions" {
    // All unique at 8.
    {
        const ids = [_][]const u8{ "aaaaaaaaxxxx", "bbbbbbbbyyyy" };
        try std.testing.expectEqual(@as(usize, 8), shortestUniquePrefixLen(&ids, 8));
    }
    // Share 8 but differ at 9.
    {
        const ids = [_][]const u8{ "01860f08a000", "01860f08b000" };
        try std.testing.expectEqual(@as(usize, 9), shortestUniquePrefixLen(&ids, 8));
    }
    // Share first 11 chars (01860f08aa0), differ at index 11.
    {
        const ids = [_][]const u8{ "01860f08aa01", "01860f08aa02" };
        try std.testing.expectEqual(@as(usize, 12), shortestUniquePrefixLen(&ids, 8));
    }
    // Single session: min_len wins.
    {
        const ids = [_][]const u8{"01860f08abcdefgh"};
        try std.testing.expectEqual(@as(usize, 8), shortestUniquePrefixLen(&ids, 8));
    }
}
