//! `hty keys` — list the supported symbolic key names for `hty send --key`.

const std = @import("std");
const Allocator = std.mem.Allocator;

const common = @import("common.zig");

pub fn helpText() []const u8 {
    return
    \\Supported send_key names
    \\
    \\Navigation:
    \\  up, down, left, right, home, end, pageup, pagedown, insert, delete
    \\
    \\Editing and control:
    \\  enter, return, tab, esc, escape, space, backspace
    \\
    \\Function keys:
    \\  f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12
    \\
    \\Modifier prefixes (combinable, any order):
    \\  ctrl- (or c-)        Ctrl modifier
    \\  alt- (or meta-, m-)  Alt/Meta modifier
    \\  shift- (or s-)       Shift modifier
    \\
    \\Single printable characters are also accepted directly:
    \\  "i", ":", "/", "q"
    \\
    \\Examples:
    \\  ctrl-x            Ctrl+X
    \\  c-a               Ctrl+A (short form)
    \\  alt-f             Alt+F (Meta+F in emacs)
    \\  shift-tab         Backtab
    \\  shift-up          Shift+Up arrow
    \\  ctrl-alt-f        Ctrl+Alt+F
    \\  ctrl-shift-end    Ctrl+Shift+End
    \\  f5                Function key F5
    \\  alt-f3            Alt+F3
    \\
    ;
}

pub fn run(_: Allocator, _: std.Io, _: []const []const u8) !void {
    try common.printRaw(helpText());
}
