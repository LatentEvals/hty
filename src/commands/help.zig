//! `hty help` — print the overview or a single subcommand's help text.
//!
//! This module also owns `generalHelpText` and `helpForTopic`. Putting them
//! here (rather than in a separate `help_text.zig`) means each subcommand's
//! help string lives with its own implementation, and only the overview +
//! dispatcher remain centralized.

const std = @import("std");
const Allocator = std.mem.Allocator;

const common = @import("common.zig");

pub fn helpText() []const u8 {
    return generalHelpText();
}

pub fn generalHelpText() []const u8 {
    return
    \\Usage:
    \\  hty <command> [args...]
    \\
    \\Commands:
    \\  run       Start a new detached session in a fresh PTY
    \\  list      List running sessions
    \\  watch     Observe a session's rendered screen in real time (read-only)
    \\  send      Send text, a named key, or raw hex bytes to a session
    \\  snapshot  Read the current rendered screen of a session
    \\  wait      Block until the session matches a condition (text/idle/exit)
    \\  kill      Terminate a session's process (the record stays for replay)
    \\  delete    Permanently remove a session record and its log file
    \\  logs      Show the event log for a session (works after it has exited)
    \\  export    Convert a recorded session log into a share-ready artifact
    \\            (currently asciinema v2 .cast)
    \\  replay    Replay a recorded session by feeding its logged output back
    \\            through a fresh in-memory VT engine. No side effects.
    \\  attach    Interactively attach to a running session (bidirectional)
    \\  keys      Print supported symbolic key names for `hty send --key`
    \\  info      Show resolved paths and server status
    \\  help      Print help. Pass a subcommand for details.
    \\
    \\Global flags:
    \\  --version, -v   Print the hty version and exit.
    \\  --help, -h      Print this help text. `hty help <command>` for details.
    \\
    \\Sessions are identified by a UUIDv7 (shown as its first 8 chars) or by a
    \\human-friendly `--name`. Any unambiguous prefix resolves to a full ID.
    \\If only one session is running, the session argument can be omitted.
    \\
    \\Examples:
    \\  hty run --name debug-vim -- vim /tmp/foo.txt
    \\  hty list
    \\  hty watch debug-vim
    \\  hty send debug-vim --text "ihello"
    \\  hty send debug-vim --key esc
    \\  hty wait debug-vim --idle 300 --timeout 2000
    \\  hty kill debug-vim
    \\
    ;
}

pub fn helpForTopic(topic: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, topic, "run")) return @import("run.zig").helpText();
    if (std.mem.eql(u8, topic, "list")) return @import("list.zig").helpText();
    if (std.mem.eql(u8, topic, "watch")) return @import("watch.zig").helpText();
    if (std.mem.eql(u8, topic, "send")) return @import("send.zig").helpText();
    if (std.mem.eql(u8, topic, "snapshot")) return @import("snapshot.zig").helpText();
    if (std.mem.eql(u8, topic, "wait")) return @import("wait.zig").helpText();
    if (std.mem.eql(u8, topic, "kill")) return @import("kill.zig").helpText();
    if (std.mem.eql(u8, topic, "delete")) return @import("delete.zig").helpText();
    if (std.mem.eql(u8, topic, "logs")) return @import("logs.zig").helpText();
    if (std.mem.eql(u8, topic, "export")) return @import("export.zig").helpText();
    if (std.mem.eql(u8, topic, "replay")) return @import("replay.zig").helpText();
    if (std.mem.eql(u8, topic, "attach")) return @import("attach.zig").helpText();
    if (std.mem.eql(u8, topic, "keys")) return @import("keys.zig").helpText();
    if (std.mem.eql(u8, topic, "info")) return @import("info.zig").helpText();
    return null;
}

pub fn run(alloc: Allocator, _: std.Io, args: []const []const u8) !void {
    if (args.len == 0) {
        try common.printRaw(generalHelpText());
        return;
    }

    if (helpForTopic(args[0])) |help| {
        try common.printRaw(help);
        return;
    }

    const message = try std.fmt.allocPrint(alloc, "unknown help topic: {s}\n\n{s}", .{ args[0], generalHelpText() });
    defer alloc.free(message);
    try common.printRaw(message);
}

test "help text lists all subcommands" {
    const general = generalHelpText();
    try std.testing.expect(std.mem.indexOf(u8, general, "run") != null);
    try std.testing.expect(std.mem.indexOf(u8, general, "list") != null);
    try std.testing.expect(std.mem.indexOf(u8, general, "watch") != null);
    try std.testing.expect(std.mem.indexOf(u8, general, "send") != null);
    try std.testing.expect(std.mem.indexOf(u8, general, "snapshot") != null);
    try std.testing.expect(std.mem.indexOf(u8, general, "wait") != null);
    try std.testing.expect(std.mem.indexOf(u8, general, "kill") != null);
    try std.testing.expect(std.mem.indexOf(u8, general, "logs") != null);
    try std.testing.expect(std.mem.indexOf(u8, general, "replay") != null);
    try std.testing.expect(std.mem.indexOf(u8, general, "attach") != null);
}

test "help text mentions global --version and --help flags" {
    const general = generalHelpText();
    try std.testing.expect(std.mem.indexOf(u8, general, "--version") != null);
    try std.testing.expect(std.mem.indexOf(u8, general, "-v") != null);
    try std.testing.expect(std.mem.indexOf(u8, general, "--help") != null);
}
