//! `hty info` — print resolved paths and server status.

const std = @import("std");
const Allocator = std.mem.Allocator;

const common = @import("common.zig");
const paths = @import("../paths.zig");
const ensure = @import("../ensure.zig");

pub fn helpText() []const u8 {
    return
    \\hty info
    \\
    \\Show resolved paths and server status. Useful for finding the socket
    \\path when setting up SSH tunnels for remote observation.
    \\
    \\Output includes:
    \\  socket    Path to the Unix domain socket
    \\  logs      Directory where session logs are stored
    \\  server    Whether the server is currently running
    \\
    \\Environment variables that affect paths ($HTY_SOCKET, $XDG_RUNTIME_DIR,
    \\$XDG_STATE_HOME) are shown if set.
    \\
    ;
}

pub fn run(alloc: Allocator) !void {
    const socket_path = try paths.resolveSocketPath(alloc);
    defer alloc.free(socket_path);
    const log_dir = try paths.resolveLogDir(alloc);
    defer alloc.free(log_dir);

    // Check server status by trying to connect.
    const server_status: []const u8 = blk: {
        if (ensure.tryConnect(socket_path)) |stream| {
            stream.close();
            break :blk "running";
        } else |_| {
            break :blk "not running";
        }
    };

    var buf: std.ArrayListUnmanaged(u8) = .{};
    defer buf.deinit(alloc);
    const w = buf.writer(alloc);

    try w.print("socket:  {s}\n", .{socket_path});
    try w.print("logs:    {s}\n", .{log_dir});
    try w.print("server:  {s}\n", .{server_status});

    // Show relevant env vars if set.
    if (std.posix.getenv("HTY_SOCKET")) |v| {
        if (v.len > 0) try w.print("\n$HTY_SOCKET={s}\n", .{v});
    }
    if (std.posix.getenv("XDG_RUNTIME_DIR")) |v| {
        if (v.len > 0) try w.print("$XDG_RUNTIME_DIR={s}\n", .{v});
    }
    if (std.posix.getenv("XDG_STATE_HOME")) |v| {
        if (v.len > 0) try w.print("$XDG_STATE_HOME={s}\n", .{v});
    }

    try common.printRaw(buf.items);
}
