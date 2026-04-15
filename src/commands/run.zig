//! `hty run` — spawn a program inside a fresh detached PTY session.

const std = @import("std");
const Allocator = std.mem.Allocator;

const common = @import("common.zig");

pub fn helpText() []const u8 {
    return
    \\hty run [--name NAME] [--rows N] [--cols N] [--cwd PATH] [--scrollback N] -- program [args...]
    \\
    \\Create a new session and start `program` inside a fresh PTY. The session
    \\is detached from your terminal; observe it with `hty watch` and drive it
    \\with `hty send`/`hty snapshot`/`hty wait`.
    \\
    \\Flags:
    \\  --name NAME       Human-friendly alias for the session. Must be unique.
    \\  --rows N          Initial row count (default 24)
    \\  --cols N          Initial column count (default 80)
    \\  --cwd PATH        Child's working directory
    \\  --scrollback N    Scrollback buffer size (default 10000)
    \\
    \\`-d` / `--detach` is accepted as a no-op — every `hty run` session is
    \\detached by default. Use `hty attach` for an interactive view.
    \\
    \\Example:
    \\  hty run --name debug-vim -- vim /tmp/foo.txt
    \\
    ;
}

pub fn run(alloc: Allocator, args: []const []const u8) !void {
    var name: ?[]const u8 = null;
    var rows: u16 = 24;
    var cols: u16 = 80;
    var cwd: ?[]const u8 = null;
    var scrollback: usize = 10_000;
    var json_output = false;

    var i: usize = 0;
    var program_args_start: ?usize = null;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--")) {
            program_args_start = i + 1;
            break;
        } else if (std.mem.eql(u8, arg, "--name")) {
            i += 1;
            if (i >= args.len) return common.printUsageAndExit("--name requires a value");
            name = args[i];
        } else if (std.mem.eql(u8, arg, "-d") or std.mem.eql(u8, arg, "--detach")) {
            // Accepted as a no-op — every `hty run` session is detached by
            // default; use `hty attach` afterwards for an interactive
            // bidirectional view.
        } else if (std.mem.eql(u8, arg, "--rows")) {
            i += 1;
            if (i >= args.len) return common.printUsageAndExit("--rows requires a value");
            rows = try std.fmt.parseInt(u16, args[i], 10);
        } else if (std.mem.eql(u8, arg, "--cols")) {
            i += 1;
            if (i >= args.len) return common.printUsageAndExit("--cols requires a value");
            cols = try std.fmt.parseInt(u16, args[i], 10);
        } else if (std.mem.eql(u8, arg, "--cwd")) {
            i += 1;
            if (i >= args.len) return common.printUsageAndExit("--cwd requires a value");
            cwd = args[i];
        } else if (std.mem.eql(u8, arg, "--scrollback")) {
            i += 1;
            if (i >= args.len) return common.printUsageAndExit("--scrollback requires a value");
            scrollback = try std.fmt.parseInt(usize, args[i], 10);
        } else if (std.mem.eql(u8, arg, "--json")) {
            json_output = true;
        } else if (std.mem.startsWith(u8, arg, "--")) {
            try common.printErrFmt("unknown flag: {s}", .{arg});
            std.process.exit(common.ExitCode.generic);
        } else {
            // First positional = program, rest = args
            program_args_start = i;
            break;
        }
    }

    const start = program_args_start orelse return common.printUsageAndExit("missing program");
    if (start >= args.len) return common.printUsageAndExit("missing program after --");

    const program = args[start];
    const program_args = args[start + 1 ..];

    // Build spawn request as a JSON object manually so we can include name + args cleanly.
    var payload_buf = std.array_list.Managed(u8).init(alloc);
    defer payload_buf.deinit();
    var writer = payload_buf.writer();

    try writer.writeAll("{\"op\":\"spawn\",\"program\":");
    try common.writeJsonString(writer.any(), program);
    try writer.writeAll(",\"args\":[");
    for (program_args, 0..) |a, idx| {
        if (idx > 0) try writer.writeAll(",");
        try common.writeJsonString(writer.any(), a);
    }
    try writer.writeAll("]");
    if (name) |n| {
        try writer.writeAll(",\"name\":");
        try common.writeJsonString(writer.any(), n);
    }
    try writer.print(",\"rows\":{d},\"cols\":{d},\"scrollback\":{d}", .{ rows, cols, scrollback });
    if (cwd) |c_val| {
        try writer.writeAll(",\"cwd\":");
        try common.writeJsonString(writer.any(), c_val);
    }
    try writer.writeAll("}");

    const response_line = try common.sendRawRequest(alloc, payload_buf.items);
    defer alloc.free(response_line);

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, response_line, .{});
    defer parsed.deinit();
    const object = try common.expectOkOrExit(parsed);

    const sess_value = object.get("session") orelse {
        try common.printErr("server did not return a session");
        std.process.exit(common.ExitCode.generic);
    };
    const sess_obj = switch (sess_value) {
        .object => |o| o,
        else => {
            try common.printErr("invalid session payload");
            std.process.exit(common.ExitCode.generic);
        },
    };

    if (json_output) {
        // Re-emit just the `session` sub-object wrapped so the top-level
        // shape matches other --json commands: { "session": {...} }. We
        // skip the outer `ok`/`error` fields because the client already
        // consumed them via expectOkOrExit; anything else (like cwd) is
        // a server concern not a wire-contract field.
        try emitRunJson(alloc, sess_obj);
        return;
    }

    const id_val = sess_obj.get("id") orelse return;
    const id_str = switch (id_val) {
        .string => |s| s,
        else => return,
    };
    const name_val = sess_obj.get("name");
    const display_name: ?[]const u8 = if (name_val) |nv| switch (nv) {
        .string => |s| s,
        else => null,
    } else null;

    if (display_name) |dn| {
        try common.printLine(try std.fmt.allocPrint(alloc, "session \"{s}\" started ({s})", .{ dn, id_str[0..8] }));
    } else {
        try common.printLine(try std.fmt.allocPrint(alloc, "session {s} started", .{id_str[0..8]}));
    }
}

fn emitRunJson(alloc: Allocator, sess_obj: std.json.ObjectMap) !void {
    const inner = try std.json.Stringify.valueAlloc(
        alloc,
        std.json.Value{ .object = sess_obj },
        .{},
    );
    defer alloc.free(inner);

    var buf = std.array_list.Managed(u8).init(alloc);
    defer buf.deinit();
    try buf.appendSlice("{\"session\":");
    try buf.appendSlice(inner);
    try buf.appendSlice("}");
    try common.printLine(buf.items);
}
