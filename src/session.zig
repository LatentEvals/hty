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

    pub fn deinit(self: *Session) void {
        // Tear down any still-attached clients before freeing the session.
        // Takes the mutex just to be safe against a rogue late broadcast.
        self.attach_mutex.lock();
        for (self.attach_clients.items) |client| {
            client.shutdown();
        }
        const clients_snapshot = self.attach_clients.toOwnedSlice(self.alloc) catch &.{};
        self.attach_mutex.unlock();
        for (clients_snapshot) |client| client.deinit();
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

/// One live `hty attach` connection. The main accept loop's drain step
/// broadcasts raw PTY bytes to each attach_client on the owning session;
/// a per-client reader thread reads input frames from the socket and
/// forwards them back into the session's terminal.
pub const AttachClient = struct {
    alloc: Allocator,
    session: *Session,
    stream: std.net.Stream,
    write_mutex: std.Thread.Mutex = .{},
    closed: std.atomic.Value(bool) = .init(false),
    reader_thread: ?std.Thread = null,

    pub fn isClosed(self: *const AttachClient) bool {
        return self.closed.load(.acquire);
    }

    pub fn shutdown(self: *AttachClient) void {
        if (self.closed.swap(true, .acq_rel)) return;
        // Shutting down the socket unblocks any in-flight read() on the
        // reader thread so it can exit cleanly.
        std.posix.shutdown(self.stream.handle, .both) catch {};
    }

    /// Best-effort write of a pre-framed JSONL line (with trailing '\n').
    /// Marks the client closed on any write error so the broadcaster
    /// will drop it on the next pass.
    pub fn tryWriteFrame(self: *AttachClient, frame: []const u8) bool {
        if (self.isClosed()) return false;
        self.write_mutex.lock();
        defer self.write_mutex.unlock();
        self.stream.writeAll(frame) catch {
            _ = self.closed.store(true, .release);
            return false;
        };
        return true;
    }

    pub fn deinit(self: *AttachClient) void {
        self.shutdown();
        if (self.reader_thread) |t| t.join();
        self.stream.close();
        self.alloc.destroy(self);
    }
};
