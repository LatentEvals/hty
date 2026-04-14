const std = @import("std");

const Allocator = std.mem.Allocator;

const paths = @import("paths.zig");
const resolveLogDir = paths.resolveLogDir;
const ensureOwnedDir = paths.ensureOwnedDir;

const json = @import("json.zig");
const readOptionalId = json.readOptionalId;
const readOptionalString = json.readOptionalString;
const readRequiredString = json.readRequiredString;

const protocol = @import("protocol.zig");
const Response = protocol.Response;
const encodeResponse = protocol.encodeResponse;
const requestErrorMessage = protocol.requestErrorMessage;

const SessionRegistry = @import("registry.zig").SessionRegistry;

const ops = @import("ops.zig");

const server_attach = @import("server_attach.zig");
const ConnectionResult = server_attach.ConnectionResult;
const detectAttachOp = server_attach.detectAttachOp;
const handleAttachConnection = server_attach.handleAttachConnection;

const empty_grace_ms: i64 = 10_000;

pub fn runServer(alloc: Allocator, socket_path: []const u8) !void {
    // Unlink stale socket file if present.
    std.posix.unlink(socket_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };

    const address = try std.net.Address.initUnix(socket_path);
    var server = try address.listen(.{ .reuse_address = true });
    defer server.deinit();
    defer std.posix.unlink(socket_path) catch {};

    var registry = SessionRegistry.init(alloc);
    defer registry.deinit();

    // Resolve the session log directory best-effort. If it can't be set up,
    // the server still runs — log hooks skip when registry.log_dir is null.
    const log_dir_opt: ?[]u8 = resolveLogDir(alloc) catch |err| blk: {
        std.debug.print("warning: session log dir unavailable ({s}) — logging disabled\n", .{@errorName(err)});
        break :blk null;
    };
    defer if (log_dir_opt) |d| alloc.free(d);
    if (log_dir_opt) |d| {
        const by_name = std.fmt.allocPrint(alloc, "{s}/by-name", .{d}) catch null;
        if (by_name) |bn| {
            defer alloc.free(bn);
            ensureOwnedDir(alloc, bn) catch |err| {
                std.debug.print("warning: by-name dir setup failed: {s}\n", .{@errorName(err)});
            };
        }
        registry.log_dir = d;
    }

    // Auto-shutdown: start in "empty" state. Every time the registry drops to
    // zero running sessions we note the timestamp; if we sit there for
    // empty_grace_ms without a new session, exit the server. A new session
    // clears the timer. The grace period absorbs rapid kill+run sequences.
    var empty_since_ms: ?i64 = std.time.milliTimestamp();

    while (true) {
        // Short poll so the accept loop wakes ~40 times per second and can
        // drain PTY events into the log / attach broadcast pipeline even
        // when no new RPC traffic arrives. 25ms matches the wait_for_*
        // polling granularity elsewhere in the server.
        var poll_fds = [_]std.posix.pollfd{.{
            .fd = server.stream.handle,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};
        const ready = std.posix.poll(&poll_fds, 25) catch |err| {
            std.debug.print("poll failed: {s}\n", .{@errorName(err)});
            continue;
        };

        // Drain every tick so attach clients see output promptly and the
        // session log file captures bytes even if the session has no RPC
        // traffic driving it.
        registry.drainAll();

        if (ready > 0 and (poll_fds[0].revents & std.posix.POLL.IN) != 0) {
            var conn = server.accept() catch |err| {
                std.debug.print("accept failed: {s}\n", .{@errorName(err)});
                continue;
            };
            const result = handleConnection(alloc, &registry, &conn) catch |err| blk: {
                std.debug.print("request failed: {s}\n", .{@errorName(err)});
                break :blk ConnectionResult.done;
            };
            switch (result) {
                .done => conn.stream.close(),
                .attached => {}, // Reader thread owns the stream now.
            }
        }

        // Update the empty-tracking timer based on the post-tick state.
        // Zombie (exited) sessions don't count — we only care whether
        // there's any _running_ process we'd be cutting off.
        if (registry.activeCount() > 0) {
            empty_since_ms = null;
        } else if (empty_since_ms == null) {
            empty_since_ms = std.time.milliTimestamp();
        }

        if (empty_since_ms) |since| {
            if (std.time.milliTimestamp() - since >= empty_grace_ms) return;
        }
    }
}

pub fn handleConnection(
    alloc: Allocator,
    registry: *SessionRegistry,
    conn: *std.net.Server.Connection,
) !ConnectionResult {
    // Read one request line.
    var buffer = std.array_list.Managed(u8).init(alloc);
    defer buffer.deinit();

    var chunk: [4096]u8 = undefined;
    while (true) {
        const n = try conn.stream.read(&chunk);
        if (n == 0) break;
        try buffer.appendSlice(chunk[0..n]);
        if (std.mem.indexOfScalar(u8, buffer.items, '\n') != null) break;
    }

    const newline = std.mem.indexOfScalar(u8, buffer.items, '\n') orelse buffer.items.len;
    const line = buffer.items[0..newline];

    if (std.mem.trim(u8, line, " \t\r").len == 0) {
        const empty = try encodeResponse(alloc, .{ .ok = false, .@"error" = "empty request" });
        defer alloc.free(empty);
        _ = try conn.stream.writeAll(empty);
        return .done;
    }

    // Peek at the op without consuming arena state; attach needs a
    // different lifecycle (keep the connection open, spawn a reader
    // thread) so we branch here before the normal RPC dispatch.
    const is_attach = detectAttachOp(alloc, line);
    if (is_attach) {
        return handleAttachConnection(alloc, registry, conn, line);
    }

    const response = try processRequestLine(alloc, registry, line);
    defer alloc.free(response);
    _ = try conn.stream.writeAll(response);
    return .done;
}

pub fn processRequestLine(alloc: Allocator, registry: *SessionRegistry, line: []const u8) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const value = std.json.parseFromSliceLeaky(std.json.Value, arena, line, .{}) catch |err| {
        return encodeResponse(alloc, .{
            .ok = false,
            .@"error" = @errorName(err),
        });
    };

    const object = switch (value) {
        .object => |object| object,
        else => {
            return encodeResponse(alloc, .{
                .ok = false,
                .@"error" = "request must be a JSON object",
            });
        },
    };

    const id = readOptionalId(object);
    const op = readRequiredString(object, "op") catch |err| {
        return encodeResponse(alloc, .{
            .id = id,
            .ok = false,
            .@"error" = @errorName(err),
        });
    };

    const response: Response = dispatchRequest(arena, registry, object, op, id) catch |err| .{
        .id = id,
        .ok = false,
        .@"error" = requestErrorMessage(err),
    };
    return encodeResponse(alloc, response);
}

pub fn dispatchRequest(
    arena: Allocator,
    registry: *SessionRegistry,
    object: std.json.ObjectMap,
    op: []const u8,
    id: ?i64,
) !Response {
    if (std.mem.eql(u8, op, "spawn")) return ops.handleSpawn(arena, registry, object, id);
    if (std.mem.eql(u8, op, "list")) return ops.handleList(arena, registry, id);

    // Validate the op before touching the session registry so unknown ops
    // surface as UnknownOperation rather than SessionNotFound.
    const known_ops = [_][]const u8{
        "snapshot",      "send_text",     "send_key",       "send_bytes_hex",
        "resize",        "wait_for_text", "wait_for_idle",  "wait_for_exit",
        "kill",          "delete",
    };
    var matched_op = false;
    for (known_ops) |candidate| {
        if (std.mem.eql(u8, op, candidate)) {
            matched_op = true;
            break;
        }
    }
    if (!matched_op) return error.UnknownOperation;

    const session_ref = try readOptionalString(object, "session");
    const sess = try registry.resolveOrSole(session_ref);

    if (std.mem.eql(u8, op, "snapshot")) return ops.handleSnapshot(arena, sess, id);
    if (std.mem.eql(u8, op, "send_text")) return ops.handleSendText(arena, sess, object, id);
    if (std.mem.eql(u8, op, "send_key")) return ops.handleSendKey(arena, sess, object, id);
    if (std.mem.eql(u8, op, "send_bytes_hex")) return ops.handleSendBytesHex(arena, sess, object, id);
    if (std.mem.eql(u8, op, "resize")) return ops.handleResize(arena, sess, object, id);
    if (std.mem.eql(u8, op, "wait_for_text")) return ops.handleWaitForText(arena, registry, sess, object, id);
    if (std.mem.eql(u8, op, "wait_for_idle")) return ops.handleWaitForIdle(arena, registry, sess, object, id);
    if (std.mem.eql(u8, op, "wait_for_exit")) return ops.handleWaitForExit(arena, registry, sess, object, id);
    if (std.mem.eql(u8, op, "kill")) return ops.handleKill(arena, registry, sess, id);
    if (std.mem.eql(u8, op, "delete")) return ops.handleDelete(arena, registry, sess, id);

    return error.UnknownOperation;
}
