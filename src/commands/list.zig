//! `hty list` — show currently running sessions, merged with any orphan
//! log files on disk.

const std = @import("std");
const Allocator = std.mem.Allocator;

const common = @import("common.zig");
const paths = @import("../paths.zig");
const ensure = @import("../ensure.zig");
const protocol = @import("../protocol.zig");
const json_mod = @import("../json.zig");
const getString = json_mod.getString;
const getInteger = json_mod.getInteger;
const readStringArray = json_mod.readStringArray;
const shortestUniquePrefixLen = @import("../uuid.zig").shortestUniquePrefixLen;
const Response = protocol.Response;
const SessionSummary = protocol.SessionSummary;

pub fn helpText() []const u8 {
    return
    \\hty list [--json]
    \\
    \\List currently running sessions. Empty output if none.
    \\
    \\Flags:
    \\  --json   Emit the full structured response as JSON.
    \\
    ;
}

const SessionEntry = struct {
    id: []const u8,
    name: ?[]const u8,
    program: []const u8,
    args: []const u8,
    status: []const u8,
    created_at_ms: i64,
};

pub const MergedSessions = struct {
    arena_state: std.heap.ArenaAllocator,
    entries: std.ArrayListUnmanaged(SessionEntry) = .{},

    pub fn deinit(self: *MergedSessions) void {
        self.entries.deinit(self.arena_state.allocator());
        self.arena_state.deinit();
        self.* = undefined;
    }

    pub fn arena(self: *MergedSessions) Allocator {
        return self.arena_state.allocator();
    }
};

pub fn run(alloc: Allocator, args: []const []const u8) !void {
    var json_output = false;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--json")) json_output = true;
    }

    // Pull live sessions from the server first — using tryConnect so we
    // DON'T auto-spawn a server just to answer "hty list". If the server
    // isn't running, fall through to the disk scan, which covers any
    // historical records that outlive the server.
    const server_line = querySeverListIfLive(alloc) catch null;
    defer if (server_line) |line| alloc.free(line);

    const log_dir = resolveLogDirForClient(alloc) catch null;
    defer if (log_dir) |dir| alloc.free(dir);

    var merged = try collectMergedSessions(alloc, log_dir, server_line);
    defer merged.deinit();

    // Sort by created_at_ms descending so newest sessions show first in both
    // table and JSON output.
    std.mem.sort(SessionEntry, merged.entries.items, {}, struct {
        fn lt(_: void, a: SessionEntry, b: SessionEntry) bool {
            return a.created_at_ms > b.created_at_ms;
        }
    }.lt);

    if (json_output) {
        const response = try buildJsonResponse(merged.arena(), merged.entries.items);
        try common.printJsonLine(response);
        return;
    }

    if (merged.entries.items.len == 0) {
        try common.printErr("no sessions");
        return;
    }

    const arena = merged.arena();
    const ids = try arena.alloc([]const u8, merged.entries.items.len);
    for (merged.entries.items, 0..) |e, idx| ids[idx] = e.id;
    const id_len = shortestUniquePrefixLen(ids, 8);

    const header = try std.fmt.allocPrint(alloc, "{s: <[w]}  NAME             PROGRAM          STATUS     STARTED", .{ .s = "ID", .w = id_len });
    defer alloc.free(header);
    try common.printLine(header);

    for (merged.entries.items) |e| {
        const now = std.time.milliTimestamp();
        const age_ms = now - e.created_at_ms;
        const age_str = try formatAge(alloc, age_ms);
        defer alloc.free(age_str);

        const short_id = if (e.id.len >= id_len) e.id[0..id_len] else e.id;
        const name = e.name orelse "";
        const short_name = if (name.len > 16) name[0..16] else name;
        const short_program = if (e.program.len > 16) e.program[0..16] else e.program;

        const line = try std.fmt.allocPrint(alloc, "{s}  {s: <16} {s: <16} {s: <10} {s}", .{
            short_id,
            short_name,
            short_program,
            e.status,
            age_str,
        });
        defer alloc.free(line);
        try common.printLine(line);
    }
}

pub fn collectMergedSessions(
    alloc: Allocator,
    log_dir: ?[]const u8,
    server_line: ?[]const u8,
) !MergedSessions {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    errdefer arena_state.deinit();
    const arena = arena_state.allocator();

    var entries: std.ArrayListUnmanaged(SessionEntry) = .{};
    var seen_ids = std.StringHashMap(void).init(arena);
    defer seen_ids.deinit();

    if (server_line) |line| {
        try appendServerSessions(arena, &entries, &seen_ids, line);
    }

    try scanDiskSessions(arena, log_dir, &entries, &seen_ids);

    return .{
        .arena_state = arena_state,
        .entries = entries,
    };
}

pub fn buildJsonResponse(arena: Allocator, entries: []const SessionEntry) !Response {
    const sessions = try arena.alloc(SessionSummary, entries.len);
    for (entries, 0..) |entry, idx| {
        sessions[idx] = try buildSessionSummary(arena, entry);
    }

    return .{
        .ok = true,
        .sessions = sessions,
    };
}

fn appendServerSessions(
    arena: Allocator,
    entries: *std.ArrayListUnmanaged(SessionEntry),
    seen_ids: *std.StringHashMap(void),
    server_line: []const u8,
) !void {
    var parsed = std.json.parseFromSlice(std.json.Value, arena, server_line, .{}) catch return;
    defer parsed.deinit();

    const object = switch (parsed.value) {
        .object => |o| o,
        else => return,
    };

    const sessions_val = object.get("sessions") orelse return;
    if (sessions_val != .array) return;

    for (sessions_val.array.items) |s| {
        if (s != .object) continue;
        const obj = s.object;
        const id_str = getString(obj, "id") orelse continue;
        const entry = SessionEntry{
            .id = try arena.dupe(u8, id_str),
            .name = try dupOptionalString(arena, getString(obj, "name")),
            .program = try arena.dupe(u8, getString(obj, "program") orelse ""),
            .args = try arena.dupe(u8, getString(obj, "args") orelse ""),
            .status = try arena.dupe(u8, getString(obj, "status") orelse ""),
            .created_at_ms = if (obj.get("created_at_ms")) |v| switch (v) {
                .integer => |i| i,
                else => 0,
            } else 0,
        };
        try entries.append(arena, entry);
        try seen_ids.put(entry.id, {});
    }
}

/// Try to read the server's live session list without auto-spawning
/// one. Returns null (owned by the caller) if the server is not
/// currently running.
fn querySeverListIfLive(alloc: Allocator) !?[]u8 {
    const socket_path = try paths.resolveSocketPath(alloc);
    defer alloc.free(socket_path);

    var stream = ensure.tryConnect(socket_path) catch return null;
    defer stream.close();

    stream.writeAll("{\"op\":\"list\"}\n") catch return null;

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
    return try alloc.dupe(u8, buf.items[0..nl]);
}

/// Walk the session log directory, parse each orphan log file's first
/// and last event, and append a synthetic entry for any id not already
/// seen. The arena owns the strings in the returned entries.
fn scanDiskSessions(
    arena: Allocator,
    log_dir: ?[]const u8,
    entries: *std.ArrayListUnmanaged(SessionEntry),
    seen_ids: *std.StringHashMap(void),
) !void {
    const dir = log_dir orelse return;

    var root = std.fs.openDirAbsolute(dir, .{ .iterate = true }) catch return;
    defer root.close();

    var it = root.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".jsonl")) continue;
        const stem = entry.name[0 .. entry.name.len - ".jsonl".len];
        if (seen_ids.contains(stem)) continue;

        const path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ dir, entry.name });
        const file = std.fs.openFileAbsolute(path, .{}) catch continue;
        defer file.close();
        const bytes = file.readToEndAlloc(arena, 64 * 1024 * 1024) catch continue;

        const parsed_entry = parseLogFileForListing(arena, stem, bytes) orelse continue;
        try entries.append(arena, parsed_entry);
        try seen_ids.put(parsed_entry.id, {});
    }
}

/// Like resolveLogDir but never creates the directory — if it doesn't
/// exist, returns an error instead of trying to mkdir. Used by the list
/// disk scan where creating a log dir as a side effect of `hty list`
/// would be surprising.
fn resolveLogDirForClient(alloc: Allocator) ![]u8 {
    if (std.posix.getenv("XDG_STATE_HOME")) |state| {
        if (state.len > 0) {
            return std.fmt.allocPrint(alloc, "{s}/hty/logs", .{state});
        }
    }
    const home = std.posix.getenv("HOME") orelse return error.HomeNotSet;
    return std.fmt.allocPrint(alloc, "{s}/.local/state/hty/logs", .{home});
}

/// Build a SessionEntry from the contents of a log file. Reads the
/// first line (spawn event) for metadata and the last line for status.
fn parseLogFileForListing(arena: Allocator, stem: []const u8, bytes: []const u8) ?SessionEntry {
    if (bytes.len == 0) return null;

    const first_nl = std.mem.indexOfScalar(u8, bytes, '\n') orelse bytes.len;
    const first_line = bytes[0..first_nl];

    var first_parsed = std.json.parseFromSlice(std.json.Value, arena, first_line, .{}) catch return null;
    defer first_parsed.deinit();
    const first_obj = switch (first_parsed.value) {
        .object => |o| o,
        else => return null,
    };
    const program = getString(first_obj, "program") orelse "";
    const name = getString(first_obj, "name");
    const created = getInteger(first_obj, "t") orelse 0;
    const args = readStringArray(arena, first_obj, "args") catch return null;
    const args_joined = joinArgsForList(arena, args) catch return null;

    // Scan backward for the last non-empty line to determine status.
    var end = bytes.len;
    while (end > 0 and (bytes[end - 1] == '\n' or bytes[end - 1] == '\r')) end -= 1;
    var last_start = end;
    while (last_start > 0 and bytes[last_start - 1] != '\n') last_start -= 1;
    const last_line = if (end > last_start) bytes[last_start..end] else first_line;

    var last_parsed = std.json.parseFromSlice(std.json.Value, arena, last_line, .{}) catch return null;
    defer last_parsed.deinit();
    const last_obj = switch (last_parsed.value) {
        .object => |o| o,
        else => return null,
    };
    const last_kind = getString(last_obj, "kind") orelse "";
    const status: []const u8 = if (std.mem.eql(u8, last_kind, "exited"))
        "exited"
    else if (std.mem.eql(u8, last_kind, "killed"))
        "killed"
    else if (std.mem.eql(u8, last_kind, "failure"))
        "failed"
    else
        // No terminal event — session never finished cleanly. The server
        // either crashed mid-session or is a stale record from before an
        // abnormal shutdown. We can't know for sure so flag it.
        "stale";

    return SessionEntry{
        .id = arena.dupe(u8, stem) catch return null,
        .name = dupOptionalString(arena, name) catch return null,
        .program = arena.dupe(u8, program) catch return null,
        .args = args_joined,
        .status = arena.dupe(u8, status) catch return null,
        .created_at_ms = created,
    };
}

fn buildSessionSummary(arena: Allocator, entry: SessionEntry) !SessionSummary {
    return .{
        .id = try arena.dupe(u8, entry.id),
        .name = if (entry.name) |name| try arena.dupe(u8, name) else null,
        .program = try arena.dupe(u8, entry.program),
        .args = try arena.dupe(u8, entry.args),
        .status = try arena.dupe(u8, entry.status),
        .created_at_ms = entry.created_at_ms,
    };
}

fn dupOptionalString(arena: Allocator, value: ?[]const u8) !?[]const u8 {
    if (value) |v| return try arena.dupe(u8, v);
    return null;
}

fn joinArgsForList(alloc: Allocator, args: []const []const u8) ![]u8 {
    if (args.len == 0) return try alloc.alloc(u8, 0);
    var total: usize = 0;
    for (args) |arg| total += arg.len + 1;
    const out = try alloc.alloc(u8, total - 1);
    var idx: usize = 0;
    for (args, 0..) |arg, i| {
        if (i > 0) {
            out[idx] = ' ';
            idx += 1;
        }
        @memcpy(out[idx..][0..arg.len], arg);
        idx += arg.len;
    }
    return out;
}

fn formatAge(alloc: Allocator, age_ms: i64) ![]u8 {
    if (age_ms < 1000) return alloc.dupe(u8, "just now");
    const secs = @divFloor(age_ms, 1000);
    if (secs < 60) return std.fmt.allocPrint(alloc, "{d}s ago", .{secs});
    const mins = @divFloor(secs, 60);
    if (mins < 60) return std.fmt.allocPrint(alloc, "{d}m ago", .{mins});
    const hours = @divFloor(mins, 60);
    if (hours < 24) return std.fmt.allocPrint(alloc, "{d}h ago", .{hours});
    const days = @divFloor(hours, 24);
    return std.fmt.allocPrint(alloc, "{d}d ago", .{days});
}
