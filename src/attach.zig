//! Broadcast frames from a session's drain loop out to every live
//! `hty attach` client subscribed to that session.
//!
//! All three functions are called from the drain step under the server's
//! main loop — they take the per-session `attach_mutex` to serialize with
//! the per-client writer threads. `reapClosedAttachClients` is where closed
//! clients get `deinit`d; that happens OUTSIDE the mutex so the joined
//! reader thread can call back into session state without deadlocking.

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
    sess.attach_mutex.lock();
    defer sess.attach_mutex.unlock();
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
    sess.attach_mutex.lock();
    defer sess.attach_mutex.unlock();
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
        // so its reader thread (and the deinit path) can shut down cleanly.
        client.shutdown();
    }
}

/// Remove any attached clients whose socket has been closed (either by the
/// client itself or by a failed write in the broadcast loop). Every reaped
/// client emits an `attach_disconnect` log event — this is the single
/// choke-point that fires for both graceful detach and abrupt drops
/// (broken pipe, ssh tunnel closed, client process killed), because every
/// one of those paths ends up flipping `client.closed` and landing here.
pub fn reapClosedAttachClients(sess: *Session) void {
    sess.attach_mutex.lock();
    var reaped: std.ArrayListUnmanaged(*AttachClient) = .{};
    defer reaped.deinit(sess.alloc);

    var i: usize = 0;
    while (i < sess.attach_clients.items.len) {
        const client = sess.attach_clients.items[i];
        if (client.isClosed()) {
            _ = sess.attach_clients.swapRemove(i);
            reaped.append(sess.alloc, client) catch {};
            continue;
        }
        i += 1;
    }
    sess.attach_mutex.unlock();

    // deinit joins the reader thread — do it outside the mutex so the reader
    // can call back into session state without deadlocking. Emit the
    // disconnect event before deinit so the client_id is still valid.
    for (reaped.items) |client| {
        if (!client.disconnect_logged.swap(true, .acq_rel)) {
            var arena_state = std.heap.ArenaAllocator.init(sess.alloc);
            defer arena_state.deinit();
            log_mod.logAttachDisconnectEvent(arena_state.allocator(), sess, client.client_id);
        }
        client.deinit();
    }
}
