const std = @import("std");

const Allocator = std.mem.Allocator;

const hex = @import("hex.zig");
const encodeHex = hex.encodeHex;
const decodeHex = hex.decodeHex;

const json = @import("json.zig");
const readOptionalString = json.readOptionalString;

const protocol = @import("protocol.zig");
const requestErrorMessage = protocol.requestErrorMessage;

const session_mod = @import("session.zig");
const AttachClient = session_mod.AttachClient;

const log_mod = @import("log.zig");
const logInputEvent = log_mod.logInputEvent;
const logResizeEvent = log_mod.logResizeEvent;

const SessionRegistry = @import("registry.zig").SessionRegistry;

pub const ConnectionResult = enum { done, attached };

/// Parse the request line far enough to recognize an attach op. Errors and
/// non-attach ops both return false so the normal RPC path handles them.
pub fn detectAttachOp(alloc: Allocator, line: []const u8) bool {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, line, .{}) catch return false;
    const object = switch (parsed) {
        .object => |o| o,
        else => return false,
    };
    const op_val = object.get("op") orelse return false;
    if (op_val != .string) return false;
    return std.mem.eql(u8, op_val.string, "attach");
}

/// Full lifecycle of an attach-style connection: parse the request,
/// resolve the session, register a subscriber, write the initial ack
/// and snapshot frame, and spawn a reader thread that owns the socket
/// for the rest of the attach lifetime. Returns `.attached` on success
/// so the accept loop hands off socket ownership; `.done` on failure
/// (the accept loop closes the connection).
pub fn handleAttachConnection(
    alloc: Allocator,
    registry: *SessionRegistry,
    conn: *std.net.Server.Connection,
    line: []const u8,
) !ConnectionResult {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, line, .{}) catch {
        try writeAttachError(conn.stream, "invalid json");
        return .done;
    };
    const object = switch (parsed) {
        .object => |o| o,
        else => {
            try writeAttachError(conn.stream, "request must be a JSON object");
            return .done;
        },
    };

    const session_ref = readOptionalString(object, "session") catch null;
    const sess = registry.resolveOrSole(session_ref) catch |err| {
        try writeAttachError(conn.stream, requestErrorMessage(err));
        return .done;
    };

    // Optional resize on attach so the PTY matches the observer's terminal.
    if (object.get("rows")) |rv| {
        if (object.get("cols")) |cv| {
            if (rv == .integer and cv == .integer) {
                const rows: u16 = @intCast(@max(1, rv.integer));
                const cols: u16 = @intCast(@max(1, cv.integer));
                sess.terminal.resize(rows, cols) catch {};
                logResizeEvent(arena, sess, rows, cols);
            }
        }
    }

    // Create the client and register it under the session's attach mutex.
    const client = alloc.create(AttachClient) catch return .done;
    client.* = .{
        .alloc = alloc,
        .session = sess,
        .stream = conn.stream,
    };
    sess.attach_mutex.lock();
    sess.attach_clients.append(alloc, client) catch {
        sess.attach_mutex.unlock();
        alloc.destroy(client);
        return .done;
    };
    sess.attach_mutex.unlock();

    // Write the attach ack. Once this goes out the client flips into
    // streaming mode.
    try writeAttachAck(conn.stream);

    // Send an initial snapshot so the attach viewer has something to
    // show right away (the recorded output stream doesn't replay).
    if (sess.terminal.snapshot()) |snap| {
        var owned = snap;
        defer owned.deinit(sess.alloc);
        // Reuse the broadcast encoder shape — feed the raw screen_ansi
        // as an output frame so the client's output decoder handles it.
        const hex_str = encodeHex(arena, owned.screen_ansi) catch null;
        if (hex_str) |h| {
            const frame = std.fmt.allocPrint(
                arena,
                "{{\"kind\":\"output\",\"bytes_hex\":\"{s}\"}}\n",
                .{h},
            ) catch null;
            if (frame) |f| _ = client.tryWriteFrame(f);
        }
    } else |_| {}

    // Spawn the reader thread that owns the socket from here on.
    client.reader_thread = std.Thread.spawn(.{}, attachReaderLoop, .{client}) catch {
        // On spawn failure, remove from the list and tear down.
        sess.attach_mutex.lock();
        var i: usize = 0;
        while (i < sess.attach_clients.items.len) : (i += 1) {
            if (sess.attach_clients.items[i] == client) {
                _ = sess.attach_clients.swapRemove(i);
                break;
            }
        }
        sess.attach_mutex.unlock();
        client.deinit();
        return .done;
    };

    return .attached;
}

pub fn writeAttachAck(stream: std.net.Stream) !void {
    try stream.writeAll("{\"ok\":true}\n");
}

pub fn writeAttachError(stream: std.net.Stream, message: []const u8) !void {
    var buf: [256]u8 = undefined;
    const line = std.fmt.bufPrint(
        &buf,
        "{{\"ok\":false,\"error\":\"{s}\"}}\n",
        .{message},
    ) catch "{\"ok\":false,\"error\":\"attach failed\"}\n";
    try stream.writeAll(line);
}

/// Reader thread for one attach connection. Reads JSONL frames from the
/// socket and dispatches: input bytes get forwarded to the PTY, resize
/// ops retarget the terminal, detach ops exit the loop cleanly. Any
/// error (EOF, parse failure, bad socket) ends the loop; the client is
/// marked closed so the next drain pass reaps it.
pub fn attachReaderLoop(client: *AttachClient) void {
    defer client.closed.store(true, .release);

    const alloc = client.alloc;
    var buffer = std.array_list.Managed(u8).init(alloc);
    defer buffer.deinit();

    var chunk: [4096]u8 = undefined;
    while (!client.isClosed()) {
        const n = client.stream.read(&chunk) catch break;
        if (n == 0) break;
        buffer.appendSlice(chunk[0..n]) catch break;

        while (std.mem.indexOfScalar(u8, buffer.items, '\n')) |nl| {
            const line = buffer.items[0..nl];
            dispatchAttachFrame(client, line) catch break;
            // Shift leftover bytes to the front.
            const rest = buffer.items[nl + 1 ..];
            std.mem.copyForwards(u8, buffer.items[0..rest.len], rest);
            buffer.shrinkRetainingCapacity(rest.len);
        }
    }
}

pub fn dispatchAttachFrame(client: *AttachClient, line: []const u8) !void {
    if (std.mem.trim(u8, line, " \t\r").len == 0) return;

    var arena_state = std.heap.ArenaAllocator.init(client.alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, line, .{}) catch return error.BadFrame;
    const object = switch (parsed) {
        .object => |o| o,
        else => return error.BadFrame,
    };

    const op_val = object.get("op") orelse return;
    if (op_val != .string) return;
    const op = op_val.string;

    if (std.mem.eql(u8, op, "input")) {
        const hex_val = object.get("bytes_hex") orelse return;
        if (hex_val != .string) return;
        const bytes = decodeHex(arena, hex_val.string) catch return;
        client.session.terminal.send(.{ .bytes = bytes }) catch {};
        // Mirror the RPC send path: record input in the log too.
        logInputEvent(arena, client.session, bytes);
        return;
    }

    if (std.mem.eql(u8, op, "resize")) {
        const rows_val = object.get("rows") orelse return;
        const cols_val = object.get("cols") orelse return;
        if (rows_val != .integer or cols_val != .integer) return;
        const rows: u16 = @intCast(@max(1, rows_val.integer));
        const cols: u16 = @intCast(@max(1, cols_val.integer));
        client.session.terminal.resize(rows, cols) catch {};
        logResizeEvent(arena, client.session, rows, cols);
        return;
    }

    if (std.mem.eql(u8, op, "detach")) {
        return error.Detach;
    }
}
