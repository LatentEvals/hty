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
const logAttachConnectEvent = log_mod.logAttachConnectEvent;
const logAttachDisconnectEvent = log_mod.logAttachDisconnectEvent;

const uuid_mod = @import("uuid.zig");

const SessionRegistry = @import("registry.zig").SessionRegistry;

pub const ConnectionResult = enum { done, attached };

/// Distinguishes between the normal RPC path, an interactive attach, and
/// a read-only watch. The event loop uses this to decide whether to
/// hand off socket ownership to `handleAttachConnection` and with which
/// `read_only` setting.
pub const AttachOp = enum { none, attach, watch };

/// Parse the request line far enough to recognize an attach-style op
/// (interactive `attach` or read-only `watch`). Errors and non-matching
/// ops return `.none` so the normal RPC path handles them.
pub fn detectAttachOp(alloc: Allocator, line: []const u8) AttachOp {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, line, .{}) catch return .none;
    const object = switch (parsed) {
        .object => |o| o,
        else => return .none,
    };
    const op_val = object.get("op") orelse return .none;
    if (op_val != .string) return .none;
    if (std.mem.eql(u8, op_val.string, "attach")) return .attach;
    if (std.mem.eql(u8, op_val.string, "watch")) return .watch;
    return .none;
}

/// Full lifecycle of an attach-style connection: parse the request,
/// resolve the session, register a subscriber, write the initial ack
/// and snapshot frame, and spawn a reader thread that owns the socket
/// for the rest of the attach lifetime. Returns `.attached` on success
/// so the event loop hands off socket ownership; `.done` on failure
/// (the event loop closes the connection). `stream` must be in blocking
/// mode on entry — the ack/snapshot writes below rely on it; the socket
/// is flipped non-blocking here once the client joins the broadcast
/// list.
///
/// `read_only` flips two behaviors: (1) the resulting `AttachClient` is
/// marked read-only so `dispatchAttachFrame` drops input/resize frames,
/// and (2) an unresolved *name* reference parks the socket on the
/// registry's pending-watchers map instead of writing an error —
/// enabling `hty watch <name>` before the session is spawned.
/// See LatentEvals/hty#29.
pub fn handleAttachConnection(
    alloc: Allocator,
    registry: *SessionRegistry,
    stream: std.net.Stream,
    line: []const u8,
    read_only: bool,
) !ConnectionResult {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, line, .{}) catch {
        try writeAttachError(stream, "invalid json");
        return .done;
    };
    const object = switch (parsed) {
        .object => |o| o,
        else => {
            try writeAttachError(stream, "request must be a JSON object");
            return .done;
        },
    };

    const session_ref = readOptionalString(object, "session") catch null;
    const sess = registry.resolveOrSole(session_ref) catch |err| {
        // Pre-creation pending path: if read_only and the ref is a
        // non-empty name string that doesn't resolve, park the socket
        // in the registry's pending-watchers map and return. Ambiguous
        // prefixes still fail fast — adding sessions can't disambiguate
        // an existing ambiguity, and a null session_ref (sole-session
        // mode) can't be pre-registered.
        if (read_only and err == error.SessionNotFound) {
            if (session_ref) |name| {
                if (name.len > 0) {
                    return parkWatchSubscriber(registry, stream, name);
                }
            }
        }
        try writeAttachError(stream, requestErrorMessage(err));
        return .done;
    };
    // Borrow from `resolveOrSole` — released on every exit path of this
    // function. By the time we return, the AttachClient (if any) is
    // registered on the session's attach list, and session teardown owns
    // its lifecycle from there; the borrow only needs to cover the setup
    // window where we hold a bare `*Session`.
    defer registry.release(sess);

    // Optional resize on attach so the PTY matches the observer's terminal.
    // Watch subscribers are read-only — their terminal size is informational
    // only and must not perturb the PTY the session is driving.
    if (!read_only) {
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
    }

    // Mint a stable client id so connect/input/disconnect log events for
    // this attachment can be paired up, even when multiple clients overlap.
    // Format: `attach-<uuidv7>`. The `attach-` prefix makes the id self-
    // describing when it shows up in forensics tooling.
    var uuid_buf: [36]u8 = undefined;
    uuid_mod.generateUuidV7(&uuid_buf);
    const client_id = std.fmt.allocPrint(alloc, "attach-{s}", .{uuid_buf[0..]}) catch return .done;
    errdefer alloc.free(client_id);

    // Create the client and register it under the session's attach mutex.
    const client = alloc.create(AttachClient) catch {
        alloc.free(client_id);
        return .done;
    };
    client.* = .{
        .alloc = alloc,
        .session = sess,
        .stream = stream,
        .client_id = client_id,
        .read_only = read_only,
    };
    sess.attach_mutex.lock();
    sess.attach_clients.append(alloc, client) catch {
        sess.attach_mutex.unlock();
        alloc.free(client.client_id);
        alloc.destroy(client);
        return .done;
    };
    sess.attach_mutex.unlock();

    // Record the connect event BEFORE the first input byte flows back to
    // the PTY. The reader thread we spawn below may land an input event
    // within microseconds of this line, so emitting connect here keeps
    // the "bracketed by connect/disconnect" invariant intact.
    logAttachConnectEvent(arena, sess, client.client_id);

    // Write the attach ack. Once this goes out the client flips into
    // streaming mode.
    try writeAttachAck(stream);

    // Make the socket non-blocking from here on: every later write goes
    // through `tryWriteFrame`'s bounded-buffer path, and the drain step's
    // broadcasts must never block on a client that stopped reading. If
    // the fcntl fails (it shouldn't), drop the client rather than let a
    // blocking socket onto the broadcast list.
    session_mod.setStreamNonBlocking(stream.handle) catch {
        client.shutdown();
    };

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
        // On spawn failure, remove from the list and tear down. Emit a
        // disconnect event since the connect event above already made it
        // into the log and readers shouldn't see a dangling half-bracket.
        sess.attach_mutex.lock();
        var i: usize = 0;
        while (i < sess.attach_clients.items.len) : (i += 1) {
            if (sess.attach_clients.items[i] == client) {
                _ = sess.attach_clients.swapRemove(i);
                break;
            }
        }
        sess.attach_mutex.unlock();
        if (!client.disconnect_logged.swap(true, .acq_rel)) {
            logAttachDisconnectEvent(arena, sess, client.client_id);
        }
        client.deinit();
        return .done;
    };

    return .attached;
}

pub fn writeAttachAck(stream: std.net.Stream) !void {
    try stream.writeAll("{\"ok\":true}\n");
}

/// Ack variant for pre-creation subscribers. Includes `waiting:true` so
/// the client knows to paint a "Waiting…" frame and delay any per-client
/// setup (for attach: raw mode, SIGWINCH) until the `started` frame
/// arrives. Older clients that don't recognize the field safely ignore it.
pub fn writeAttachAckWaiting(stream: std.net.Stream) !void {
    try stream.writeAll("{\"ok\":true,\"waiting\":true}\n");
}

/// Park a watch-style subscriber whose target session doesn't exist yet.
/// Writes the waiting-ack, parks the socket on the registry's pending
/// map, and returns `.attached` so the caller surrenders ownership of
/// the stream. The socket is promoted to a real `AttachClient` the
/// next time a session with a matching name is created.
fn parkWatchSubscriber(
    registry: *SessionRegistry,
    stream: std.net.Stream,
    name: []const u8,
) !ConnectionResult {
    // Send the waiting ack BEFORE parking so the client knows it's
    // subscribed. If the ack write fails the socket is already toast —
    // don't bother parking it.
    writeAttachAckWaiting(stream) catch {
        return .done;
    };
    _ = registry.parkPendingWatcher(name, stream) catch {
        // Parking failed (allocation or thread spawn). Best we can do is
        // write an error and let the client retry.
        writeAttachError(stream, "server busy; could not park pending watcher") catch {};
        return .done;
    };
    return .attached;
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
///
/// The socket is non-blocking (the broadcast writer must never stall on
/// it), so this loop blocks in `poll` rather than `read`. The poll
/// timeout doubles as a periodic check of the `closed` flag.
pub fn attachReaderLoop(client: *AttachClient) void {
    defer client.closed.store(true, .release);

    const alloc = client.alloc;
    var buffer = std.array_list.Managed(u8).init(alloc);
    defer buffer.deinit();

    var chunk: [4096]u8 = undefined;
    while (!client.isClosed()) {
        var pfds = [_]std.posix.pollfd{.{
            .fd = client.stream.handle,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};
        const ready = std.posix.poll(&pfds, 250) catch break;
        if (ready == 0) continue;
        const n = client.stream.read(&chunk) catch |err| switch (err) {
            error.WouldBlock => continue,
            else => break,
        };
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
        // Read-only (watch) clients may not drive the PTY. Silently drop
        // the frame rather than erroring — a stale or confused client
        // shouldn't tear the connection down, but must not be able to
        // type into a watched session.
        if (client.read_only) return;
        const hex_val = object.get("bytes_hex") orelse return;
        if (hex_val != .string) return;
        const bytes = decodeHex(arena, hex_val.string) catch return;
        client.session.terminal.send(.{ .bytes = bytes }) catch {};
        // Mirror the RPC send path: record input in the log too, tagged
        // `origin: "attach"` with this connection's client_id so two
        // overlapping attach clients remain distinguishable post-mortem.
        logInputEvent(arena, client.session, bytes, "attach", client.client_id);
        return;
    }

    if (std.mem.eql(u8, op, "resize")) {
        // Watch clients can't resize the PTY. See comment on `input`.
        if (client.read_only) return;
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

test "detectAttachOp recognizes attach and watch requests" {
    const alloc = std.testing.allocator;
    try std.testing.expectEqual(AttachOp.attach, detectAttachOp(alloc, "{\"op\":\"attach\",\"session\":\"foo\"}"));
    try std.testing.expectEqual(AttachOp.attach, detectAttachOp(alloc, "{\"op\":\"attach\"}"));
    try std.testing.expectEqual(AttachOp.watch, detectAttachOp(alloc, "{\"op\":\"watch\",\"session\":\"foo\"}"));
    try std.testing.expectEqual(AttachOp.watch, detectAttachOp(alloc, "{\"op\":\"watch\"}"));
    try std.testing.expectEqual(AttachOp.none, detectAttachOp(alloc, "{\"op\":\"snapshot\"}"));
    try std.testing.expectEqual(AttachOp.none, detectAttachOp(alloc, "{\"op\":\"spawn\",\"program\":\"/bin/sh\"}"));
    try std.testing.expectEqual(AttachOp.none, detectAttachOp(alloc, "not json"));
    try std.testing.expectEqual(AttachOp.none, detectAttachOp(alloc, "[\"attach\"]"));
}
