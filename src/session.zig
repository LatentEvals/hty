//! Session + AttachClient + SessionStatus.
//!
//! These types are bundled in one file because Session owns a list of
//! `*AttachClient` and AttachClient holds a `*Session`. Splitting them would
//! create a circular import that Zig can technically express via opaque
//! pointers but would only obscure the fact that they're a single tightly-
//! coupled concept: a PTY-backed session and the live connections observing
//! it.

const std = @import("std");
const sys = @import("hty").sys;
const hty = @import("hty");
const Allocator = std.mem.Allocator;

pub const SessionStatus = enum { running, exited, failed, killed };

/// Per-session mouse-input mode state, inferred by sniffing the PTY output
/// stream for DEC private mode toggles (`CSI ? Pm h/l`). Apps opt into
/// mouse input with `?1000` / `?1002` / `?1003` (event sets) and `?1006`
/// for SGR extended encoding. `hty send --click` consults this state to
/// (a) refuse to send if nothing is enabled, and (b) pick the right
/// encoding when it is.
///
/// Plain fields: writers (the loop's PTY output dispatch) and readers
/// (`send_mouse` / `snapshot` handlers) all run on the single server
/// thread.
pub const MouseState = struct {
    /// `CSI ?1000` — button-event mode (press/release only, no motion).
    x10: bool = false,
    /// `CSI ?1002` — button-event + drag motion while pressed.
    button_event: bool = false,
    /// `CSI ?1003` — any-event motion (even without a button pressed).
    any_event: bool = false,
    /// `CSI ?1006` — SGR extended encoding. Independent of the event
    /// mode — apps typically enable 1000/1002/1003 *and* 1006 together.
    sgr: bool = false,

    pub fn init() MouseState {
        return .{};
    }

    /// True if any event-set mode is on (1000/1002/1003). This is the
    /// gate `send --click` checks.
    pub fn isEnabled(self: *const MouseState) bool {
        return self.x10 or self.button_event or self.any_event;
    }

    /// Snapshot all four flags to a plain struct for serialization.
    pub fn snapshot(self: *const MouseState) MouseStateSnapshot {
        return .{
            .x10 = self.x10,
            .button_event = self.button_event,
            .any_event = self.any_event,
            .sgr = self.sgr,
        };
    }
};

pub const MouseStateSnapshot = struct {
    x10: bool,
    button_event: bool,
    any_event: bool,
    sgr: bool,

    /// True when any event-set mode is enabled.
    pub fn enabled(self: MouseStateSnapshot) bool {
        return self.x10 or self.button_event or self.any_event;
    }
};

/// Scan `bytes` (a chunk of PTY output) for DEC private mode toggles of
/// the form `ESC [ ? Pm ; Pm ... h` (enable) or `... l` (disable) and
/// apply the mouse-related ones to `mouse`. Non-matching bytes are
/// ignored; this is a lenient sniffer, not a full VT parser (the real
/// VT is Ghostty's job — we just tee a byte-level view to learn about
/// mouse modes). Chunks that split a sequence mid-way are still picked
/// up when the next output chunk is dispatched. In practice apps emit
/// the toggle as one write, so a split is rare.
pub fn applyMouseModeTogglesFromOutput(mouse: *MouseState, bytes: []const u8) void {
    var i: usize = 0;
    while (i + 2 < bytes.len) {
        // Look for ESC [ ? — a DEC private mode sequence.
        if (bytes[i] != 0x1B) {
            i += 1;
            continue;
        }
        if (bytes[i + 1] != '[' or bytes[i + 2] != '?') {
            i += 1;
            continue;
        }
        // Walk forward collecting semicolon-separated decimal params
        // until we hit the terminator 'h' or 'l'.
        var p: usize = i + 3;
        const params_start = p;
        while (p < bytes.len) : (p += 1) {
            const b = bytes[p];
            if (b == 'h' or b == 'l') break;
            // Only digits and ';' are valid inside a DEC private param
            // list. Anything else means this wasn't a clean mode toggle;
            // bail out and keep scanning from the next byte.
            if (!(b >= '0' and b <= '9') and b != ';') {
                p = bytes.len;
                break;
            }
        }
        if (p >= bytes.len) {
            i += 1;
            continue;
        }
        const enable = bytes[p] == 'h';
        const params = bytes[params_start..p];
        // Split on ';' and apply each numeric param.
        var tok_it = std.mem.splitScalar(u8, params, ';');
        while (tok_it.next()) |tok| {
            if (tok.len == 0) continue;
            const n = std.fmt.parseInt(u32, tok, 10) catch continue;
            switch (n) {
                1000 => mouse.x10 = enable,
                1002 => mouse.button_event = enable,
                1003 => mouse.any_event = enable,
                1006 => mouse.sgr = enable,
                else => {},
            }
        }
        i = p + 1;
    }
}

test "applyMouseModeTogglesFromOutput: enable 1000 + 1006" {
    var m = MouseState.init();
    applyMouseModeTogglesFromOutput(&m, "\x1b[?1000h\x1b[?1006h");
    try std.testing.expect(m.x10);
    try std.testing.expect(m.sgr);
    try std.testing.expect(!m.button_event);
}

test "applyMouseModeTogglesFromOutput: disable 1002" {
    var m = MouseState.init();
    m.button_event = true;
    applyMouseModeTogglesFromOutput(&m, "junk \x1b[?1002l tail");
    try std.testing.expect(!m.button_event);
}

test "applyMouseModeTogglesFromOutput: combined params" {
    var m = MouseState.init();
    applyMouseModeTogglesFromOutput(&m, "\x1b[?1002;1006h");
    try std.testing.expect(m.button_event);
    try std.testing.expect(m.sgr);
}

test "applyMouseModeTogglesFromOutput: 1015 is ignored" {
    var m = MouseState.init();
    applyMouseModeTogglesFromOutput(&m, "\x1b[?1015h");
    try std.testing.expect(!m.x10);
    try std.testing.expect(!m.sgr);
}

pub fn statusName(status: SessionStatus) []const u8 {
    return switch (status) {
        .running => "running",
        .exited => "exited",
        .failed => "failed",
        .killed => "killed",
    };
}

pub const Session = struct {
    /// Upper bound on unflushed input bytes queued for the PTY master
    /// (raw bytes, post hex-decode). Interactive input is human-scale;
    /// once a child has 64 KiB of unconsumed input it has stopped reading
    /// its tty and further input is dropped rather than buffered without
    /// bound (PRD: drop with a debug-level note, never stall the server).
    pub const max_pending_input_bytes: usize = 64 * 1024;

    alloc: Allocator,
    id: [36]u8,
    name: ?[]u8,
    terminal: *hty.InteractiveTerminal,
    program: []u8,
    args_joined: []u8,
    created_at_ms: i64,

    /// Lifecycle fields. Plain values: everything that reads or writes
    /// them — PTY dispatch, wait evaluation, RPC handlers — runs on the
    /// single server thread (or the single test thread).
    last_screen_change_at_ms: i64,
    status: SessionStatus = .running,
    exit_code: ?i32 = null,

    /// When true, the registry automatically removes this session once the
    /// child process exits (success, failure, signal, or `hty kill`).
    /// Opt-in via `hty run --remove`. The auto-remove sweep treats this
    /// identically to `hty delete` — same teardown, same filesystem
    /// cleanup. In-flight waiters are protected structurally: removal
    /// unpublishes the session immediately and the storage is freed in
    /// the loop's deferred-free phase, never mid-dispatch.
    remove_on_exit: bool = false,
    /// Unix-epoch milliseconds at which this session was first observed in
    /// a non-`running` state. `0` means "still running / not yet stamped."
    /// Set on exit/failure transitions and by `handleKill` when it flips
    /// status to `.killed`. Read by the auto-remove sweep to decide
    /// eligibility.
    terminal_at_ms: i64 = 0,

    /// True once the session has been unpublished from the registry maps
    /// (`hty delete` or the `--remove` sweep). The storage stays valid
    /// until the deferred-free phase, so parked waiters can observe the
    /// flag and resolve with a structured error instead of touching a
    /// freed session.
    doomed: bool = false,

    /// Server-side view of the PTY master fd's read state. `.open` while
    /// the loop should poll it for output; `.eof` after read returned
    /// 0/EIO (child gone or going — reap pending or done); `.broken`
    /// after an unexpected read error marked the session failed.
    pty_state: enum { open, eof, broken } = .open,

    /// Mouse-input mode flags inferred from the PTY output stream.
    /// Mutated by PTY output dispatch when raw bytes arrive; read by
    /// `handleSendMouse` (to gate on enable + pick an encoding) and by
    /// `handleSnapshot` (to expose the state to clients).
    mouse_state: MouseState = .{},

    log_file: ?sys.fd_t = null,

    /// Active `hty attach` clients subscribed to this session's output.
    /// Only ever touched from the server's event-loop thread (broadcasts,
    /// attach setup, reaping) — no lock needed.
    attach_clients: std.ArrayListUnmanaged(*AttachClient) = .empty,

    /// Input bytes accepted for the PTY that the master fd wouldn't take
    /// without blocking, waiting to be flushed on writability. Bounded by
    /// `max_pending_input_bytes`; overflow is dropped (a child that has
    /// stopped reading its tty with 64 KiB of unconsumed input is wedged
    /// anyway, and input must never stall the event loop).
    pending_input: std.ArrayListUnmanaged(u8) = .empty,

    pub fn getStatus(self: *const Session) SessionStatus {
        return self.status;
    }

    pub fn setStatus(self: *Session, new_status: SessionStatus) void {
        self.status = new_status;
    }

    pub fn getExitCode(self: *const Session) ?i32 {
        return self.exit_code;
    }

    pub fn setExitCode(self: *Session, code: ?i32) void {
        self.exit_code = code;
    }

    pub fn getLastScreenChange(self: *const Session) i64 {
        return self.last_screen_change_at_ms;
    }

    pub fn touchLastScreenChange(self: *Session, now_ms: i64) void {
        self.last_screen_change_at_ms = now_ms;
    }

    /// A successful resize repaints the screen, which historically
    /// emitted a screen_update event that reset the idle clock. Server
    /// terminals queue no events, so resize paths bump the stamp
    /// explicitly (gated the same way the event emission was).
    pub fn touchAfterResize(self: *Session) void {
        if (self.terminal.config.emit_screen_updates) {
            self.touchLastScreenChange(sys.milliTimestamp());
        }
    }

    /// Stamp `terminal_at_ms` the first time the session leaves the
    /// running state. Idempotent: subsequent calls are no-ops so the stamp
    /// records the first observed transition, not a later `hty kill`
    /// against an already-exited session.
    pub fn markTerminal(self: *Session, now_ms: i64) void {
        if (self.terminal_at_ms == 0) self.terminal_at_ms = now_ms;
    }

    pub fn getTerminalAt(self: *const Session) i64 {
        return self.terminal_at_ms;
    }

    /// True once the session has been unpublished from the registry and is
    /// awaiting the deferred free. Code holding the pointer may still
    /// touch the memory safely within the current iteration, but should
    /// treat the session as deleted for every observable purpose.
    pub fn isDoomed(self: *const Session) bool {
        return self.doomed;
    }

    /// Queue raw input bytes for the PTY. This is the single fan-in point
    /// for every input source (RPC `send_*` ops and attach `input` frames):
    /// whole frames are appended in call order, so concurrent clients
    /// interleave at frame granularity, never mid-frame. Bytes the master
    /// fd accepts immediately go straight out (the fd is non-blocking on
    /// the server path); the remainder lands in `pending_input`, flushed
    /// by the event loop on master-fd writability. When the buffer is at
    /// `max_pending_input_bytes` the frame is dropped without error — a
    /// wedged child must never stall or backpressure the server.
    ///
    /// Errors are real write failures (child gone, fd closed) observed
    /// while nothing was buffered; drops are silent by design.
    pub fn queueInput(self: *Session, bytes: []const u8) !void {
        self.flushPendingInput();
        var index: usize = 0;
        if (self.pending_input.items.len == 0) {
            while (index < bytes.len) {
                const n = sys.write(self.terminal.master_fd, bytes[index..]) catch |err| switch (err) {
                    error.WouldBlock => break,
                    else => return err,
                };
                if (n == 0) break;
                index += n;
            }
            if (index == bytes.len) return;
        }
        if (self.pending_input.items.len + (bytes.len - index) > max_pending_input_bytes) {
            std.log.debug("pending input full for session {s}; dropping {d} bytes", .{
                &self.id, bytes.len - index,
            });
            return;
        }
        self.pending_input.appendSlice(self.alloc, bytes[index..]) catch {
            // OOM: input is droppable by policy; never fail the caller
            // once part of the frame may already be on the wire.
        };
    }

    /// Write out as much queued input as the master fd accepts without
    /// blocking. Called by the event loop on POLLOUT (and from the drain
    /// step as a backstop). A real write error means the queued bytes can
    /// never be delivered (child gone) — the buffer is dropped so the
    /// loop stops arming write interest on a dead fd.
    pub fn flushPendingInput(self: *Session) void {
        const len = self.pending_input.items.len;
        if (len == 0) return;
        var written: usize = 0;
        while (written < len) {
            const n = sys.write(self.terminal.master_fd, self.pending_input.items[written..]) catch |err| switch (err) {
                error.WouldBlock => break,
                else => {
                    self.pending_input.clearRetainingCapacity();
                    return;
                },
            };
            if (n == 0) break;
            written += n;
        }
        if (written == 0) return;
        if (written < len) {
            std.mem.copyForwards(u8, self.pending_input.items[0 .. len - written], self.pending_input.items[written..]);
            self.pending_input.shrinkRetainingCapacity(len - written);
        } else {
            self.pending_input.clearRetainingCapacity();
        }
    }

    pub fn hasPendingInput(self: *const Session) bool {
        return self.pending_input.items.len != 0;
    }

    pub fn deinit(self: *Session) void {
        // Tear down any still-attached clients before freeing the session.
        // Emit a disconnect for each still-open client — this is our last
        // chance to bracket the attach in the log; the `disconnect_logged`
        // swap ensures we emit exactly once per connection. Clients owned
        // by an event-loop connection are only detached here (marked
        // closed, `session_gone` set so the loop never dereferences this
        // session again); the loop frees their storage when it reaps the
        // connection. Self-owned clients (tests, teardown paths without a
        // loop) are destroyed in place.
        const log_mod = @import("log.zig");
        const clients_snapshot = self.attach_clients.toOwnedSlice(self.alloc) catch &.{};
        for (clients_snapshot) |client| {
            client.shutdown();
            if (!client.disconnect_logged) {
                client.disconnect_logged = true;
                var arena_state = std.heap.ArenaAllocator.init(self.alloc);
                defer arena_state.deinit();
                log_mod.logAttachDisconnectEvent(arena_state.allocator(), self, client.client_id);
            }
            if (client.owned_by_conn) {
                client.session_gone = true;
            } else {
                client.deinit();
            }
        }
        if (clients_snapshot.len > 0) self.alloc.free(clients_snapshot);

        self.pending_input.deinit(self.alloc);

        if (self.log_file) |fd| {
            sys.close(fd);
            self.log_file = null;
        }
        self.terminal.deinit();
        self.alloc.free(self.program);
        self.alloc.free(self.args_joined);
        if (self.name) |name| self.alloc.free(name);
    }
};

/// Put an attach/watch socket into non-blocking mode. Broadcast writes
/// from the drain step must never block on a client that stopped reading.
/// The flag has to live on the fd itself: macOS ignores `MSG_DONTWAIT` on
/// UNIX-domain sockets, so per-call flags are not enough.
pub fn setStreamNonBlocking(fd: std.posix.socket_t) !void {
    const fl = try sys.fcntl(fd, std.posix.F.GETFL, 0);
    const nonblock: usize = @as(u32, @bitCast(std.posix.O{ .NONBLOCK = true }));
    _ = try sys.fcntl(fd, std.posix.F.SETFL, fl | nonblock);
}

/// One live `hty attach` connection's broadcast subscription. PTY output
/// dispatch broadcasts raw bytes to each attach_client on the owning
/// session through the client's bounded outbound buffer; inbound frames
/// are parsed by the event loop's connection state machine (there is no
/// per-client reader thread).
pub const AttachClient = struct {
    /// Upper bound on bytes buffered for a client whose socket would block.
    /// 1 MiB is generous — a full-screen ANSI frame is a few hundred KB at
    /// worst — while bounding per-client memory. This is the same bound and
    /// policy as the loop's per-connection outbound buffer: a client that
    /// falls further behind is dropped (marked closed and reaped, with an
    /// `attach_disconnect` logged). Observers never get to stall the server
    /// or backpressure the PTY.
    pub const max_pending_bytes: usize = 1 << 20;

    alloc: Allocator,
    session: *Session,
    stream: sys.Stream,
    /// Outbound bytes the socket wouldn't accept without blocking, waiting
    /// to be flushed on POLLOUT (or the next write attempt / drain tick).
    /// Bounded by `max_pending_bytes`.
    pending: std.ArrayListUnmanaged(u8) = .empty,
    /// Opaque, self-describing id assigned by the server on accept. Appears
    /// in the session log in `attach_connect`, `attach_disconnect`, and
    /// `input` events whose origin is `"attach"`, so forensics can pair
    /// connects with disconnects even when multiple clients overlap.
    /// Format: `attach-<uuidv7>`. Owned by this struct; freed on deinit.
    client_id: []u8,
    closed: bool = false,
    /// Set true once the `attach_disconnect` log event has been emitted.
    /// Used to avoid double-emitting when both the loop's reap path and
    /// the session-deinit path run on the same client.
    disconnect_logged: bool = false,
    /// If true, the client is a `hty watch` subscriber: it sits on the
    /// same broadcast list as a full attach client, receives the same
    /// initial snapshot and live output/exit frames, but any `input` /
    /// `resize` frames it sends are silently dropped by the server-side
    /// frame dispatch. This lets watch piggyback on attach's broadcast
    /// infrastructure with one flag rather than a parallel subscriber
    /// list. See LatentEvals/hty#29.
    read_only: bool = false,
    /// True when an event-loop connection owns this client's lifecycle
    /// (socket close + storage free happen when the loop reaps the conn).
    /// False for clients constructed directly (tests / loop-less paths),
    /// which are destroyed by `reapClosedAttachClients` or session deinit.
    owned_by_conn: bool = false,
    /// Set by `Session.deinit` when the owning session is torn down while
    /// a loop connection still references this client. Tells the loop's
    /// reap path that `session` is dangling and must not be dereferenced.
    session_gone: bool = false,

    pub fn isClosed(self: *const AttachClient) bool {
        return self.closed;
    }

    pub fn shutdown(self: *AttachClient) void {
        if (self.closed) return;
        self.closed = true;
        // Shutting down the socket makes the peer see EOF promptly; the
        // loop (or reaper) frees the client on its next pass.
        sys.shutdown(self.stream.handle, .both) catch {};
    }

    /// Best-effort, non-blocking write of a pre-framed JSONL line (with
    /// trailing '\n'). Bytes the socket won't accept right now are queued
    /// in `pending` (flushed on POLLOUT or the next write). Never blocks:
    /// a stalled reader must not be able to wedge the server. Marks the
    /// client closed — so the broadcaster drops it on the next pass — on
    /// any real write error or when `pending` would exceed
    /// `max_pending_bytes`.
    pub fn tryWriteFrame(self: *AttachClient, frame: []const u8) bool {
        if (self.isClosed()) return false;
        // Anything already queued must go out before this frame so the
        // client sees frames in broadcast order.
        if (!self.flushPendingInner()) return false;
        var sent: usize = 0;
        if (self.pending.items.len == 0) {
            sent = self.sendNonBlocking(frame) orelse return false;
        }
        if (sent < frame.len) return self.queuePending(frame[sent..]);
        return true;
    }

    /// Give this client a chance to drain its pending buffer. Called on
    /// POLLOUT (and from the in-process pump) so a client that stalled
    /// during a burst catches back up even when the session emits no
    /// further output.
    pub fn flushPending(self: *AttachClient) void {
        if (self.isClosed()) return;
        _ = self.flushPendingInner();
    }

    /// Returns false if the client got marked closed by a write error.
    fn flushPendingInner(self: *AttachClient) bool {
        const len = self.pending.items.len;
        if (len == 0) return true;
        const n = self.sendNonBlocking(self.pending.items) orelse return false;
        if (n == 0) return true;
        if (n < len) {
            std.mem.copyForwards(u8, self.pending.items[0 .. len - n], self.pending.items[n..]);
            self.pending.shrinkRetainingCapacity(len - n);
        } else {
            self.pending.clearRetainingCapacity();
        }
        return true;
    }

    /// The socket is in non-blocking mode (`setStreamNonBlocking`, done at
    /// attach setup) so a full socket buffer surfaces as `error.WouldBlock`
    /// instead of stalling; the MSG_DONTWAIT flag is belt-and-braces for
    /// platforms that honor it. Returns the byte count the kernel accepted
    /// (0 when the buffer is full), or null after marking the client
    /// closed on any real error.
    fn sendNonBlocking(self: *AttachClient, bytes: []const u8) ?usize {
        var written: usize = 0;
        while (written < bytes.len) {
            const n = sys.send(
                self.stream.handle,
                bytes[written..],
                std.posix.MSG.DONTWAIT,
            ) catch |err| switch (err) {
                error.WouldBlock => return written,
                else => {
                    self.closed = true;
                    return null;
                },
            };
            if (n == 0) break;
            written += n;
        }
        return written;
    }

    /// Queue leftover bytes for a later flush; a client too far behind
    /// (`max_pending_bytes`) is marked closed and dropped instead of
    /// buffered without bound.
    fn queuePending(self: *AttachClient, bytes: []const u8) bool {
        if (self.pending.items.len + bytes.len > max_pending_bytes) {
            self.closed = true;
            return false;
        }
        self.pending.appendSlice(self.alloc, bytes) catch {
            self.closed = true;
            return false;
        };
        return true;
    }

    /// Full teardown for self-owned clients: closes the socket and frees
    /// all storage. Conn-owned clients must use `deinitDetached` instead —
    /// the loop's connection owns (and closes) the fd.
    pub fn deinit(self: *AttachClient) void {
        self.shutdown();
        self.stream.close();
        self.pending.deinit(self.alloc);
        self.alloc.free(self.client_id);
        self.alloc.destroy(self);
    }

    /// Free storage without touching the stream (the event-loop connection
    /// owns the fd and closes it during conn teardown).
    pub fn deinitDetached(self: *AttachClient) void {
        self.pending.deinit(self.alloc);
        self.alloc.free(self.client_id);
        self.alloc.destroy(self);
    }
};
