//! `hty info` — print resolved paths and server status.

const std = @import("std");
const Allocator = std.mem.Allocator;

const common = @import("common.zig");
const paths = @import("../paths.zig");
const ensure = @import("../ensure.zig");
const protocol = @import("../protocol.zig");
const json_mod = @import("../json.zig");
const getInteger = json_mod.getInteger;
const build_info = @import("build_info");

pub fn helpText() []const u8 {
    return
    \\hty info [--json]
    \\
    \\Show resolved paths and server status. Useful for finding the socket
    \\path when setting up SSH tunnels for remote observation.
    \\
    \\Output includes:
    \\  socket    Path to the Unix domain socket
    \\  logs      Directory where session logs are stored
    \\  server    Whether the server is currently running
    \\
    \\Flags:
    \\  --json    Emit a structured JSON object instead of the text block.
    \\
    \\Environment variables that affect paths ($HTY_SOCKET, $XDG_RUNTIME_DIR,
    \\$XDG_STATE_HOME) are shown (text mode only) if set.
    \\
    ;
}

/// Git-derived build metadata. A plain struct so we can feed fake values
/// into `renderVersionLine` in unit tests without touching the real
/// `build_info` module.
pub const GitInfo = struct {
    version: []const u8,
    commit: ?[]const u8,
    tag: ?[]const u8,
    dirty: bool,
    describe: ?[]const u8,
};

fn currentGitInfo() GitInfo {
    return .{
        .version = build_info.version,
        .commit = build_info.commit,
        .tag = build_info.tag,
        .dirty = build_info.dirty,
        .describe = build_info.describe,
    };
}

fn currentBuildInfo() protocol.BuildInfo {
    return .{
        .version = build_info.version,
        .commit = build_info.commit,
        .tag = build_info.tag,
        .dirty = build_info.dirty,
        .describe = build_info.describe,
        .mode = build_info.mode,
    };
}

/// Render the single-line version string used by `hty --version`, `hty -v`,
/// and the first line of plain-text `hty info`. Two cases:
///   * git describe available: use it verbatim after `hty ` — gives us
///     `hty v0.3.1` for an exact-match tag, `hty v0.3.1-11-g30aea6bd`
///     for a dev commit, and `hty v0.3.1-dirty` / `hty v0.3.1-11-g...-dirty`
///     when the tree is dirty. Exact-match tags produce `describe == tag`.
///   * no git (source tarball): `hty <version>`, where `<version>` is
///     whatever the `-Dversion-string=` override or zon fallback produced.
/// Caller owns the returned slice.
pub fn renderVersionLine(alloc: Allocator, info: GitInfo) ![]u8 {
    if (info.describe) |d| {
        return std.fmt.allocPrint(alloc, "hty {s}", .{d});
    }
    return std.fmt.allocPrint(alloc, "hty {s}", .{info.version});
}

/// The same string `renderVersionLine` emits minus the `hty ` prefix.
/// Used as the top-level `version` field in `hty info --json` so the
/// CLI's `--version` output and the JSON always agree. Caller owns the
/// returned slice.
pub fn renderVersionString(alloc: Allocator, info: GitInfo) ![]u8 {
    if (info.describe) |d| {
        return alloc.dupe(u8, d);
    }
    return alloc.dupe(u8, info.version);
}

pub fn run(alloc: Allocator, args: []const []const u8) !void {
    var json_output = false;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--json")) {
            json_output = true;
        } else if (std.mem.startsWith(u8, arg, "--")) {
            try common.printErrFmt("unknown flag: {s}", .{arg});
            std.process.exit(common.ExitCode.generic);
        }
    }

    const socket_path = try paths.resolveSocketPath(alloc);
    defer alloc.free(socket_path);
    const log_dir = try paths.resolveLogDir(alloc);
    defer alloc.free(log_dir);
    const state_dir = try paths.resolveRuntimeDir(alloc);
    defer alloc.free(state_dir);

    // Probe the server without auto-spawning one. `info` is diagnostic —
    // we shouldn't have a side-effect of starting the server just to
    // answer the question "is it running?". If it *is* running we also
    // ask it for pid / uptime.
    const server_stats = queryServerIfLive(alloc, socket_path);
    defer if (server_stats) |s| alloc.free(s);

    if (json_output) {
        // Top-level `version` string must match what `--version` would
        // print (minus the `hty ` prefix) so the two outputs always
        // agree. Prefer `describe` when git info is available, fall back
        // to the plumbed `build_info.version`.
        const version_str = try renderVersionString(alloc, currentGitInfo());
        defer alloc.free(version_str);
        try emitJson(alloc, version_str, socket_path, state_dir, log_dir, server_stats);
        return;
    }

    const running = server_stats != null;
    const server_status: []const u8 = if (running) "running" else "not running";

    var buf: std.ArrayListUnmanaged(u8) = .{};
    defer buf.deinit(alloc);
    const w = buf.writer(alloc);

    const version_line = try renderVersionLine(alloc, currentGitInfo());
    defer alloc.free(version_line);
    try w.print("{s}\n", .{version_line});
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

/// Fast path for the top-level `hty --version` / `hty -v` flags. Prints
/// the same version line plain-text `hty info` emits and returns. Kept
/// here (rather than inlined in `headless.zig`) so there's a single
/// source of truth for the version-line format.
pub fn printVersionLine(alloc: Allocator) !void {
    const line = try renderVersionLine(alloc, currentGitInfo());
    defer alloc.free(line);
    try common.printLine(line);
}

/// Ask the running server for its pid and uptime. Returns null if the
/// server isn't reachable — `info` never auto-spawns one. Returned slice
/// owned by the caller and contains the raw JSON response line.
fn queryServerIfLive(alloc: Allocator, socket_path: []const u8) ?[]u8 {
    var stream = ensure.tryConnect(socket_path) catch return null;
    defer stream.close();

    stream.writeAll("{\"op\":\"info\"}\n") catch return null;

    var buf = std.array_list.Managed(u8).init(alloc);
    defer buf.deinit();

    var chunk: [4096]u8 = undefined;
    while (true) {
        const n = stream.read(&chunk) catch return null;
        if (n == 0) break;
        buf.appendSlice(chunk[0..n]) catch return null;
        if (std.mem.indexOfScalar(u8, buf.items, '\n') != null) break;
    }

    const nl = std.mem.indexOfScalar(u8, buf.items, '\n') orelse buf.items.len;
    return alloc.dupe(u8, buf.items[0..nl]) catch null;
}

/// Parse the server's `info` response and emit a single JSON object
/// combining local config with (optional) server stats.
fn emitJson(
    alloc: Allocator,
    version: []const u8,
    socket_path: []const u8,
    state_dir: []const u8,
    log_dir: []const u8,
    server_line: ?[]u8,
) !void {
    const payload = try buildInfoPayload(alloc, version, socket_path, state_dir, log_dir, server_line);
    try common.printJsonLine(payload);
}

/// Pure builder: combine local config + (optional) server response line
/// into an `InfoPayload`. Extracted so unit tests can exercise both
/// server-up and server-down paths without driving sockets.
pub fn buildInfoPayload(
    alloc: Allocator,
    version: []const u8,
    socket_path: []const u8,
    state_dir: []const u8,
    log_dir: []const u8,
    server_line: ?[]const u8,
) !protocol.InfoPayload {
    var server_pid: ?i64 = null;
    var server_uptime_ms: ?i64 = null;
    var server_running = false;

    if (server_line) |line| {
        var parsed = std.json.parseFromSlice(std.json.Value, alloc, line, .{}) catch null;
        if (parsed) |*p| {
            defer p.deinit();
            if (p.value == .object) {
                const obj = p.value.object;
                // Server line is considered "the server answered" only if
                // the response envelope parses and is ok — otherwise we
                // treat it as if the server never answered.
                if (obj.get("ok")) |ok_val| {
                    if (ok_val == .bool and ok_val.bool) server_running = true;
                }
                if (obj.get("info")) |info_val| {
                    if (info_val == .object) {
                        const info_obj = info_val.object;
                        if (info_obj.get("server")) |sv| {
                            if (sv == .object) {
                                const srv = sv.object;
                                server_pid = getInteger(srv, "pid");
                                server_uptime_ms = getInteger(srv, "uptime_ms");
                            }
                        }
                    }
                }
            }
        }
    }

    return .{
        .version = version,
        .socket_path = socket_path,
        .state_dir = state_dir,
        .log_dir = log_dir,
        .server = .{
            .running = server_running,
            .pid = server_pid,
            .uptime_ms = server_uptime_ms,
        },
        .build = currentBuildInfo(),
    };
}

test "renderVersionLine: tagged clean uses describe verbatim" {
    const alloc = std.testing.allocator;
    const line = try renderVersionLine(alloc, .{
        .version = "0.4.0",
        .commit = "7a8b9c0",
        .tag = "v0.4.0",
        .dirty = false,
        .describe = "v0.4.0",
    });
    defer alloc.free(line);
    try std.testing.expectEqualStrings("hty v0.4.0", line);
}

test "renderVersionLine: dev dirty build uses describe" {
    const alloc = std.testing.allocator;
    const line = try renderVersionLine(alloc, .{
        .version = "0.4.0",
        .commit = "7a8b9c0",
        .tag = null,
        .dirty = true,
        .describe = "v0.4.0-3-g7a8b9c0-dirty",
    });
    defer alloc.free(line);
    try std.testing.expectEqualStrings("hty v0.4.0-3-g7a8b9c0-dirty", line);
}

test "renderVersionLine: no git info falls back to plain version field" {
    const alloc = std.testing.allocator;
    const line = try renderVersionLine(alloc, .{
        .version = "0.4.0",
        .commit = null,
        .tag = null,
        .dirty = false,
        .describe = null,
    });
    defer alloc.free(line);
    try std.testing.expectEqualStrings("hty 0.4.0", line);
}
