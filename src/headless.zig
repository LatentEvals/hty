//! `hty` entry point. Everything is in dedicated modules — this file is
//! just argv dispatch and the test-discovery shim Zig's test runner needs
//! to walk into the extracted files.

const std = @import("std");

const runServer = @import("server.zig").runServer;
const ExitCode = @import("commands/common.zig").ExitCode;

const commands = struct {
    const common_mod = @import("commands/common.zig");
    const help_mod = @import("commands/help.zig");
    const run_mod = @import("commands/run.zig");
    const list_mod = @import("commands/list.zig");
    const kill_mod = @import("commands/kill.zig");
    const delete_mod = @import("commands/delete.zig");
    const send_mod = @import("commands/send.zig");
    const snapshot_mod = @import("commands/snapshot.zig");
    const wait_mod = @import("commands/wait.zig");
    const watch_mod = @import("commands/watch.zig");
    const attach_mod = @import("commands/attach.zig");
    const replay_mod = @import("commands/replay.zig");
    const logs_mod = @import("commands/logs.zig");
    const export_mod = @import("commands/export.zig");
    const keys_mod = @import("commands/keys.zig");
    const info_mod = @import("commands/info.zig");
};

// Force Zig's test discovery to walk the extracted modules even when this
// root file only references `runServer` and the command `run()` fns.
comptime {
    _ = @import("ensure.zig");
    _ = @import("keys.zig");
    _ = @import("uuid.zig");
    _ = @import("ops.zig");
    _ = @import("server_attach.zig");
    _ = @import("tests.zig");
    _ = @import("commands/help.zig");
    _ = @import("commands/kill.zig");
    _ = @import("commands/send.zig");
    _ = @import("commands/logs.zig");
    _ = @import("commands/replay.zig");
    _ = @import("commands/asciicast.zig");
    _ = @import("commands/export.zig");
}

/// Suppress std.log output below error level across the whole binary.
/// The Ghostty VT parser emits warn-level messages when it hits escape
/// sequences it doesn't implement (e.g. the non-standard "CSI m with
/// intermediate: 63" vim occasionally sends). Those go to stderr, and
/// for the replay / watch / attach clients stderr is the user's
/// terminal — the warnings land right on top of the rendered frame.
/// The server redirects stdio to /dev/null so raising the level there
/// costs nothing; raising it for the clients fixes the visual glitch.
pub const std_options: std.Options = .{
    .log_level = .err,
};

fn writeUsageError(arg: []const u8) !void {
    const alloc = std.heap.c_allocator;
    const message = try std.fmt.allocPrint(alloc, "unknown subcommand: {s}\n\n{s}", .{ arg, commands.help_mod.generalHelpText() });
    defer alloc.free(message);
    var stderr = std.fs.File.stderr();
    _ = try stderr.writeAll(message);
}

pub fn main() !void {
    const alloc = std.heap.c_allocator;
    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);

    if (args.len < 2) {
        try commands.common_mod.printRaw(commands.help_mod.generalHelpText());
        return;
    }

    const verb = args[1];

    // Top-level `--version` / `-v` prints the same concise version line the
    // `info` command emits and exits 0. Handled here (not routed into
    // `info.zig`) so there's no socket probe or path resolution on the fast
    // path — useful when packagers call `hty --version` from constrained
    // environments.
    if (std.mem.eql(u8, verb, "--version") or std.mem.eql(u8, verb, "-v")) {
        try commands.info_mod.printVersionLine(alloc);
        return;
    }

    // Hidden server entry point.
    if (std.mem.eql(u8, verb, "__server__")) {
        if (args.len < 3) {
            try commands.common_mod.printErr("__server__ requires a socket path");
            std.process.exit(ExitCode.generic);
        }
        try runServer(alloc, args[2]);
        return;
    }

    const subargs = args[2..];
    if (std.mem.eql(u8, verb, "--help") or std.mem.eql(u8, verb, "-h") or std.mem.eql(u8, verb, "help")) {
        try commands.help_mod.run(alloc, subargs);
        return;
    }
    if (std.mem.eql(u8, verb, "keys")) return commands.keys_mod.run(alloc, subargs);
    if (std.mem.eql(u8, verb, "info")) return commands.info_mod.run(alloc, subargs);
    if (std.mem.eql(u8, verb, "run")) return commands.run_mod.run(alloc, subargs);
    if (std.mem.eql(u8, verb, "list")) return commands.list_mod.run(alloc, subargs);
    if (std.mem.eql(u8, verb, "watch")) return commands.watch_mod.run(alloc, subargs);
    if (std.mem.eql(u8, verb, "send")) return commands.send_mod.run(alloc, subargs);
    if (std.mem.eql(u8, verb, "snapshot")) return commands.snapshot_mod.run(alloc, subargs);
    if (std.mem.eql(u8, verb, "wait")) return commands.wait_mod.run(alloc, subargs);
    if (std.mem.eql(u8, verb, "kill")) return commands.kill_mod.run(alloc, subargs);
    if (std.mem.eql(u8, verb, "delete")) return commands.delete_mod.run(alloc, subargs);
    if (std.mem.eql(u8, verb, "logs")) return commands.logs_mod.run(alloc, subargs);
    if (std.mem.eql(u8, verb, "export")) return commands.export_mod.run(alloc, subargs);
    if (std.mem.eql(u8, verb, "replay")) return commands.replay_mod.run(alloc, subargs);
    if (std.mem.eql(u8, verb, "attach")) return commands.attach_mod.run(alloc, subargs);

    try writeUsageError(verb);
    std.process.exit(ExitCode.generic);
}
