const std = @import("std");

const Allocator = std.mem.Allocator;

const runServer = @import("server.zig").runServer;

const c = @cImport({
    @cInclude("unistd.h");
});

pub const EnsureServerOptions = struct {
    attempts: usize = 30,
    delay_ms: u64 = 50,
};

pub fn ensureServer(alloc: Allocator, socket_path: []const u8, opts: EnsureServerOptions) !std.net.Stream {
    if (tryConnect(socket_path)) |stream| return stream else |err| switch (err) {
        error.FileNotFound, error.ConnectionRefused => {
            // When HTY_SOCKET is set we assume the server lives on another
            // machine (or at least another namespace) behind that endpoint.
            // Don't try to spawn a local one — fail fast so the user knows
            // their tunnel is down.
            if (std.posix.getenv("HTY_SOCKET")) |override| {
                if (override.len > 0) return error.ServerUnreachable;
            }
            // Stale or missing socket — try to unlink and spawn.
            std.posix.unlink(socket_path) catch {};
            try spawnServer(alloc, socket_path);
        },
        else => return err,
    }

    // Retry connection with backoff.
    var attempt: usize = 0;
    while (attempt < opts.attempts) : (attempt += 1) {
        if (tryConnect(socket_path)) |stream| return stream else |_| {}
        std.Thread.sleep(opts.delay_ms * std.time.ns_per_ms);
    }
    return error.ServerUnreachable;
}

pub fn tryConnect(socket_path: []const u8) !std.net.Stream {
    return std.net.connectUnixSocket(socket_path);
}

pub fn spawnServer(alloc: Allocator, socket_path: []const u8) !void {
    const pid = std.posix.fork() catch return error.ForkFailed;
    if (pid != 0) return;

    // Child: detach from terminal, redirect stdio to /dev/null, then exec a
    // fresh `hty __server__ <socket>` so `ps`/`pgrep` can find the server
    // process by a distinct argv rather than inheriting the parent's.
    _ = c.setsid();
    const devnull = std.posix.open("/dev/null", .{ .ACCMODE = .RDWR }, 0) catch {
        std.posix.exit(1);
    };
    _ = std.posix.dup2(devnull, 0) catch {};
    _ = std.posix.dup2(devnull, 1) catch {};
    _ = std.posix.dup2(devnull, 2) catch {};
    if (devnull > 2) std.posix.close(devnull);

    var self_buf: [std.fs.max_path_bytes]u8 = undefined;
    const self_exe = std.fs.selfExePath(&self_buf) catch {
        // Fallback: run the server in-process. The process name will still
        // be the parent's argv, but at least the server starts.
        runServer(alloc, socket_path) catch std.posix.exit(1);
        std.posix.exit(0);
    };

    const self_exe_z = alloc.dupeZ(u8, self_exe) catch std.posix.exit(1);
    defer alloc.free(self_exe_z);
    const socket_z = alloc.dupeZ(u8, socket_path) catch std.posix.exit(1);
    defer alloc.free(socket_z);

    const argv = [_:null]?[*:0]const u8{
        self_exe_z.ptr,
        "__server__",
        socket_z.ptr,
        null,
    };

    // Pass the parent's environment so $HOME, $XDG_STATE_HOME, $XDG_RUNTIME_DIR
    // etc. reach the server. With an empty envp the log dir can't be resolved.
    _ = c.execve(self_exe_z.ptr, @ptrCast(&argv), @ptrCast(std.c.environ));
    // execve only returns on failure.
    runServer(alloc, socket_path) catch std.posix.exit(1);
    std.posix.exit(0);
}
