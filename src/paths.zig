//! XDG-style directory resolution for the hty runtime.
//!
//! Socket lives under `$XDG_RUNTIME_DIR/hty/` (or the `$HTY_SOCKET` override);
//! logs live under `$XDG_STATE_HOME/hty/logs`. macOS has no `$XDG_RUNTIME_DIR`
//! by default, so we fall back to `$XDG_STATE_HOME/hty/` and finally to
//! `~/.local/state/hty/`. `ensureOwnedDir` recursively creates parents and
//! rejects the path if it was created by another uid (symlink-attack defense).

const std = @import("std");
const sys = @import("hty").sys;
const Allocator = std.mem.Allocator;

const c = @cImport({
    @cInclude("sys/stat.h");
    @cInclude("unistd.h");
});

pub fn resolveSocketPath(alloc: Allocator) ![]u8 {
    // Explicit override wins — used for SSH-tunneled sockets, tests, or any
    // other time you want the client to talk to a non-default socket.
    // Does NOT ensureOwnedDir, because the override path may live in a
    // directory the caller doesn't own (e.g. a tunnel endpoint).
    if (sys.getenv("HTY_SOCKET")) |override| {
        if (override.len > 0) return alloc.dupe(u8, override);
    }

    const dir = try resolveRuntimeDir(alloc);
    defer alloc.free(dir);
    try ensureOwnedDir(alloc, dir);
    return std.fmt.allocPrint(alloc, "{s}/sock", .{dir});
}

pub fn resolveRuntimeDir(alloc: Allocator) ![]u8 {
    if (sys.getenv("XDG_RUNTIME_DIR")) |runtime| {
        if (runtime.len > 0) {
            return std.fmt.allocPrint(alloc, "{s}/hty", .{runtime});
        }
    }
    // No XDG_RUNTIME_DIR (typical on macOS). Fall back to ~/.local/state/hty
    // alongside the log directory — keeps everything in one place and avoids
    // world-listable /tmp.
    if (sys.getenv("XDG_STATE_HOME")) |state| {
        if (state.len > 0) {
            return std.fmt.allocPrint(alloc, "{s}/hty", .{state});
        }
    }
    const home = sys.getenv("HOME") orelse return error.HomeNotSet;
    return std.fmt.allocPrint(alloc, "{s}/.local/state/hty", .{home});
}

pub fn resolveLogDir(alloc: Allocator) ![]u8 {
    if (sys.getenv("XDG_STATE_HOME")) |state| {
        if (state.len > 0) {
            const dir = try std.fmt.allocPrint(alloc, "{s}/hty/logs", .{state});
            errdefer alloc.free(dir);
            try ensureOwnedDir(alloc, dir);
            return dir;
        }
    }
    const home = sys.getenv("HOME") orelse return error.HomeNotSet;
    const dir = try std.fmt.allocPrint(alloc, "{s}/.local/state/hty/logs", .{home});
    errdefer alloc.free(dir);
    try ensureOwnedDir(alloc, dir);
    return dir;
}

/// Ensure `path` exists as a directory owned by the current user with mode 0700.
/// Recursively creates missing parents. Bails out if the resulting directory is
/// owned by a different uid (symlink-attack defense).
pub fn ensureOwnedDir(alloc: Allocator, path: []const u8) !void {
    try mkdirAll(path);

    const path_z = try alloc.dupeZ(u8, path);
    defer alloc.free(path_z);

    var st: c.struct_stat = undefined;
    if (c.stat(path_z.ptr, &st) != 0) return error.CannotStatDir;
    const uid = c.getuid();
    if (st.st_uid != uid) return error.DirectoryStolen;
    _ = c.chmod(path_z.ptr, 0o700);
}

/// Recursively create `path` and any missing parents (mode 0755, like the
/// pre-0.16 std.fs.Dir.makePath default; ensureOwnedDir tightens the leaf
/// to 0700 afterwards).
fn mkdirAll(path: []const u8) !void {
    sys.mkdir(path, 0o755) catch |err| switch (err) {
        error.PathAlreadyExists => return,
        error.FileNotFound => {
            const parent = std.fs.path.dirname(path) orelse return err;
            try mkdirAll(parent);
            sys.mkdir(path, 0o755) catch |err2| switch (err2) {
                error.PathAlreadyExists => return,
                else => return err2,
            };
        },
        else => return err,
    };
}
