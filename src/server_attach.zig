//! Attach/watch connection bring-up and frame dispatch for the event
//! loop. There are no threads here: the loop owns every attach socket and
//! feeds inbound bytes through `dispatchAttachFrame`; outbound broadcast
//! frames go through the client's bounded non-blocking buffer
//! (`AttachClient.tryWriteFrame`).

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
const Session = session_mod.Session;

const log_mod = @import("log.zig");
const logInputEvent = log_mod.logInputEvent;
const logResizeEvent = log_mod.logResizeEvent;
const logAttachConnectEvent = log_mod.logAttachConnectEvent;

const uuid_mod = @import("uuid.zig");

const SessionRegistry = @import("registry.zig").SessionRegistry;

/// Distinguishes between the normal RPC path, an interactive attach, and
/// a read-only watch. The event loop uses this to decide whether to flip
/// the connection into an attach-style state and with which `read_only`
/// setting.
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

/// Outcome of `handleAttachConnection`: what the event loop should do
/// with the connection.
pub const AttachSetup = union(enum) {
    /// Setup failed; an error line was written (best-effort). Close the
    /// connection.
    done,
    /// Registered on a live session. The client is on the session's
    /// attach list; the ack and initial snapshot are queued through its
    /// buffer. The caller decides lifecycle ownership (`owned_by_conn`).
    attached: *AttachClient,
    /// Watch-by-name for a session that doesn't exist yet: the waiting
    /// ack was written; the caller should park the connection in a
    /// pending-watch state. The name is owned by the caller (allocated
    /// with the passed allocator).
    pending: []u8,
};

/// Bring-up of an attach-style connection: parse the request, resolve the
/// session, register a subscriber, and queue the initial ack and snapshot
/// frames through the client's non-blocking buffer. The stream must
/// already be (or is put) in non-blocking mode — no write here can block.
///
/// `read_only` flips two behaviors: (1) the resulting `AttachClient` is
/// marked read-only so `dispatchAttachFrame` drops input/resize frames,
/// and (2) an unresolved *name* reference yields `.pending` instead of an
/// error — enabling `hty watch <name>` before the session is spawned.
/// See LatentEvals/hty#29.
pub fn handleAttachConnection(
    alloc: Allocator,
    registry: *SessionRegistry,
    stream: std.net.Stream,
    line: []const u8,
    read_only: bool,
) !AttachSetup {
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
    // The resolved pointer is valid for the duration of this call —
    // session frees are deferred to the loop's end-of-iteration phase.
    const sess = registry.resolveOrSole(session_ref) catch |err| {
        // Pre-creation pending path: if read_only and the ref is a
        // non-empty name string that doesn't resolve, park the
        // connection until a session with that name is created.
        // Ambiguous prefixes still fail fast — adding sessions can't
        // disambiguate an existing ambiguity, and a null session_ref
        // (sole-session mode) can't be pre-registered.
        if (read_only and err == error.SessionNotFound) {
            if (session_ref) |name| {
                if (name.len > 0) {
                    // Send the waiting ack BEFORE reporting `.pending` so
                    // the client knows it's subscribed. If the ack write
                    // fails the socket is already toast.
                    writeAttachAckWaiting(stream) catch return .done;
                    const owned = try alloc.dupe(u8, name);
                    return .{ .pending = owned };
                }
            }
        }
        try writeAttachError(stream, requestErrorMessage(err));
        return .done;
    };

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
                    sess.touchAfterResize();
                }
            }
        }
    }

    // Every write from here on goes through the client's bounded
    // non-blocking buffer, so the socket must carry the O_NONBLOCK flag
    // (loop-accepted sockets already do; in-process callers may hand us a
    // blocking socketpair). If the fcntl fails (it shouldn't), bail
    // rather than let a blocking socket onto the broadcast list.
    session_mod.setStreamNonBlocking(stream.handle) catch {
        try writeAttachError(stream, "attach failed");
        return .done;
    };

    const client = registerSubscriber(alloc, sess, stream, read_only) catch return .done;

    // Queue the attach ack. Once this goes out the client flips into
    // streaming mode. Then the initial snapshot, so the viewer has
    // something to show right away (the recorded output stream doesn't
    // replay). Both go through the same buffer, so order is preserved.
    _ = client.tryWriteFrame("{\"ok\":true}\n");
    sendSnapshotFrame(client);

    return .{ .attached = client };
}

/// Shared bring-up for a subscriber joining a live session: mint a stable
/// client id, register the client on the session's attach list, and log
/// the `attach_connect` event. Used by the live attach/watch path and by
/// pending-watch promotion. The connect event is recorded BEFORE any
/// input frame from this client can be dispatched, keeping the log's
/// "input bracketed by connect/disconnect" invariant intact.
pub fn registerSubscriber(
    alloc: Allocator,
    sess: *Session,
    stream: std.net.Stream,
    read_only: bool,
) !*AttachClient {
    // Mint a stable client id so connect/input/disconnect log events for
    // this attachment can be paired up, even when multiple clients overlap.
    // Format: `attach-<uuidv7>`. The `attach-` prefix makes the id self-
    // describing when it shows up in forensics tooling.
    var uuid_buf: [36]u8 = undefined;
    uuid_mod.generateUuidV7(&uuid_buf);
    const client_id = try std.fmt.allocPrint(alloc, "attach-{s}", .{uuid_buf[0..]});
    errdefer alloc.free(client_id);

    const client = try alloc.create(AttachClient);
    errdefer alloc.destroy(client);
    client.* = .{
        .alloc = alloc,
        .session = sess,
        .stream = stream,
        .client_id = client_id,
        .read_only = read_only,
    };
    try sess.attach_clients.append(alloc, client);

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    logAttachConnectEvent(arena_state.allocator(), sess, client.client_id);
    return client;
}

/// Promote a parked watch subscriber onto a newly-created session:
/// register it read-only, log the connect, and queue the `started` frame
/// (which gates the client-side raw-mode flip / clears the "Waiting…"
/// paint) followed by the initial snapshot — matching what a
/// first-time-live watch receives.
pub fn promoteWatchSubscriber(
    alloc: Allocator,
    sess: *Session,
    stream: std.net.Stream,
) !*AttachClient {
    const client = try registerSubscriber(alloc, sess, stream, true);
    _ = client.tryWriteFrame("{\"kind\":\"started\"}\n");
    sendSnapshotFrame(client);
    return client;
}

/// Queue the current screen as an `output` frame — the same shape the
/// broadcast encoder uses, so the client's output decoder handles it.
pub fn sendSnapshotFrame(client: *AttachClient) void {
    const sess = client.session;
    if (sess.terminal.snapshot()) |snap| {
        var owned = snap;
        defer owned.deinit(sess.alloc);
        var arena_state = std.heap.ArenaAllocator.init(client.alloc);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
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

pub fn writeAttachError(stream: std.net.Stream, message: []const u8) !void {
    var buf: [256]u8 = undefined;
    const line = std.fmt.bufPrint(
        &buf,
        "{{\"ok\":false,\"error\":\"{s}\"}}\n",
        .{message},
    ) catch "{\"ok\":false,\"error\":\"attach failed\"}\n";
    try stream.writeAll(line);
}

/// Dispatch one JSONL frame from an attach client: input bytes are queued
/// on the owning session's pending-input buffer (whole-frame appends —
/// frames from concurrent clients and RPC sends interleave at frame
/// granularity, never mid-frame), resize ops retarget the terminal
/// directly (`ioctl` doesn't block), detach ops surface `error.Detach` so
/// the caller ends the attachment.
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
        // Mirror the RPC send path: record input in the log too, tagged
        // `origin: "attach"` with this connection's client_id so two
        // overlapping attach clients remain distinguishable post-mortem.
        // Logging happens at append time, preserving connect-before-input
        // ordering.
        logInputEvent(arena, client.session, bytes, "attach", client.client_id);
        client.session.queueInput(bytes) catch {};
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
        client.session.touchAfterResize();
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
