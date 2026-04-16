//! `hty run` — spawn a program inside a fresh detached PTY session.

const std = @import("std");
const Allocator = std.mem.Allocator;

const common = @import("common.zig");
const send_cmd = @import("send.zig");

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
    \\Wait + snapshot flags (let `run` block until the program is ready and
    \\return the initial render in one round-trip):
    \\  --snapshot                Include the post-spawn snapshot in the response.
    \\                            Requires one of --wait-until-* or --wait-duration.
    \\  --wait-duration DUR       Sleep DUR after spawn, then snapshot.
    \\  --wait-until-idle [MS]    Block until the screen has been quiet for MS
    \\                            milliseconds (default 100).
    \\  --wait-until-text STR     Block until STR appears in the rendered buffer.
    \\  --wait-until-regex RE     Block until RE (POSIX extended) matches.
    \\  --wait-until-exit         Block until the child process exits.
    \\  --timeout DUR             Cap on any --wait-until-* (default 30s; 0 = none).
    \\  --ansi                    With --snapshot, print styled ANSI rendering.
    \\
    \\`-d` / `--detach` is accepted as a no-op — every `hty run` session is
    \\detached by default. Use `hty attach` for an interactive view.
    \\
    \\Example:
    \\  hty run --name debug-vim -- vim /tmp/foo.txt
    \\  hty run --name app --snapshot --wait-until-idle -- create-next-app my-app
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

    var snapshot_flag = false;
    var ansi_output = false;
    var wait_duration_str: ?[]const u8 = null;
    var wait_until_idle = false;
    var wait_until_idle_ms_str: ?[]const u8 = null;
    var wait_until_text: ?[]const u8 = null;
    var wait_until_regex: ?[]const u8 = null;
    var wait_until_exit = false;
    var timeout_str: ?[]const u8 = null;

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
        } else if (std.mem.eql(u8, arg, "--snapshot")) {
            snapshot_flag = true;
        } else if (std.mem.eql(u8, arg, "--ansi")) {
            ansi_output = true;
        } else if (std.mem.eql(u8, arg, "--wait-duration")) {
            i += 1;
            if (i >= args.len) return common.printUsageAndExit("--wait-duration requires a value");
            wait_duration_str = args[i];
        } else if (std.mem.eql(u8, arg, "--wait-until-idle")) {
            wait_until_idle = true;
            if (i + 1 < args.len) {
                const peek = args[i + 1];
                if (peek.len > 0 and peek[0] >= '0' and peek[0] <= '9') {
                    i += 1;
                    wait_until_idle_ms_str = peek;
                }
            }
        } else if (std.mem.eql(u8, arg, "--wait-until-text")) {
            i += 1;
            if (i >= args.len) return common.printUsageAndExit("--wait-until-text requires a value");
            wait_until_text = args[i];
        } else if (std.mem.eql(u8, arg, "--wait-until-regex")) {
            i += 1;
            if (i >= args.len) return common.printUsageAndExit("--wait-until-regex requires a value");
            wait_until_regex = args[i];
        } else if (std.mem.eql(u8, arg, "--wait-until-exit")) {
            wait_until_exit = true;
        } else if (std.mem.eql(u8, arg, "--timeout")) {
            i += 1;
            if (i >= args.len) return common.printUsageAndExit("--timeout requires a value");
            timeout_str = args[i];
        } else if (std.mem.startsWith(u8, arg, "--")) {
            try common.printErrFmt("unknown flag: {s}", .{arg});
            std.process.exit(common.ExitCode.generic);
        } else {
            // First positional = program, rest = args
            program_args_start = i;
            break;
        }
    }

    // Validate the wait/snapshot combinations before doing any I/O.
    var wait_kind_count: u8 = 0;
    if (wait_until_idle) wait_kind_count += 1;
    if (wait_until_text != null) wait_kind_count += 1;
    if (wait_until_regex != null) wait_kind_count += 1;
    if (wait_until_exit) wait_kind_count += 1;
    if (wait_kind_count > 1) {
        try common.printErr("at most one of --wait-until-idle, --wait-until-text, --wait-until-regex, --wait-until-exit may be supplied");
        std.process.exit(common.ExitCode.generic);
    }
    if (wait_duration_str != null and wait_kind_count > 0) {
        try common.printErr("--wait-duration is incompatible with --wait-until-*");
        std.process.exit(common.ExitCode.generic);
    }
    if (wait_duration_str != null and !snapshot_flag) {
        try common.printErr("--wait-duration without --snapshot is just a delay; add --snapshot");
        std.process.exit(common.ExitCode.generic);
    }
    // Spec: `run --snapshot` with no wait flags is almost always wrong (the
    // snapshot would fire before the spawned program had a chance to paint
    // anything). Surface the helpful error rather than silently racing.
    if (snapshot_flag and wait_kind_count == 0 and wait_duration_str == null) {
        try common.printErr("--snapshot on `hty run` almost always wants --wait-until-idle or --wait-duration");
        std.process.exit(common.ExitCode.generic);
    }
    if (ansi_output and !snapshot_flag) {
        try common.printErr("--ansi requires --snapshot");
        std.process.exit(common.ExitCode.generic);
    }
    if (json_output and ansi_output) {
        try common.printErr("--json and --ansi are mutually exclusive");
        std.process.exit(common.ExitCode.generic);
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

    const id_val = sess_obj.get("id");
    const id_str: ?[]const u8 = if (id_val) |iv| switch (iv) {
        .string => |s| s,
        else => null,
    } else null;
    const name_val = sess_obj.get("name");
    const display_name: ?[]const u8 = if (name_val) |nv| switch (nv) {
        .string => |s| s,
        else => null,
    } else null;

    // Fused wait + snapshot: only triggered when one of --wait-until-* or
    // --wait-duration is set. The earlier validation rejected --snapshot
    // alone (without a wait flag) on `run`, so any fused path here is
    // accompanied by a wait condition.
    const fused = wait_kind_count > 0 or wait_duration_str != null;
    if (fused) {
        const wait_kind: []const u8 = if (wait_until_idle)
            "idle"
        else if (wait_until_text != null)
            "text"
        else if (wait_until_regex != null)
            "regex"
        else if (wait_until_exit)
            "exit"
        else if (wait_duration_str != null)
            "duration"
        else
            unreachable;

        const timeout_ms: u64 = if (timeout_str) |t| common.parseDurationMs(t) catch {
            try common.printErr("invalid --timeout value");
            std.process.exit(common.ExitCode.generic);
            unreachable;
        } else 30_000;

        const idle_ms: u64 = if (wait_until_idle_ms_str) |s| send_cmd.parseIdleArg(s) catch {
            try common.printErr("invalid --wait-until-idle value");
            std.process.exit(common.ExitCode.generic);
            unreachable;
        } else 100;

        const duration_ms: u64 = if (wait_duration_str) |d| common.parseDurationMs(d) catch {
            try common.printErr("invalid --wait-duration value");
            std.process.exit(common.ExitCode.generic);
            unreachable;
        } else 0;

        const needle: ?[]const u8 = wait_until_text orelse wait_until_regex;

        // Pin the wait_and_snapshot to the freshly-spawned session by id —
        // safer than relying on sole-session resolution if other tests /
        // commands are racing in the background.
        var wait_parsed = try send_cmd.sendFusedWait(alloc, .{
            .session_ref = id_str,
            .wait_kind = wait_kind,
            .needle = needle,
            .idle_ms = idle_ms,
            .duration_ms = duration_ms,
            .timeout_ms = timeout_ms,
            .snapshot = snapshot_flag,
        });
        defer wait_parsed.deinit();
        const wait_object = try common.expectOkOrExit(wait_parsed);

        const timed_out = send_cmd.readTimedOut(wait_object);

        if (json_output) {
            const sess_json = try std.json.Stringify.valueAlloc(
                alloc,
                std.json.Value{ .object = sess_obj },
                .{},
            );
            defer alloc.free(sess_json);
            try send_cmd.emitFusedJson(alloc, wait_object, snapshot_flag, sess_json);
            if (timed_out) std.process.exit(common.ExitCode.wait_timeout);
            return;
        }

        if (snapshot_flag) {
            try send_cmd.printSnapshotBody(wait_object, ansi_output);
        } else {
            try printStartedLine(alloc, display_name, id_str);
        }

        if (timed_out) {
            try common.printErr("timed out");
            std.process.exit(common.ExitCode.wait_timeout);
        }
        return;
    }

    if (json_output) {
        // Re-emit just the `session` sub-object wrapped so the top-level
        // shape matches other --json commands: { "session": {...} }. We
        // skip the outer `ok`/`error` fields because the client already
        // consumed them via expectOkOrExit; anything else (like cwd) is
        // a server concern not a wire-contract field.
        try emitRunJson(alloc, sess_obj);
        return;
    }

    try printStartedLine(alloc, display_name, id_str);
}

fn printStartedLine(alloc: Allocator, display_name: ?[]const u8, id_str: ?[]const u8) !void {
    const id = id_str orelse return;
    if (display_name) |dn| {
        try common.printLine(try std.fmt.allocPrint(alloc, "session \"{s}\" started ({s})", .{ dn, id[0..8] }));
    } else {
        try common.printLine(try std.fmt.allocPrint(alloc, "session {s} started", .{id[0..8]}));
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
