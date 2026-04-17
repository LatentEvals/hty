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

/// Optional configuration for the server accept loop. Production uses the
/// defaults; tests pass a short `empty_grace_ms` and/or a `stop_signal`
/// they can flip externally so the loop exits promptly.
pub const RunOpts = struct {
    empty_grace_ms: i64 = empty_grace_ms,
    /// If non-null, the accept loop returns as soon as it observes this
    /// flag set to true (and after joining in-flight workers).
    stop_signal: ?*std.atomic.Value(bool) = null,
};

/// One in-flight RPC connection owned by a worker thread. The accept loop
/// spawns one of these per accept; the worker runs `workerMain`, which
/// dispatches the request and then marks `done` so the accept loop reaps
/// and joins the thread on its next sweep.
const Worker = struct {
    alloc: Allocator,
    registry: *SessionRegistry,
    conn: std.net.Server.Connection,
    thread: ?std.Thread = null,
    done: std.atomic.Value(bool) = .init(false),
};

fn workerMain(worker: *Worker) void {
    defer worker.done.store(true, .release);
    const result = handleConnection(worker.alloc, worker.registry, &worker.conn) catch |err| blk: {
        std.debug.print("request failed: {s}\n", .{@errorName(err)});
        break :blk ConnectionResult.done;
    };
    switch (result) {
        .done => worker.conn.stream.close(),
        .attached => {}, // The attach reader thread now owns the stream.
    }
}

/// Shared state between the accept loop and in-flight worker threads.
/// `mutex` protects `workers` against concurrent append (new accept) and
/// swapRemove (sweep after a worker signals done).
const WorkerPool = struct {
    alloc: Allocator,
    mutex: std.Thread.Mutex = .{},
    workers: std.ArrayListUnmanaged(*Worker) = .{},

    fn init(alloc: Allocator) WorkerPool {
        return .{ .alloc = alloc };
    }

    fn spawn(self: *WorkerPool, registry: *SessionRegistry, conn: std.net.Server.Connection) !void {
        const worker = try self.alloc.create(Worker);
        errdefer self.alloc.destroy(worker);
        worker.* = .{ .alloc = self.alloc, .registry = registry, .conn = conn };

        self.mutex.lock();
        defer self.mutex.unlock();
        try self.workers.append(self.alloc, worker);
        worker.thread = try std.Thread.spawn(.{}, workerMain, .{worker});
    }

    /// Join any workers that have signalled `done`. Called periodically
    /// from the accept loop so completed threads don't accumulate.
    fn sweep(self: *WorkerPool) void {
        self.mutex.lock();
        var joined: std.ArrayListUnmanaged(*Worker) = .{};
        defer joined.deinit(self.alloc);

        var i: usize = 0;
        while (i < self.workers.items.len) {
            const w = self.workers.items[i];
            if (w.done.load(.acquire)) {
                _ = self.workers.swapRemove(i);
                joined.append(self.alloc, w) catch {};
                continue;
            }
            i += 1;
        }
        self.mutex.unlock();

        // Join and free outside the lock so a slow join can't stall new
        // accepts that want to register their own worker.
        for (joined.items) |w| {
            if (w.thread) |t| t.join();
            self.alloc.destroy(w);
        }
    }

    /// Drain all outstanding workers on shutdown. Each worker's RPC is
    /// bounded by the protocol's timeouts (longest is `wait_for_*` at 10s
    /// default, but most are <25ms). After this returns, no RPC workers
    /// are still touching the registry.
    fn joinAll(self: *WorkerPool) void {
        self.mutex.lock();
        const remaining = self.workers.toOwnedSlice(self.alloc) catch &.{};
        self.mutex.unlock();
        defer if (remaining.len > 0) self.alloc.free(remaining);

        for (remaining) |w| {
            if (w.thread) |t| t.join();
            self.alloc.destroy(w);
        }
    }

    fn outstanding(self: *WorkerPool) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.workers.items.len;
    }
};

pub fn runServer(alloc: Allocator, socket_path: []const u8) !void {
    return runServerWithOpts(alloc, socket_path, .{});
}

pub fn runServerWithOpts(alloc: Allocator, socket_path: []const u8, opts: RunOpts) !void {
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

    var pool = WorkerPool.init(alloc);
    // Drain workers before tearing down the registry they might still
    // reference. Ordering: workers first, registry second (reverse of init).
    defer pool.joinAll();

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
    // zero running sessions AND no worker threads are still mid-RPC, we note
    // the timestamp; if we sit there for `empty_grace_ms` without new work,
    // exit the server. A new session or a new RPC clears the timer.
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
        // traffic driving it. This is the only drain caller now — wait
        // handlers used to call drainAll themselves but moved to pure
        // read-only polling when the server became multi-threaded.
        registry.drainAll();

        // Reap any workers that finished their RPC since the last tick.
        pool.sweep();

        if (ready > 0 and (poll_fds[0].revents & std.posix.POLL.IN) != 0) {
            const conn = server.accept() catch |err| {
                std.debug.print("accept failed: {s}\n", .{@errorName(err)});
                continue;
            };
            pool.spawn(&registry, conn) catch |err| {
                std.debug.print("worker spawn failed: {s}\n", .{@errorName(err)});
                conn.stream.close();
            };
        }

        // External stop signal (test harness) wins over the empty timer.
        if (opts.stop_signal) |flag| {
            if (flag.load(.acquire)) return;
        }

        // Update the empty-tracking timer based on the post-tick state.
        // Zombie (exited) sessions don't count — we only care whether
        // there's any _running_ process we'd be cutting off. In-flight
        // workers also gate the timer: we won't initiate shutdown while
        // a wait_for_* or other long RPC is mid-flight.
        const active = registry.activeCount();
        const busy = pool.outstanding();
        if (active > 0 or busy > 0) {
            empty_since_ms = null;
        } else if (empty_since_ms == null) {
            empty_since_ms = std.time.milliTimestamp();
        }

        if (empty_since_ms) |since| {
            if (std.time.milliTimestamp() - since >= opts.empty_grace_ms) return;
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

    // Peek at the op without consuming arena state; attach and watch
    // need a different lifecycle (keep the connection open, spawn a
    // reader thread) so we branch here before the normal RPC dispatch.
    // Watch is the read-only variant; both share handleAttachConnection.
    switch (detectAttachOp(alloc, line)) {
        .attach => return handleAttachConnection(alloc, registry, conn, line, false),
        .watch => return handleAttachConnection(alloc, registry, conn, line, true),
        .none => {},
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
    if (std.mem.eql(u8, op, "info")) return ops.handleInfo(arena, registry, id);

    // Validate the op before touching the session registry so unknown ops
    // surface as UnknownOperation rather than SessionNotFound.
    // Note: `info` and `list` are dispatched above (no session needed), so
    // they're not in this list.
    const known_ops = [_][]const u8{
        "snapshot",      "send_text",         "send_key",      "send_bytes_hex",
        "send_mouse",
        "resize",        "wait_for_text",     "wait_for_idle", "wait_for_exit",
        "kill",          "delete",            "wait_and_snapshot",
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
    if (std.mem.eql(u8, op, "send_mouse")) return ops.handleSendMouse(arena, sess, object, id);
    if (std.mem.eql(u8, op, "resize")) return ops.handleResize(arena, sess, object, id);
    if (std.mem.eql(u8, op, "wait_for_text")) return ops.handleWaitForText(arena, registry, sess, object, id);
    if (std.mem.eql(u8, op, "wait_for_idle")) return ops.handleWaitForIdle(arena, registry, sess, object, id);
    if (std.mem.eql(u8, op, "wait_for_exit")) return ops.handleWaitForExit(arena, registry, sess, object, id);
    if (std.mem.eql(u8, op, "kill")) return ops.handleKill(arena, registry, sess, id);
    if (std.mem.eql(u8, op, "delete")) return ops.handleDelete(arena, registry, sess, id);
    if (std.mem.eql(u8, op, "wait_and_snapshot")) return ops.handleWaitAndSnapshot(arena, registry, sess, object, id);

    return error.UnknownOperation;
}
