//! All `hty <subcommand> --help` text lives here. Pure string constants with
//! a small topic dispatcher (`helpForTopic`) so the CLI entry point can route
//! `hty help <topic>` to the right block.
//!
//! Kept as one module (rather than co-located per-command) because help text
//! is cross-referential: `generalHelpText` lists every subcommand, and
//! changes often touch several help strings at once. Centralizing them makes
//! the table easier to keep in sync.

const std = @import("std");

pub fn helpForTopic(topic: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, topic, "run")) return @import("commands/run.zig").helpText();
    if (std.mem.eql(u8, topic, "list")) return @import("commands/list.zig").helpText();
    if (std.mem.eql(u8, topic, "watch")) return @import("commands/watch.zig").helpText();
    if (std.mem.eql(u8, topic, "send")) return @import("commands/send.zig").helpText();
    if (std.mem.eql(u8, topic, "snapshot")) return @import("commands/snapshot.zig").helpText();
    if (std.mem.eql(u8, topic, "wait")) return @import("commands/wait.zig").helpText();
    if (std.mem.eql(u8, topic, "kill")) return @import("commands/kill.zig").helpText();
    if (std.mem.eql(u8, topic, "delete")) return deleteHelpText();
    if (std.mem.eql(u8, topic, "logs")) return logsHelpText();
    if (std.mem.eql(u8, topic, "replay")) return replayHelpText();
    if (std.mem.eql(u8, topic, "attach")) return attachHelpText();
    if (std.mem.eql(u8, topic, "keys")) return @import("commands/keys.zig").helpText();
    if (std.mem.eql(u8, topic, "info")) return @import("commands/info.zig").helpText();
    return null;
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
    \\  replay    Replay a recorded session by feeding its logged output back
    \\            through a fresh in-memory VT engine. No side effects.
    \\  attach    Interactively attach to a running session (bidirectional)
    \\  keys      Print supported symbolic key names for `hty send --key`
    \\  info      Show resolved paths and server status
    \\  help      Print help. Pass a subcommand for details.
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

pub fn deleteHelpText() []const u8 {
    return
    \\hty delete [SESSION]
    \\
    \\Permanently remove a session. If the child process is still running
    \\it's terminated first; the session's log file and by-name symlink
    \\are then unlinked from disk. After delete, the session's name is
    \\free to reuse.
    \\
    \\If SESSION is omitted and exactly one session is live, that one
    \\is deleted.
    \\
    ;
}

pub fn attachHelpText() []const u8 {
    return
    \\hty attach [SESSION]
    \\
    \\Interactively attach to a running session. Your terminal's keystrokes
    \\are forwarded into the PTY and the session's rendered output streams
    \\back — the same session an agent is driving can be taken over by a
    \\human (or multiple humans) at any time.
    \\
    \\Detach keybinds (tmux-style, Ctrl-A is the prefix):
    \\  Ctrl-A d      Detach cleanly.
    \\  Ctrl-A Ctrl-A Send a literal Ctrl-A to the session.
    \\
    \\The observer's terminal size is sent on attach and on SIGWINCH, so
    \\the child program sees the right LINES/COLUMNS.
    \\
    \\Multiple clients can attach to the same session simultaneously —
    \\writes are atomic per input frame, reads are broadcast to everyone.
    \\
    ;
}

pub fn replayHelpText() []const u8 {
    return
    \\hty replay [SESSION] [--speed Nx] [--at T] [--to T] [--loop]
    \\
    \\Replay a session by reading its log file and feeding the recorded
    \\output bytes back through a fresh in-memory VT engine. The program
    \\is NOT re-executed and no input is re-sent — replay is a pure
    \\visualization with zero side effects.
    \\
    \\Flags:
    \\  --speed Nx   Playback speed multiplier (default 1x). 0 = no sleep.
    \\  --at T       Fast-forward silently to T into the session before
    \\               painting (same duration syntax as --since).
    \\  --to T       Stop painting once the timeline reaches T.
    \\  --loop       Restart playback from the beginning when the log ends.
    \\
    \\Press Ctrl-C or Ctrl-Q to exit.
    \\
    ;
}

pub fn logsHelpText() []const u8 {
    return
    \\hty logs [SESSION] [--follow|-f] [--since DURATION] [--json]
    \\
    \\Print the JSONL event log for a session. Logs are read directly from
    \\disk, so this works for sessions that have already exited and even
    \\across server restarts.
    \\
    \\SESSION may be a --name, a full UUID, or any unambiguous prefix. If
    \\omitted and exactly one log file exists, that one is used.
    \\
    \\Flags:
    \\  --follow, -f     Tail the log as new events arrive.
    \\  --since DURATION Only show events within the last DURATION of logged
    \\                   activity. Accepts: 500ms, 5s, 1m, 2h, or a bare
    \\                   integer (seconds).
    \\  --json           Emit raw JSONL lines (one per event) instead of the
    \\                   human-readable table.
    \\
    \\Logs live at \$XDG_STATE_HOME/hty/logs (fallback ~/.local/state/hty/logs).
    \\
    ;
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
