//! Broadcast frames from a session's PTY output dispatch out to every
//! live `hty attach` client subscribed to that session.
//!
//! All functions here run on the server's event-loop thread (or the
//! single test thread), which is the only thread that ever touches a
//! session's attach-client list — no locking needed.
//!
//! Broadcasts never block: `tryWriteFrame` uses non-blocking sends and a
//! bounded per-client pending buffer, so a client that stops reading can't
//! wedge the loop. Overflowing the bound marks the client closed and it
//! gets reaped like any other drop.

const std = @import("std");
const session_mod = @import("session.zig");
const hex_mod = @import("hex.zig");
const log_mod = @import("log.zig");

const Session = session_mod.Session;
const AttachClient = session_mod.AttachClient;

/// Build a JSONL output frame ({"kind":"output","bytes_hex":"..."}) and
/// broadcast it to every client attached to `sess`. Clients whose write
/// fails get marked closed and reaped on the next drain pass.
pub fn broadcastRawBytesToAttach(sess: *Session, bytes: []const u8) void {
    if (sess.attach_clients.items.len == 0) return;

    var arena_state = std.heap.ArenaAllocator.init(sess.alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const hex = hex_mod.encodeHex(arena, bytes) catch return;
    const frame = std.fmt.allocPrint(
        arena,
        "{{\"kind\":\"output\",\"bytes_hex\":\"{s}\"}}\n",
        .{hex},
    ) catch return;
    for (sess.attach_clients.items) |client| _ = client.tryWriteFrame(frame);
}

pub fn broadcastExitedToAttach(sess: *Session, code: ?i32) void {
    if (sess.attach_clients.items.len == 0) return;

    var arena_state = std.heap.ArenaAllocator.init(sess.alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const frame = std.fmt.allocPrint(
        arena,
        "{{\"kind\":\"exited\",\"code\":{d}}}\n",
        .{code orelse 0},
    ) catch return;
    for (sess.attach_clients.items) |client| {
        _ = client.tryWriteFrame(frame);
        // Exit is terminal for the session, so also mark the client closed
        // so the reap path (loop or drain) can shut it down cleanly.
        client.shutdown();
    }
}

/// Give every attached client a chance to drain bytes buffered by an
/// earlier would-block send. Called from the in-process pump so a client
/// that stalled during a burst catches back up (or errors out and gets
/// reaped) even when the session emits no further output; loop-owned
/// clients flush on POLLOUT instead.
pub fn flushPendingToAttach(sess: *Session) void {
    for (sess.attach_clients.items) |client| client.flushPending();
}

/// Remove any self-owned attached clients whose socket has been closed
/// (either by the client itself or by a failed/overflowed write in the
/// broadcast loop). Every reaped client emits an `attach_disconnect` log
/// event — the single choke-point for both graceful detach and abrupt
/// drops, because every one of those paths ends up flipping
/// `client.closed` and landing here.
///
/// Clients owned by an event-loop connection (`owned_by_conn`) are
/// skipped: the loop reaps those itself when it tears the connection
/// down, emitting the same disconnect event.
pub fn reapClosedAttachClients(sess: *Session) void {
    var reaped: std.ArrayListUnmanaged(*AttachClient) = .empty;
    defer reaped.deinit(sess.alloc);

    var i: usize = 0;
    while (i < sess.attach_clients.items.len) {
        const client = sess.attach_clients.items[i];
        if (client.isClosed() and !client.owned_by_conn) {
            _ = sess.attach_clients.swapRemove(i);
            reaped.append(sess.alloc, client) catch {};
            continue;
        }
        i += 1;
    }

    // Emit the disconnect event before deinit so the client_id is still
    // valid.
    for (reaped.items) |client| {
        if (!client.disconnect_logged) {
            client.disconnect_logged = true;
            var arena_state = std.heap.ArenaAllocator.init(sess.alloc);
            defer arena_state.deinit();
            log_mod.logAttachDisconnectEvent(arena_state.allocator(), sess, client.client_id);
        }
        client.deinit();
    }
}
