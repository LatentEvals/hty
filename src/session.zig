//! Session + AttachClient + SessionStatus.
//!
//! These types are bundled in one file because Session owns a list of
//! `*AttachClient` and AttachClient holds a `*Session`. Splitting them would
//! create a circular import that Zig can technically express via opaque
//! pointers but would only obscure the fact that they're a single tightly-
//! coupled concept: a PTY-backed session and the live connections observing
//! it.

const std = @import("std");
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
/// Readers touch each field through atomics (acquire load), writers update
/// with release store from inside `drainAll` under `registry.mutex`. No
/// session-local lock exists for mouse state — the atomics are enough
/// since each field is independent and a torn read across fields is
/// harmless (the client would just see a momentarily-stale combination
/// on the next snapshot).
pub const MouseState = struct {
    /// `CSI ?1000` — button-event mode (press/release only, no motion).
    x10: std.atomic.Value(bool),
    /// `CSI ?1002` — button-event + drag motion while pressed.
    button_event: std.atomic.Value(bool),
    /// `CSI ?1003` — any-event motion (even without a button pressed).
    any_event: std.atomic.Value(bool),
    /// `CSI ?1006` — SGR extended encoding. Independent of the event
    /// mode — apps typically enable 1000/1002/1003 *and* 1006 together.
    sgr: std.atomic.Value(bool),

    pub fn init() MouseState {
        return .{
            .x10 = .init(false),
            .button_event = .init(false),
            .any_event = .init(false),
            .sgr = .init(false),
        };
    }

    /// True if any event-set mode is on (1000/1002/1003). This is the
    /// gate `send --click` checks.
    pub fn isEnabled(self: *const MouseState) bool {
        return self.x10.load(.acquire) or
            self.button_event.load(.acquire) or
            self.any_event.load(.acquire);
    }

    /// Snapshot all four flags to a plain struct for serialization.
    pub fn snapshot(self: *const MouseState) MouseStateSnapshot {
        return .{
            .x10 = self.x10.load(.acquire),
            .button_event = self.button_event.load(.acquire),
            .any_event = self.any_event.load(.acquire),
            .sgr = self.sgr.load(.acquire),
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
/// up by the next raw_bytes drain event on the following drainAll pass.
/// In practice apps emit the toggle as one write, so a split is rare.
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
                1000 => mouse.x10.store(enable, .release),
                1002 => mouse.button_event.store(enable, .release),
                1003 => mouse.any_event.store(enable, .release),
                1006 => mouse.sgr.store(enable, .release),
                else => {},
            }
        }
        i = p + 1;
    }
}

test "applyMouseModeTogglesFromOutput: enable 1000 + 1006" {
    var m = MouseState.init();
    applyMouseModeTogglesFromOutput(&m, "\x1b[?1000h\x1b[?1006h");
    try std.testing.expect(m.x10.load(.acquire));
    try std.testing.expect(m.sgr.load(.acquire));
    try std.testing.expect(!m.button_event.load(.acquire));
}

test "applyMouseModeTogglesFromOutput: disable 1002" {
    var m = MouseState.init();
    m.button_event.store(true, .release);
    applyMouseModeTogglesFromOutput(&m, "junk \x1b[?1002l tail");
    try std.testing.expect(!m.button_event.load(.acquire));
}

test "applyMouseModeTogglesFromOutput: combined params" {
    var m = MouseState.init();
    applyMouseModeTogglesFromOutput(&m, "\x1b[?1002;1006h");
    try std.testing.expect(m.button_event.load(.acquire));
    try std.testing.expect(m.sgr.load(.acquire));
}

test "applyMouseModeTogglesFromOutput: 1015 is ignored" {
    var m = MouseState.init();
    applyMouseModeTogglesFromOutput(&m, "\x1b[?1015h");
    try std.testing.expect(!m.x10.load(.acquire));
    try std.testing.expect(!m.sgr.load(.acquire));
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
    /// Sentinel for "exit code not set" inside the atomic storage. POSIX
    /// exit codes are 0-255 and the session's own status atomic tells the
    /// reader whether the code is meaningful at all, so using INT_MIN here
    /// is only a defence-in-depth if someone reads exit_code directly
    /// without checking status first.
    pub const no_exit_code: i32 = std.math.minInt(i32);

    alloc: Allocator,
    id: [36]u8,
    name: ?[]u8,
    terminal: *hty.InteractiveTerminal,
    program: []u8,
    args_joined: []u8,
    created_at_ms: i64,

    /// Lifecycle fields mutated by the server's drain loop (accept thread)
    /// and read by worker threads running wait / snapshot handlers. Stored
    /// as atomics so readers don't need to hold a lock while polling.
    /// Writers use release ordering; readers use acquire. When `status`
    /// transitions to a terminal state, `exit_code` must be written first
    /// so the release-acquire pair publishes both together.
    last_screen_change_at_ms_atomic: std.atomic.Value(i64),
    status_atomic: std.atomic.Value(u8),
    exit_code_atomic: std.atomic.Value(i32),

    /// When true, the registry automatically removes this session once the
    /// child process exits (success, failure, signal, or `hty kill`).
    /// Opt-in via `hty run --remove`. The auto-removal path in
    /// `SessionRegistry.drainAll` treats this identically to `hty delete`
    /// — same teardown, same filesystem cleanup. In-flight wait/snapshot
    /// handlers are protected by the refcount (`ref_count` below), not by
    /// timing: removal unpublishes the session immediately and the last
    /// borrow holder frees it.
    remove_on_exit: bool = false,
    /// Unix-epoch milliseconds at which this session was first observed in
    /// a non-`running` state. `0` means "still running / not yet stamped."
    /// Set by the drain loop on exit/failure transitions and by
    /// `handleKill` when it flips status to `.killed`. Read by the drain
    /// loop's auto-remove sweep to decide eligibility.
    terminal_at_ms_atomic: std.atomic.Value(i64) = .init(0),

    /// Number of live borrows of this session pointer held by in-flight
    /// handlers (RPC workers, attach setup). Guarded by
    /// `SessionRegistry.mutex`: incremented by the registry's resolve
    /// paths, decremented by `SessionRegistry.release`. When the count
    /// drops to zero and `doomed_atomic` is set, the releaser frees the
    /// session — ownership, not timing, decides the lifetime.
    ref_count: u32 = 0,
    /// Set (under `SessionRegistry.mutex`) when the session has been
    /// unpublished from the registry maps (`hty delete` or the `--remove`
    /// sweep) but destruction is deferred because handlers still hold
    /// borrows. Stored as an atomic so wait loops can check it lock-free
    /// between polls and bail out instead of running to their timeout
    /// against a deleted session.
    doomed_atomic: std.atomic.Value(bool) = .init(false),

    /// Mouse-input mode flags inferred from the PTY output stream.
    /// Mutated from `drainAll` when raw_bytes events arrive; read by
    /// `handleSendMouse` (to gate on enable + pick an encoding) and by
    /// `handleSnapshot` (to expose the state to clients).
    mouse_state: MouseState = .{
        .x10 = .{ .raw = false },
        .button_event = .{ .raw = false },
        .any_event = .{ .raw = false },
        .sgr = .{ .raw = false },
    },

    log_file: ?std.fs.File = null,
    /// Serializes writes to `log_file`. Held by every log helper in `log.zig`
    /// since multiple threads (drain, attach reader, RPC workers) call into
    /// the log writers concurrently once the server becomes multi-threaded.
    log_mutex: std.Thread.Mutex = .{},

    /// Active `hty attach` clients subscribed to this session's output.
    attach_clients: std.ArrayListUnmanaged(*AttachClient) = .{},
    /// Protects attach_clients against concurrent broadcast and remove.
    attach_mutex: std.Thread.Mutex = .{},

    pub fn initAtomics(now_ms: i64) struct {
        last_screen_change_at_ms_atomic: std.atomic.Value(i64),
        status_atomic: std.atomic.Value(u8),
        exit_code_atomic: std.atomic.Value(i32),
    } {
        return .{
            .last_screen_change_at_ms_atomic = .init(now_ms),
            .status_atomic = .init(@intFromEnum(SessionStatus.running)),
            .exit_code_atomic = .init(no_exit_code),
        };
    }

    pub fn getStatus(self: *const Session) SessionStatus {
        return @enumFromInt(self.status_atomic.load(.acquire));
    }

    pub fn setStatus(self: *Session, new_status: SessionStatus) void {
        self.status_atomic.store(@intFromEnum(new_status), .release);
    }

    pub fn getExitCode(self: *const Session) ?i32 {
        const v = self.exit_code_atomic.load(.acquire);
        return if (v == no_exit_code) null else v;
    }

    /// Set the exit code. The caller must set `status` to a non-running
    /// value afterwards (the status store is the release barrier that
    /// publishes the code to readers).
    pub fn setExitCode(self: *Session, code: i32) void {
        self.exit_code_atomic.store(code, .release);
    }

    pub fn getLastScreenChange(self: *const Session) i64 {
        return self.last_screen_change_at_ms_atomic.load(.acquire);
    }

    pub fn touchLastScreenChange(self: *Session, now_ms: i64) void {
        self.last_screen_change_at_ms_atomic.store(now_ms, .release);
    }

    /// Stamp `terminal_at_ms_atomic` the first time the session leaves the
    /// running state. Idempotent: subsequent calls are no-ops so the stamp
    /// records the first observed transition, not a later `hty kill`
    /// racing against an already-exited session.
    pub fn markTerminal(self: *Session, now_ms: i64) void {
        _ = self.terminal_at_ms_atomic.cmpxchgStrong(0, now_ms, .release, .monotonic);
    }

    pub fn getTerminalAt(self: *const Session) i64 {
        return self.terminal_at_ms_atomic.load(.acquire);
    }

    /// True once the session has been unpublished from the registry and is
    /// awaiting its last borrow release. Handlers holding a borrow may
    /// still touch the memory safely, but should treat the session as
    /// deleted for every observable purpose.
    pub fn isDoomed(self: *const Session) bool {
        return self.doomed_atomic.load(.acquire);
    }

    pub fn deinit(self: *Session) void {
        // Tear down any still-attached clients before freeing the session.
        // Takes the mutex just to be safe against a rogue late broadcast.
        // Emit a disconnect for each still-open client before its storage
        // goes away — this is our last chance to bracket the attach in the
        // log. The reader-thread-exit path may have also flipped the
        // `disconnect_logged` flag; the atomic swap ensures we emit
        // exactly once per connection.
        const log_mod = @import("log.zig");
        self.attach_mutex.lock();
        for (self.attach_clients.items) |client| {
            client.shutdown();
        }
        const clients_snapshot = self.attach_clients.toOwnedSlice(self.alloc) catch &.{};
        self.attach_mutex.unlock();
        for (clients_snapshot) |client| {
            if (!client.disconnect_logged.swap(true, .acq_rel)) {
                var arena_state = std.heap.ArenaAllocator.init(self.alloc);
                defer arena_state.deinit();
                log_mod.logAttachDisconnectEvent(arena_state.allocator(), self, client.client_id);
            }
            client.deinit();
        }
        if (clients_snapshot.len > 0) self.alloc.free(clients_snapshot);

        if (self.log_file) |*f| {
            f.close();
            self.log_file = null;
        }
        self.terminal.deinit();
        self.alloc.free(self.program);
        self.alloc.free(self.args_joined);
        if (self.name) |name| self.alloc.free(name);
    }
};

/// Put an attach/watch socket into non-blocking mode. Broadcast writes
/// from the drain step (which holds `registry.mutex`) must never block on
/// a client that stopped reading. The flag has to live on the fd itself:
/// macOS ignores `MSG_DONTWAIT` on UNIX-domain sockets, so per-call flags
/// are not enough. The attach reader loop compensates by blocking in
/// `poll` instead of `read` (see `server_attach.attachReaderLoop`).
pub fn setStreamNonBlocking(fd: std.posix.socket_t) !void {
    const fl = try std.posix.fcntl(fd, std.posix.F.GETFL, 0);
    const nonblock: usize = @as(u32, @bitCast(std.posix.O{ .NONBLOCK = true }));
    _ = try std.posix.fcntl(fd, std.posix.F.SETFL, fl | nonblock);
}

/// One live `hty attach` connection. The main accept loop's drain step
/// broadcasts raw PTY bytes to each attach_client on the owning session;
/// a per-client reader thread reads input frames from the socket and
/// forwards them back into the session's terminal.
pub const AttachClient = struct {
    /// Upper bound on bytes buffered for a client whose socket would block.
    /// 1 MiB is generous — a full-screen ANSI frame is a few hundred KB at
    /// worst — while bounding per-client memory. A client that falls further
    /// behind is dropped (marked closed and reaped on the next drain pass):
    /// drop-and-disconnect is the policy; observers never get to stall the
    /// server or backpressure the PTY.
    pub const max_pending_bytes: usize = 1 << 20;

    alloc: Allocator,
    session: *Session,
    stream: std.net.Stream,
    /// Outbound bytes the socket wouldn't accept without blocking, waiting
    /// to be flushed by the next write attempt or drain tick. Guarded by
    /// `write_mutex`. Bounded by `max_pending_bytes`.
    pending: std.ArrayListUnmanaged(u8) = .{},
    /// Opaque, self-describing id assigned by the server on accept. Appears
    /// in the session log in `attach_connect`, `attach_disconnect`, and
    /// `input` events whose origin is `"attach"`, so forensics can pair
    /// connects with disconnects even when multiple clients overlap.
    /// Format: `attach-<uuidv7>`. Owned by this struct; freed on deinit.
    client_id: []u8,
    write_mutex: std.Thread.Mutex = .{},
    closed: std.atomic.Value(bool) = .init(false),
    /// Set true once the `attach_disconnect` log event has been emitted.
    /// Used by the reaper path to avoid double-emitting if both the
    /// reader-thread-exit path and the session-deinit path run on the
    /// same client.
    disconnect_logged: std.atomic.Value(bool) = .init(false),
    reader_thread: ?std.Thread = null,
    /// If true, the client is a `hty watch` subscriber: it sits on the
    /// same broadcast list as a full attach client, receives the same
    /// initial snapshot and live output/exit frames, but any `input` /
    /// `resize` frames it sends are silently dropped by the server-side
    /// reader loop. This lets watch piggyback on attach's broadcast
    /// infrastructure with one flag rather than a parallel subscriber
    /// list. See LatentEvals/hty#29.
    read_only: bool = false,

    pub fn isClosed(self: *const AttachClient) bool {
        return self.closed.load(.acquire);
    }

    pub fn shutdown(self: *AttachClient) void {
        if (self.closed.swap(true, .acq_rel)) return;
        // Shutting down the socket unblocks any in-flight read() on the
        // reader thread so it can exit cleanly.
        std.posix.shutdown(self.stream.handle, .both) catch {};
    }

    /// Best-effort, non-blocking write of a pre-framed JSONL line (with
    /// trailing '\n'). Bytes the socket won't accept right now are queued
    /// in `pending` (flushed on the next write or drain tick). Never blocks:
    /// this runs from the drain step while `registry.mutex` is held, so a
    /// stalled reader must not be able to wedge the server. Marks the
    /// client closed — so the broadcaster drops it on the next pass — on
    /// any real write error or when `pending` would exceed
    /// `max_pending_bytes`.
    pub fn tryWriteFrame(self: *AttachClient, frame: []const u8) bool {
        if (self.isClosed()) return false;
        self.write_mutex.lock();
        defer self.write_mutex.unlock();
        // Anything already queued must go out before this frame so the
        // client sees frames in broadcast order.
        if (!self.flushPendingLocked()) return false;
        var sent: usize = 0;
        if (self.pending.items.len == 0) {
            sent = self.sendNonBlockingLocked(frame) orelse return false;
        }
        if (sent < frame.len) return self.queuePendingLocked(frame[sent..]);
        return true;
    }

    /// Give this client a chance to drain its pending buffer. Called once
    /// per drain tick so a client that stalled during a burst catches back
    /// up even when the session emits no further output.
    pub fn flushPending(self: *AttachClient) void {
        if (self.isClosed()) return;
        self.write_mutex.lock();
        defer self.write_mutex.unlock();
        _ = self.flushPendingLocked();
    }

    /// Caller holds `write_mutex`. Returns false if the client got marked
    /// closed by a write error.
    fn flushPendingLocked(self: *AttachClient) bool {
        const len = self.pending.items.len;
        if (len == 0) return true;
        const n = self.sendNonBlockingLocked(self.pending.items) orelse return false;
        if (n == 0) return true;
        if (n < len) {
            std.mem.copyForwards(u8, self.pending.items[0 .. len - n], self.pending.items[n..]);
            self.pending.shrinkRetainingCapacity(len - n);
        } else {
            self.pending.clearRetainingCapacity();
        }
        return true;
    }

    /// Caller holds `write_mutex`. The socket is in non-blocking mode
    /// (`setStreamNonBlocking`, done at attach setup) so a full socket
    /// buffer surfaces as `error.WouldBlock` instead of stalling; the
    /// MSG_DONTWAIT flag is belt-and-braces for platforms that honor it.
    /// Returns the byte count the kernel accepted (0 when the buffer is
    /// full), or null after marking the client closed on any real error.
    fn sendNonBlockingLocked(self: *AttachClient, bytes: []const u8) ?usize {
        var written: usize = 0;
        while (written < bytes.len) {
            const n = std.posix.send(
                self.stream.handle,
                bytes[written..],
                std.posix.MSG.DONTWAIT,
            ) catch |err| switch (err) {
                error.WouldBlock => return written,
                else => {
                    self.closed.store(true, .release);
                    return null;
                },
            };
            if (n == 0) break;
            written += n;
        }
        return written;
    }

    /// Caller holds `write_mutex`. Queue leftover bytes for a later flush;
    /// a client too far behind (`max_pending_bytes`) is marked closed and
    /// dropped instead of buffered without bound.
    fn queuePendingLocked(self: *AttachClient, bytes: []const u8) bool {
        if (self.pending.items.len + bytes.len > max_pending_bytes) {
            self.closed.store(true, .release);
            return false;
        }
        self.pending.appendSlice(self.alloc, bytes) catch {
            self.closed.store(true, .release);
            return false;
        };
        return true;
    }

    pub fn deinit(self: *AttachClient) void {
        self.shutdown();
        if (self.reader_thread) |t| t.join();
        self.stream.close();
        self.pending.deinit(self.alloc);
        self.alloc.free(self.client_id);
        self.alloc.destroy(self);
    }
};
