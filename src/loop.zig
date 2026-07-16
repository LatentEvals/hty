//! Event-loop readiness and timer core.
//!
//! Pure mechanics for the single-threaded server event loop: a pollfd-set
//! builder with per-fd interest flags (`Loop`), a sorted deadline table
//! (`DeadlineTable`), and the timeout math that connects the two
//! (`nextTimeoutMs`). The module ships dark — no server integration yet —
//! and everything here is unit-testable without sockets.
//!
//! Two design decisions are settled and load-bearing:
//!
//! - **poll(2) only.** There is no kqueue/epoll backend. On macOS, kqueue
//!   cannot reliably monitor PTY master fds (EVFILT_READ on the master
//!   side of a pty does not fire — the long-standing Darwin limitation
//!   that forces libuv into a select-thread fallback for TTYs), and PTY
//!   masters are the highest-value fds in this loop. `poll` handles PTYs,
//!   Unix sockets, and pipes uniformly on both macOS and Linux, so one
//!   code path serves both targets.
//! - **Rebuild per iteration.** `waitReady` rebuilds the pollfd array from
//!   the registration table on every call instead of maintaining a
//!   kernel-side interest set incrementally. O(n fds) per wakeup is
//!   accepted: the design center is well under 100 fds (≤ ~16 sessions +
//!   ≤ ~32 clients), where rebuilding a small array is noise. The
//!   interface (`registerFd`/`armWrite`/`waitReady`) hides the mechanism,
//!   so a platform-specific backend could be slotted in later without
//!   touching dispatch code — but none ships.

const std = @import("std");
const posix = std.posix;
const Allocator = std.mem.Allocator;

/// Readiness interest for a registered fd. `read` maps to POLLIN,
/// `write` to POLLOUT.
pub const Interest = struct {
    read: bool = true,
    write: bool = false,
};

/// One ready fd yielded by `ReadyIter`: the fd plus the raw `revents`
/// bits reported by poll(2) (test against `std.posix.POLL.*`).
pub const Ready = struct {
    fd: posix.fd_t,
    revents: i16,
};

/// Iterator over the fds that reported readiness in the last
/// `Loop.waitReady` call. Entries with `revents == 0` are skipped.
///
/// The iterator borrows the loop's internal pollfd array; it is valid
/// until the next `waitReady`/`buildPollSet` call on the same loop.
pub const ReadyIter = struct {
    pollfds: []const posix.pollfd,
    index: usize = 0,

    pub fn next(self: *ReadyIter) ?Ready {
        while (self.index < self.pollfds.len) {
            const entry = self.pollfds[self.index];
            self.index += 1;
            if (entry.revents != 0) {
                return .{ .fd = entry.fd, .revents = entry.revents };
            }
        }
        return null;
    }
};

/// The readiness half of the event loop: a registration table of fds and
/// their interest flags, rebuilt into a pollfd array on every wait (see
/// the module doc for why rebuild-per-iteration is the design).
///
/// Not thread-safe by design — the whole point of the event loop is that
/// exactly one thread ever touches it.
pub const Loop = struct {
    alloc: Allocator,
    entries: std.ArrayListUnmanaged(Entry) = .{},
    /// Scratch pollfd array rebuilt by `buildPollSet`; retained between
    /// iterations so steady-state waits allocate nothing.
    pollfds: std.ArrayListUnmanaged(posix.pollfd) = .{},

    const Entry = struct {
        fd: posix.fd_t,
        interest: Interest,
    };

    pub fn init(alloc: Allocator) Loop {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *Loop) void {
        self.entries.deinit(self.alloc);
        self.pollfds.deinit(self.alloc);
    }

    /// Register `fd` with the given interest. Each fd may be registered
    /// at most once; a duplicate registration is a caller bug and is
    /// reported as an error rather than silently replacing the interest.
    pub fn registerFd(self: *Loop, fd: posix.fd_t, interest: Interest) (Allocator.Error || error{AlreadyRegistered})!void {
        if (self.find(fd) != null) return error.AlreadyRegistered;
        try self.entries.append(self.alloc, .{ .fd = fd, .interest = interest });
    }

    /// Remove `fd` from the registration table. Returns false when the fd
    /// was not registered (already removed — callers on teardown paths may
    /// race with themselves logically, never with another thread).
    pub fn deregisterFd(self: *Loop, fd: posix.fd_t) bool {
        const i = self.find(fd) orelse return false;
        _ = self.entries.orderedRemove(i);
        return true;
    }

    /// Turn on POLLOUT interest for `fd` (e.g. its outbound buffer just
    /// became non-empty). Toggling an unregistered fd is a caller bug.
    pub fn armWrite(self: *Loop, fd: posix.fd_t) void {
        self.setWrite(fd, true);
    }

    /// Turn off POLLOUT interest for `fd` (outbound buffer drained).
    pub fn disarmWrite(self: *Loop, fd: posix.fd_t) void {
        self.setWrite(fd, false);
    }

    fn setWrite(self: *Loop, fd: posix.fd_t, want: bool) void {
        const i = self.find(fd) orelse {
            // Toggling interest on an fd that isn't registered is a
            // programmer error; loud in Debug, harmless no-op in release.
            std.debug.assert(false);
            return;
        };
        self.entries.items[i].interest.write = want;
    }

    /// Number of registered fds.
    pub fn count(self: *const Loop) usize {
        return self.entries.items.len;
    }

    /// Rebuild the pollfd array from the registration table (the
    /// rebuild-per-iteration step). Exposed separately from `waitReady`
    /// so the mapping from interest flags to POLLIN/POLLOUT bits is
    /// testable without performing an actual poll.
    ///
    /// The returned slice is owned by the loop and valid until the next
    /// `buildPollSet`/`waitReady` call.
    pub fn buildPollSet(self: *Loop) Allocator.Error![]posix.pollfd {
        self.pollfds.clearRetainingCapacity();
        // Capacity of at least 1 even with no registrations: the returned
        // slice's pointer must be valid storage even at length 0, because
        // aarch64-linux lowers poll(2) to ppoll, whose address check
        // rejects a dangling pointer regardless of nfds (EFAULT).
        try self.pollfds.ensureTotalCapacity(self.alloc, @max(1, self.entries.items.len));
        for (self.entries.items) |entry| {
            var events: i16 = 0;
            if (entry.interest.read) events |= posix.POLL.IN;
            if (entry.interest.write) events |= posix.POLL.OUT;
            self.pollfds.appendAssumeCapacity(.{
                .fd = entry.fd,
                .events = events,
                .revents = 0,
            });
        }
        return self.pollfds.items;
    }

    /// One loop iteration's wait: rebuild the pollfd set, block in
    /// poll(2) for up to `timeout_ms` (null = infinite; pair with
    /// `DeadlineTable.nextTimeoutMs`), and return an iterator over the
    /// fds that reported readiness. A timeout yields an iterator that
    /// returns null immediately. EINTR is retried inside std's poll
    /// wrapper, so callers never observe it.
    pub fn waitReady(self: *Loop, timeout_ms: ?i32) !ReadyIter {
        const fds = try self.buildPollSet();
        _ = try posix.poll(fds, timeout_ms orelse -1);
        return .{ .pollfds = fds };
    }

    fn find(self: *const Loop, fd: posix.fd_t) ?usize {
        for (self.entries.items, 0..) |entry, i| {
            if (entry.fd == fd) return i;
        }
        return null;
    }
};

/// One pending deadline. `id` is caller-defined (e.g. a waiter or
/// housekeeping-task identifier); the table never interprets it.
pub const Deadline = struct {
    id: u64,
    deadline_ms: i64,
};

/// The timer half of the event loop: a list of `{id, deadline_ms}`
/// entries kept sorted by deadline (a sorted list is enough at this
/// scale — same < 100 design center as the fd table). Insertion is
/// stable: entries with equal deadlines pop in insertion order.
///
/// Timestamps are absolute milliseconds on the caller's clock
/// (`std.time.milliTimestamp` convention elsewhere in the server).
pub const DeadlineTable = struct {
    alloc: Allocator,
    entries: std.ArrayListUnmanaged(Deadline) = .{},

    pub fn init(alloc: Allocator) DeadlineTable {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *DeadlineTable) void {
        self.entries.deinit(self.alloc);
    }

    /// Insert a deadline, keeping the table sorted ascending. Ties go
    /// after existing entries with the same deadline (FIFO pop order).
    /// Duplicate ids are allowed; `cancel` removes all of them.
    pub fn insert(self: *DeadlineTable, id: u64, deadline_ms: i64) Allocator.Error!void {
        var i: usize = 0;
        while (i < self.entries.items.len and self.entries.items[i].deadline_ms <= deadline_ms) : (i += 1) {}
        try self.entries.insert(self.alloc, i, .{ .id = id, .deadline_ms = deadline_ms });
    }

    /// Remove every entry with the given id. Returns true when at least
    /// one entry was removed.
    pub fn cancel(self: *DeadlineTable, id: u64) bool {
        var removed = false;
        var i: usize = 0;
        while (i < self.entries.items.len) {
            if (self.entries.items[i].id == id) {
                _ = self.entries.orderedRemove(i);
                removed = true;
                continue;
            }
            i += 1;
        }
        return removed;
    }

    /// Pop the earliest deadline that has expired (`deadline_ms <=
    /// now_ms`), or null when nothing has. Call in a loop after poll
    /// returns to service every expiry; expired entries pop in deadline
    /// order, insertion order among ties.
    pub fn popExpired(self: *DeadlineTable, now_ms: i64) ?Deadline {
        if (self.entries.items.len == 0) return null;
        if (self.entries.items[0].deadline_ms > now_ms) return null;
        return self.entries.orderedRemove(0);
    }

    /// Poll timeout to the nearest deadline, clamped to [0, maxInt(i32)]:
    /// already-expired deadlines yield 0 (poll returns immediately so the
    /// expiry is serviced this iteration), and null means no deadlines —
    /// wait forever. Feed the result straight into `Loop.waitReady`.
    pub fn nextTimeoutMs(self: *const DeadlineTable, now_ms: i64) ?i32 {
        if (self.entries.items.len == 0) return null;
        const diff = self.entries.items[0].deadline_ms -| now_ms;
        if (diff <= 0) return 0;
        return std.math.cast(i32, diff) orelse std.math.maxInt(i32);
    }

    /// Number of pending deadlines.
    pub fn count(self: *const DeadlineTable) usize {
        return self.entries.items.len;
    }
};

// ============================================================================
// Deadline table tests
// ============================================================================

test "deadlines: nextTimeoutMs selects the nearest among mixed deadlines" {
    var table = DeadlineTable.init(std.testing.allocator);
    defer table.deinit();

    try table.insert(1, 500);
    try table.insert(2, 100);
    try table.insert(3, 900);

    // Nearest is 100; from now=40 that's 60ms out.
    try std.testing.expectEqual(@as(?i32, 60), table.nextTimeoutMs(40));

    // Once the nearest is popped, the next-nearest drives the timeout.
    _ = table.popExpired(100);
    try std.testing.expectEqual(@as(?i32, 400), table.nextTimeoutMs(100));
}

test "deadlines: nextTimeoutMs clamps expired to 0, empty to null, huge to maxInt" {
    var table = DeadlineTable.init(std.testing.allocator);
    defer table.deinit();

    // Empty table: wait forever.
    try std.testing.expectEqual(@as(?i32, null), table.nextTimeoutMs(0));

    // Already-expired deadline: poll must return immediately, not block
    // on a negative timeout (negative means infinite to poll(2)).
    try table.insert(1, 100);
    try std.testing.expectEqual(@as(?i32, 0), table.nextTimeoutMs(250));
    try std.testing.expectEqual(@as(?i32, 0), table.nextTimeoutMs(100));

    // A deadline farther out than i32 milliseconds clamps instead of
    // overflowing poll's c_int timeout.
    _ = table.cancel(1);
    try table.insert(2, std.math.maxInt(i64) - 1);
    try std.testing.expectEqual(@as(?i32, std.math.maxInt(i32)), table.nextTimeoutMs(0));
}

test "deadlines: cancel removes the entry and misses return false" {
    var table = DeadlineTable.init(std.testing.allocator);
    defer table.deinit();

    try table.insert(1, 100);
    try table.insert(2, 200);
    try table.insert(3, 300);

    try std.testing.expect(table.cancel(2));
    try std.testing.expectEqual(@as(usize, 2), table.count());

    // Cancelled id never pops; the others still do, in order.
    const first = table.popExpired(1000).?;
    try std.testing.expectEqual(@as(u64, 1), first.id);
    const second = table.popExpired(1000).?;
    try std.testing.expectEqual(@as(u64, 3), second.id);
    try std.testing.expect(table.popExpired(1000) == null);

    // Cancelling an id that isn't there reports false.
    try std.testing.expect(!table.cancel(42));

    // cancel removes *all* entries carrying the id.
    try table.insert(7, 100);
    try table.insert(7, 500);
    try std.testing.expect(table.cancel(7));
    try std.testing.expectEqual(@as(usize, 0), table.count());
}

test "deadlines: popExpired yields deadline order with FIFO ties, respects now" {
    var table = DeadlineTable.init(std.testing.allocator);
    defer table.deinit();

    // Inserted out of order, with two entries tied at 200.
    try table.insert(1, 200);
    try table.insert(2, 100);
    try table.insert(3, 200);

    // now=150: only the 100ms entry has expired.
    const early = table.popExpired(150).?;
    try std.testing.expectEqual(@as(u64, 2), early.id);
    try std.testing.expectEqual(@as(i64, 100), early.deadline_ms);
    try std.testing.expect(table.popExpired(150) == null);

    // now=200 (boundary is inclusive): the tied entries pop in the order
    // they were inserted.
    const tie_a = table.popExpired(200).?;
    try std.testing.expectEqual(@as(u64, 1), tie_a.id);
    const tie_b = table.popExpired(200).?;
    try std.testing.expectEqual(@as(u64, 3), tie_b.id);
    try std.testing.expect(table.popExpired(200) == null);
}

// ============================================================================
// Readiness (pollfd-set builder) tests
// ============================================================================

test "loop: registered fds appear in the built set; deregister removes the entry" {
    var loop = Loop.init(std.testing.allocator);
    defer loop.deinit();

    // Pure build-side test: fds are never handed to poll(2), so plain
    // numbers stand in for real descriptors.
    try loop.registerFd(7, .{});
    try loop.registerFd(8, .{});

    var fds = try loop.buildPollSet();
    try std.testing.expectEqual(@as(usize, 2), fds.len);
    try std.testing.expectEqual(@as(posix.fd_t, 7), fds[0].fd);
    try std.testing.expect(fds[0].events & posix.POLL.IN != 0);
    try std.testing.expectEqual(@as(posix.fd_t, 8), fds[1].fd);

    // Duplicate registration is rejected, not silently replaced.
    try std.testing.expectError(error.AlreadyRegistered, loop.registerFd(7, .{}));

    try std.testing.expect(loop.deregisterFd(7));
    fds = try loop.buildPollSet();
    try std.testing.expectEqual(@as(usize, 1), fds.len);
    try std.testing.expectEqual(@as(posix.fd_t, 8), fds[0].fd);

    // Deregistering an fd that's already gone reports false.
    try std.testing.expect(!loop.deregisterFd(7));
}

test "loop: armWrite/disarmWrite toggle POLLOUT in the built pollfd array" {
    var loop = Loop.init(std.testing.allocator);
    defer loop.deinit();

    try loop.registerFd(7, .{});

    var fds = try loop.buildPollSet();
    try std.testing.expect(fds[0].events & posix.POLL.OUT == 0);

    loop.armWrite(7);
    fds = try loop.buildPollSet();
    try std.testing.expect(fds[0].events & posix.POLL.OUT != 0);
    // Read interest survives the write toggle.
    try std.testing.expect(fds[0].events & posix.POLL.IN != 0);

    loop.disarmWrite(7);
    fds = try loop.buildPollSet();
    try std.testing.expect(fds[0].events & posix.POLL.OUT == 0);

    // Write interest can also be requested at registration time.
    try loop.registerFd(9, .{ .read = false, .write = true });
    fds = try loop.buildPollSet();
    try std.testing.expect(fds[1].events & posix.POLL.OUT != 0);
    try std.testing.expect(fds[1].events & posix.POLL.IN == 0);
}

test "loop: waitReady yields the readable fd and skips quiet ones" {
    var loop = Loop.init(std.testing.allocator);
    defer loop.deinit();

    // Two pipes: one gets a byte written (readable), one stays quiet.
    const ready_pipe = try posix.pipe();
    defer posix.close(ready_pipe[0]);
    defer posix.close(ready_pipe[1]);
    const quiet_pipe = try posix.pipe();
    defer posix.close(quiet_pipe[0]);
    defer posix.close(quiet_pipe[1]);

    try loop.registerFd(quiet_pipe[0], .{});
    try loop.registerFd(ready_pipe[0], .{});

    // Nothing written yet: timeout=0 returns an empty iteration.
    var it = try loop.waitReady(0);
    try std.testing.expect(it.next() == null);

    _ = try posix.write(ready_pipe[1], "x");

    it = try loop.waitReady(0);
    const ready = it.next().?;
    try std.testing.expectEqual(ready_pipe[0], ready.fd);
    try std.testing.expect(ready.revents & posix.POLL.IN != 0);
    // The quiet pipe reported nothing, so the iteration ends here.
    try std.testing.expect(it.next() == null);
}
