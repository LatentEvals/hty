const std = @import("std");
const sys = @import("hty").sys;

const Allocator = std.mem.Allocator;

const runServer = @import("server.zig").runServer;

const c = @cImport({
    @cInclude("unistd.h");
    @cInclude("sys/stat.h");
});

pub const EnsureServerOptions = struct {
    attempts: usize = 30,
    delay_ms: u64 = 50,
};

/// Connect to the server socket, auto-starting a local server when nothing is
/// listening. Every failure path prints an actionable diagnosis to stderr
/// before returning, so callers can exit(1) without a stack trace.
pub fn ensureServer(alloc: Allocator, io: std.Io, socket_path: []const u8, opts: EnsureServerOptions) !sys.Stream {
    if (tryConnect(socket_path)) |stream| return stream else |err| switch (err) {
        error.FileNotFound, error.ConnectionRefused => {
            // When HTY_SOCKET is set we assume the server lives on another
            // machine (or at least another namespace) behind that endpoint.
            // Don't try to spawn a local one — fail fast so the user knows
            // their tunnel is down.
            if (sys.getenv("HTY_SOCKET")) |override| {
                if (override.len > 0) {
                    printDiag(
                        \\error: cannot connect to hty server at {s}
                        \\HTY_SOCKET is set, so hty will not auto-start a local server.
                        \\Check the endpoint (is your tunnel up?) or unset HTY_SOCKET.
                    , .{socket_path});
                    return error.ServerUnreachable;
                }
            }
            // Stale or missing socket — unlink, check the dir accepts new
            // files, then spawn. Without the preflight a sandboxed or
            // read-only environment kills the forked server silently (its
            // stderr points at /dev/null) and all the user would see is a
            // generic timeout.
            sys.unlink(socket_path) catch {};
            const socket_dir = std.fs.path.dirname(socket_path) orelse ".";
            preflightSocketDir(io, socket_path) catch |pf_err| {
                printDiag(
                    \\error: hty state dir is not writable: {s} ({s})
                    \\The server keeps its socket there. If this shell is sandboxed, rerun
                    \\outside the sandbox, or point XDG_STATE_HOME at a writable location.
                , .{ socket_dir, @errorName(pf_err) });
                return error.StateDirNotWritable;
            };
            const pid = try spawnServer(alloc, io, socket_path);

            // Retry connection with backoff, bailing out early if the
            // server process dies instead of waiting for the full timeout.
            var attempt: usize = 0;
            while (attempt < opts.attempts) : (attempt += 1) {
                if (tryConnect(socket_path)) |stream| return stream else |_| {}
                const wait = sys.waitpid(pid, std.posix.W.NOHANG);
                if (wait.pid == pid) {
                    if (std.posix.W.IFEXITED(wait.status)) {
                        printDiag("error: hty server exited during startup (exit status {d})", .{std.posix.W.EXITSTATUS(wait.status)});
                    } else {
                        printDiag("error: hty server died during startup", .{});
                    }
                    printDiag(
                        \\The server could not initialize. Check that {s} is writable —
                        \\sandboxed shells often block unix socket or log file creation.
                    , .{socket_dir});
                    return error.ServerStartupFailed;
                }
                sys.sleep(opts.delay_ms * std.time.ns_per_ms);
            }
            printDiag("error: hty server did not become reachable within {d} ms of starting", .{opts.attempts * opts.delay_ms});
            return error.ServerUnreachable;
        },
        error.NameTooLong => {
            printDiag(
                \\error: socket path is too long for a unix socket: {s}
                \\Set XDG_STATE_HOME (or HTY_SOCKET) to a shorter path.
            , .{socket_path});
            return error.SocketPathTooLong;
        },
        else => return err,
    }
}

pub fn tryConnect(socket_path: []const u8) !sys.Stream {
    return sys.connectUnixSocket(socket_path);
}

/// Verify the socket's directory accepts new files before forking a server.
/// Uses a real create-then-unlink probe rather than access(2) so sandbox
/// policies that deny writes regardless of permission bits are caught too.
fn preflightSocketDir(io: std.Io, socket_path: []const u8) !void {
    const dir_path = std.fs.path.dirname(socket_path) orelse return;
    var dir = try std.Io.Dir.cwd().openDir(io, dir_path, .{});
    defer dir.close(io);
    const probe_name = ".preflight";
    const probe = try dir.createFile(io, probe_name, .{});
    probe.close(io);
    dir.deleteFile(io, probe_name) catch {};
}

fn printDiag(comptime fmt: []const u8, args: anytype) void {
    const alloc = std.heap.c_allocator;
    const msg = std.fmt.allocPrint(alloc, fmt ++ "\n", args) catch return;
    defer alloc.free(msg);
    sys.writeAll(std.posix.STDERR_FILENO, msg) catch {};
}

/// Fork and exec a detached `hty __server__ <socket>`. Returns the child pid
/// so the caller can detect an early death while waiting for the socket.
pub fn spawnServer(alloc: Allocator, io: std.Io, socket_path: []const u8) !std.posix.pid_t {
    const pid = sys.fork() catch return error.ForkFailed;
    if (pid != 0) return pid;

    // Child: detach from terminal, redirect stdio to /dev/null, then exec a
    // fresh `hty __server__ <socket>` so `ps`/`pgrep` can find the server
    // process by a distinct argv rather than inheriting the parent's.
    _ = c.setsid();
    const devnull = sys.open("/dev/null", .{ .ACCMODE = .RDWR }, 0) catch {
        sys.exit(1);
    };
    _ = sys.dup2(devnull, 0) catch {};
    _ = sys.dup2(devnull, 1) catch {};
    _ = sys.dup2(devnull, 2) catch {};
    if (devnull > 2) sys.close(devnull);

    var self_buf: [std.fs.max_path_bytes]u8 = undefined;
    const self_len = std.process.executablePath(io, &self_buf) catch {
        // Fallback: run the server in-process. The process name will still
        // be the parent's argv, but at least the server starts.
        runServer(alloc, io, socket_path) catch sys.exit(1);
        sys.exit(0);
    };
    const self_exe = self_buf[0..self_len];

    const self_exe_z = alloc.dupeZ(u8, self_exe) catch sys.exit(1);
    defer alloc.free(self_exe_z);
    const socket_z = alloc.dupeZ(u8, socket_path) catch sys.exit(1);
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
    runServer(alloc, io, socket_path) catch sys.exit(1);
    sys.exit(0);
}

test "preflightSocketDir passes on a writable dir and leaves no probe behind" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "state", .default_dir);
    const alloc = std.testing.allocator;
    const state_path = try tmp.dir.realPathFileAlloc(io, "state", alloc);
    defer alloc.free(state_path);
    const sock_path = try std.fs.path.join(alloc, &.{ state_path, "sock" });
    defer alloc.free(sock_path);

    try preflightSocketDir(io, sock_path);
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "state/.preflight", .{}));
}

test "preflightSocketDir rejects an unwritable dir" {
    const io = std.testing.io;
    if (c.getuid() == 0) return error.SkipZigTest; // root ignores permission bits
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "state", .default_dir);
    const alloc = std.testing.allocator;
    const state_path = try tmp.dir.realPathFileAlloc(io, "state", alloc);
    defer alloc.free(state_path);
    const sock_path = try std.fs.path.join(alloc, &.{ state_path, "sock" });
    defer alloc.free(sock_path);

    const state_z = try alloc.dupeZ(u8, state_path);
    defer alloc.free(state_z);
    try std.testing.expect(c.chmod(state_z.ptr, 0o555) == 0);
    defer _ = c.chmod(state_z.ptr, 0o755);

    try std.testing.expectError(error.AccessDenied, preflightSocketDir(io, sock_path));
}
