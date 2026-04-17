//! Typed field readers for `std.json.ObjectMap`. Two flavors:
//!
//! * `read*` helpers enforce types (e.g. `readRequiredString` returns an error
//!   if the field is missing or not a string). Used by the RPC dispatcher
//!   where schema violations should surface as `{ok:false, error:...}`.
//! * `get*` helpers return `null` on any mismatch. Used for lenient parsers
//!   (log-file walkers) where a malformed event should be skipped, not
//!   reported as an error.

const std = @import("std");
const hty = @import("hty");
const Allocator = std.mem.Allocator;

// ---- strict readers (return errors on schema violations) ----

pub fn readOptionalId(object: std.json.ObjectMap) ?i64 {
    const value = object.get("id") orelse return null;
    return switch (value) {
        .integer => |integer| integer,
        else => null,
    };
}

pub fn readRequiredString(object: std.json.ObjectMap, key: []const u8) ![]const u8 {
    const value = object.get(key) orelse return error.MissingField;
    return switch (value) {
        .string => |string| string,
        else => error.InvalidFieldType,
    };
}

pub fn readOptionalString(object: std.json.ObjectMap, key: []const u8) !?[]const u8 {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .null => null,
        .string => |string| string,
        else => error.InvalidFieldType,
    };
}

pub fn readOptionalBool(object: std.json.ObjectMap, key: []const u8, default: bool) !bool {
    const value = object.get(key) orelse return default;
    return switch (value) {
        .bool => |boolean| boolean,
        else => error.InvalidFieldType,
    };
}

pub fn readRequiredU64(object: std.json.ObjectMap, key: []const u8) !u64 {
    const value = object.get(key) orelse return error.MissingField;
    return switch (value) {
        .integer => |integer| {
            if (integer < 0) return error.InvalidFieldValue;
            return @intCast(integer);
        },
        else => error.InvalidFieldType,
    };
}

pub fn readOptionalU64(object: std.json.ObjectMap, key: []const u8, default: u64) !u64 {
    const value = object.get(key) orelse return default;
    return switch (value) {
        .integer => |integer| {
            if (integer < 0) return error.InvalidFieldValue;
            return @intCast(integer);
        },
        else => error.InvalidFieldType,
    };
}

pub fn readOptionalUsize(object: std.json.ObjectMap, key: []const u8, default: usize) !usize {
    const value = object.get(key) orelse return default;
    return switch (value) {
        .integer => |integer| {
            if (integer < 0) return error.InvalidFieldValue;
            return @intCast(integer);
        },
        else => error.InvalidFieldType,
    };
}

pub fn readRequiredU16(object: std.json.ObjectMap, key: []const u8) !u16 {
    const value = object.get(key) orelse return error.MissingField;
    return toU16(value);
}

pub fn readOptionalU16(object: std.json.ObjectMap, key: []const u8, default: u16) !u16 {
    const value = object.get(key) orelse return default;
    return toU16(value);
}

fn toU16(value: std.json.Value) !u16 {
    return switch (value) {
        .integer => |integer| {
            if (integer < 0 or integer > std.math.maxInt(u16)) return error.InvalidFieldValue;
            return @intCast(integer);
        },
        else => error.InvalidFieldType,
    };
}

pub fn readStringArray(arena: Allocator, object: std.json.ObjectMap, key: []const u8) ![]const []const u8 {
    const value = object.get(key) orelse return &.{};
    const array = switch (value) {
        .array => |array| array,
        else => return error.InvalidFieldType,
    };

    const items = try arena.alloc([]const u8, array.items.len);
    for (array.items, 0..) |item, index| {
        items[index] = switch (item) {
            .string => |string| string,
            else => return error.InvalidFieldType,
        };
    }
    return items;
}

pub fn readEnvArray(arena: Allocator, object: std.json.ObjectMap, key: []const u8) ![]const hty.EnvVar {
    const value = object.get(key) orelse return &.{};

    return switch (value) {
        .object => |env_object| blk: {
            const items = try arena.alloc(hty.EnvVar, env_object.count());
            var iterator = env_object.iterator();
            var index: usize = 0;
            while (iterator.next()) |entry| : (index += 1) {
                items[index] = .{
                    .key = entry.key_ptr.*,
                    .value = switch (entry.value_ptr.*) {
                        .string => |string| string,
                        else => return error.InvalidFieldType,
                    },
                };
            }
            break :blk items;
        },
        .array => |env_array| blk: {
            const items = try arena.alloc(hty.EnvVar, env_array.items.len);
            for (env_array.items, 0..) |item, index| {
                const env_object = switch (item) {
                    .object => |env_object| env_object,
                    else => return error.InvalidFieldType,
                };
                items[index] = .{
                    .key = try readRequiredString(env_object, "key"),
                    .value = try readRequiredString(env_object, "value"),
                };
            }
            break :blk items;
        },
        else => error.InvalidFieldType,
    };
}

// ---- lenient getters (return null on any mismatch) ----

pub fn getString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

pub fn getInteger(obj: std.json.ObjectMap, key: []const u8) ?i64 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .integer => |i| i,
        else => null,
    };
}
