//! Compatibility layer for Zig 0.16.
//! std.posix syscall wrappers, std.time timestamps, and unix-socket helpers
//! that were removed from the standard library in 0.16 ("go lower: use
//! std.posix.system directly"). Implementations are ported from the Zig
//! 0.15.2 standard library so semantics match what hty shipped on 0.15.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const system = posix.system;
const linux = std.os.linux;
const windows = std.os.windows;
const wasi = std.os.wasi;
const errno = posix.errno;
const unexpectedErrno = posix.unexpectedErrno;
const UnexpectedError = posix.UnexpectedError;
const toPosixPath = posix.toPosixPath;
pub const fd_t = posix.fd_t;
const pid_t = posix.pid_t;
const mode_t = posix.mode_t;
const socket_t = posix.socket_t;
const sockaddr = posix.sockaddr;
const socklen_t = posix.socklen_t;
const timespec = posix.timespec;
const maxInt = std.math.maxInt;
const assert = std.debug.assert;
const native_os = builtin.os.tag;
const use_libc = builtin.link_libc or switch (native_os) {
    .windows, .wasi => true,
    else => false,
};
const iovec_const = posix.iovec_const;
const O = posix.O;
const AT = posix.AT;
const SHUT = posix.SHUT;
const fs = std.fs;
const mem = std.mem;
const math = std.math;
const F = posix.F;
const FD_CLOEXEC = posix.FD_CLOEXEC;
const winsize = posix.winsize;
const SOCK = posix.SOCK;
const clockid_t = posix.clockid_t;
const lfs64_abi = native_os == .linux and builtin.link_libc and (builtin.abi.isGnu() or builtin.abi.isAndroid());
const sys = @This();
const testing = std.testing;
const timestamp_t = wasi.timestamp_t;
const epoch = std.time.epoch;
const ns_per_ms = std.time.ns_per_ms;
const ns_per_us = std.time.ns_per_us;
const ns_per_s = std.time.ns_per_s;
const ms_per_s = std.time.ms_per_s;

// ---------------------------------------------------------------------------
// std.posix (0.15.2)
// ---------------------------------------------------------------------------

pub const WriteError = error{
    DiskQuota,
    FileTooBig,
    InputOutput,
    NoSpaceLeft,
    DeviceBusy,
    InvalidArgument,

    /// File descriptor does not hold the required rights to write to it.
    AccessDenied,
    PermissionDenied,
    BrokenPipe,
    SystemResources,
    OperationAborted,
    NotOpenForWriting,

    /// The process cannot access the file because another process has locked
    /// a portion of the file. Windows-only.
    LockViolation,

    /// This error occurs when no global event loop is configured,
    /// and reading from the file descriptor would block.
    WouldBlock,

    /// Connection reset by peer.
    ConnectionResetByPeer,

    /// This error occurs in Linux if the process being written to
    /// no longer exists.
    ProcessNotFound,
    /// This error occurs when a device gets disconnected before or mid-flush
    /// while it's being written to - errno(6): No such device or address.
    NoDevice,

    /// The socket type requires that message be sent atomically, and the size of the message
    /// to be sent made this impossible. The message is not transmitted.
    MessageTooBig,
} || UnexpectedError;

/// Write to a file descriptor.
/// Retries when interrupted by a signal.
/// Returns the number of bytes written. If nonzero bytes were supplied, this will be nonzero.
///
/// Note that a successful write() may transfer fewer than count bytes.  Such partial  writes  can
/// occur  for  various reasons; for example, because there was insufficient space on the disk
/// device to write all of the requested bytes, or because a blocked write() to a socket,  pipe,  or
/// similar  was  interrupted by a signal handler after it had transferred some, but before it had
/// transferred all of the requested bytes.  In the event of a partial write, the caller can  make
/// another  write() call to transfer the remaining bytes.  The subsequent call will either
/// transfer further bytes or may result in an error (e.g., if the disk is now full).
///
/// For POSIX systems, if `fd` is opened in non blocking mode, the function will
/// return error.WouldBlock when EAGAIN is received.
/// On Windows, if the application has a global event loop enabled, I/O Completion Ports are
/// used to perform the I/O. `error.WouldBlock` is not possible on Windows.
///
/// Linux has a limit on how many bytes may be transferred in one `write` call, which is `0x7ffff000`
/// on both 64-bit and 32-bit systems. This is due to using a signed C int as the return value, as
/// well as stuffing the errno codes into the last `4096` values. This is noted on the `write` man page.
/// The limit on Darwin is `0x7fffffff`, trying to read more than that returns EINVAL.
/// The corresponding POSIX limit is `maxInt(isize)`.

/// Write to a file descriptor.
/// Retries when interrupted by a signal.
/// Returns the number of bytes written. If nonzero bytes were supplied, this will be nonzero.
///
/// Note that a successful write() may transfer fewer than count bytes.  Such partial  writes  can
/// occur  for  various reasons; for example, because there was insufficient space on the disk
/// device to write all of the requested bytes, or because a blocked write() to a socket,  pipe,  or
/// similar  was  interrupted by a signal handler after it had transferred some, but before it had
/// transferred all of the requested bytes.  In the event of a partial write, the caller can  make
/// another  write() call to transfer the remaining bytes.  The subsequent call will either
/// transfer further bytes or may result in an error (e.g., if the disk is now full).
///
/// For POSIX systems, if `fd` is opened in non blocking mode, the function will
/// return error.WouldBlock when EAGAIN is received.
/// On Windows, if the application has a global event loop enabled, I/O Completion Ports are
/// used to perform the I/O. `error.WouldBlock` is not possible on Windows.
///
/// Linux has a limit on how many bytes may be transferred in one `write` call, which is `0x7ffff000`
/// on both 64-bit and 32-bit systems. This is due to using a signed C int as the return value, as
/// well as stuffing the errno codes into the last `4096` values. This is noted on the `write` man page.
/// The limit on Darwin is `0x7fffffff`, trying to read more than that returns EINVAL.
/// The corresponding POSIX limit is `maxInt(isize)`.
pub fn write(fd: fd_t, bytes: []const u8) WriteError!usize {
    if (bytes.len == 0) return 0;
    if (native_os == .windows) {
        return windows.WriteFile(fd, bytes, null);
    }

    if (native_os == .wasi and !builtin.link_libc) {
        const ciovs = [_]iovec_const{iovec_const{
            .base = bytes.ptr,
            .len = bytes.len,
        }};
        var nwritten: usize = undefined;
        switch (wasi.fd_write(fd, &ciovs, ciovs.len, &nwritten)) {
            .SUCCESS => return nwritten,
            .INTR => unreachable,
            .INVAL => unreachable,
            .FAULT => unreachable,
            .AGAIN => unreachable,
            .BADF => return error.NotOpenForWriting, // can be a race condition.
            .DESTADDRREQ => unreachable, // `connect` was never called.
            .DQUOT => return error.DiskQuota,
            .FBIG => return error.FileTooBig,
            .IO => return error.InputOutput,
            .NOSPC => return error.NoSpaceLeft,
            .PERM => return error.PermissionDenied,
            .PIPE => return error.BrokenPipe,
            .NOTCAPABLE => return error.AccessDenied,
            else => |err| return unexpectedErrno(err),
        }
    }

    const max_count = switch (native_os) {
        .linux => 0x7ffff000,
        .macos, .ios, .watchos, .tvos, .visionos => maxInt(i32),
        else => maxInt(isize),
    };
    while (true) {
        const rc = system.write(fd, bytes.ptr, @min(bytes.len, max_count));
        switch (errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            .INVAL => return error.InvalidArgument,
            .FAULT => unreachable,
            .SRCH => return error.ProcessNotFound,
            .AGAIN => return error.WouldBlock,
            .BADF => return error.NotOpenForWriting, // can be a race condition.
            .DESTADDRREQ => unreachable, // `connect` was never called.
            .DQUOT => return error.DiskQuota,
            .FBIG => return error.FileTooBig,
            .IO => return error.InputOutput,
            .NOSPC => return error.NoSpaceLeft,
            .ACCES => return error.AccessDenied,
            .PERM => return error.PermissionDenied,
            .PIPE => return error.BrokenPipe,
            .CONNRESET => return error.ConnectionResetByPeer,
            .BUSY => return error.DeviceBusy,
            .NXIO => return error.NoDevice,
            .MSGSIZE => return error.MessageTooBig,
            else => |err| return unexpectedErrno(err),
        }
    }
}

/// Write multiple buffers to a file descriptor.
/// Retries when interrupted by a signal.
/// Returns the number of bytes written. If nonzero bytes were supplied, this will be nonzero.
///
/// Note that a successful write() may transfer fewer bytes than supplied.  Such partial  writes  can
/// occur  for  various reasons; for example, because there was insufficient space on the disk
/// device to write all of the requested bytes, or because a blocked write() to a socket,  pipe,  or
/// similar  was  interrupted by a signal handler after it had transferred some, but before it had
/// transferred all of the requested bytes.  In the event of a partial write, the caller can  make
/// another  write() call to transfer the remaining bytes.  The subsequent call will either
/// transfer further bytes or may result in an error (e.g., if the disk is now full).
///
/// For POSIX systems, if `fd` is opened in non blocking mode, the function will
/// return error.WouldBlock when EAGAIN is received.
/// On Windows, if the application has a global event loop enabled, I/O Completion Ports are
/// used to perform the I/O. `error.WouldBlock` is not possible on Windows.
///
/// If `iov.len` is larger than `IOV_MAX`, a partial write will occur.
///
/// This function assumes that all vectors, including zero-length vectors, have
/// a pointer within the address space of the application.

/// Closes the file descriptor.
///
/// Asserts the file descriptor is open.
///
/// This function is not capable of returning any indication of failure. An
/// application which wants to ensure writes have succeeded before closing must
/// call `fsync` before `close`.
///
/// The Zig standard library does not support POSIX thread cancellation.
pub fn close(fd: fd_t) void {
    if (native_os == .windows) {
        return windows.CloseHandle(fd);
    }
    if (native_os == .wasi and !builtin.link_libc) {
        _ = std.os.wasi.fd_close(fd);
        return;
    }
    switch (errno(system.close(fd))) {
        .BADF => unreachable, // Always a race condition.
        .INTR => return, // This is still a success. See https://github.com/ziglang/zig/issues/2425
        else => return,
    }
}

pub const UnlinkError = error{
    FileNotFound,

    /// In WASI, this error may occur when the file descriptor does
    /// not hold the required rights to unlink a resource by path relative to it.
    AccessDenied,
    PermissionDenied,
    FileBusy,
    FileSystem,
    IsDir,
    SymLinkLoop,
    NameTooLong,
    NotDir,
    SystemResources,
    ReadOnlyFileSystem,

    /// WASI-only; file paths must be valid UTF-8.
    InvalidUtf8,

    /// Windows-only; file paths provided by the user must be valid WTF-8.
    /// https://simonsapin.github.io/wtf-8/
    InvalidWtf8,

    /// On Windows, file paths cannot contain these characters:
    /// '/', '*', '?', '"', '<', '>', '|'
    BadPathName,

    /// On Windows, `\\server` or `\\server\share` was not found.
    NetworkNotFound,
} || UnexpectedError;

/// Delete a name and possibly the file it refers to.
/// On Windows, `file_path` should be encoded as [WTF-8](https://simonsapin.github.io/wtf-8/).
/// On WASI, `file_path` should be encoded as valid UTF-8.
/// On other platforms, `file_path` is an opaque sequence of bytes with no particular encoding.
/// See also `unlinkZ`.

/// Delete a name and possibly the file it refers to.
/// On Windows, `file_path` should be encoded as [WTF-8](https://simonsapin.github.io/wtf-8/).
/// On WASI, `file_path` should be encoded as valid UTF-8.
/// On other platforms, `file_path` is an opaque sequence of bytes with no particular encoding.
/// See also `unlinkZ`.
pub fn unlink(file_path: []const u8) UnlinkError!void {
    if (native_os == .wasi and !builtin.link_libc) {
        return unlinkat(AT.FDCWD, file_path, 0) catch |err| switch (err) {
            error.DirNotEmpty => unreachable, // only occurs when targeting directories
            else => |e| return e,
        };
    } else if (native_os == .windows) {
        const file_path_w = try windows.sliceToPrefixedFileW(null, file_path);
        return unlinkW(file_path_w.span());
    } else {
        const file_path_c = try toPosixPath(file_path);
        return unlinkZ(&file_path_c);
    }
}

/// Same as `unlink` except the parameter is null terminated.

/// Same as `unlink` except the parameter is null terminated.
pub fn unlinkZ(file_path: [*:0]const u8) UnlinkError!void {
    if (native_os == .windows) {
        const file_path_w = try windows.cStrToPrefixedFileW(null, file_path);
        return unlinkW(file_path_w.span());
    } else if (native_os == .wasi and !builtin.link_libc) {
        return unlink(mem.sliceTo(file_path, 0));
    }
    switch (errno(system.unlink(file_path))) {
        .SUCCESS => return,
        .ACCES => return error.AccessDenied,
        .PERM => return error.PermissionDenied,
        .BUSY => return error.FileBusy,
        .FAULT => unreachable,
        .INVAL => unreachable,
        .IO => return error.FileSystem,
        .ISDIR => return error.IsDir,
        .LOOP => return error.SymLinkLoop,
        .NAMETOOLONG => return error.NameTooLong,
        .NOENT => return error.FileNotFound,
        .NOTDIR => return error.NotDir,
        .NOMEM => return error.SystemResources,
        .ROFS => return error.ReadOnlyFileSystem,
        .ILSEQ => |err| if (native_os == .wasi)
            return error.InvalidUtf8
        else
            return unexpectedErrno(err),
        else => |err| return unexpectedErrno(err),
    }
}

/// Windows-only. Same as `unlink` except the parameter is null-terminated, WTF16 LE encoded.

pub fn dup(old_fd: fd_t) !fd_t {
    const rc = system.dup(old_fd);
    return switch (errno(rc)) {
        .SUCCESS => return @intCast(rc),
        .MFILE => error.ProcessFdQuotaExceeded,
        .BADF => unreachable, // invalid file descriptor
        else => |err| return unexpectedErrno(err),
    };
}

pub fn dup2(old_fd: fd_t, new_fd: fd_t) !void {
    while (true) {
        switch (errno(system.dup2(old_fd, new_fd))) {
            .SUCCESS => return,
            .BUSY, .INTR => continue,
            .MFILE => return error.ProcessFdQuotaExceeded,
            .INVAL => unreachable, // invalid parameters passed to dup2
            .BADF => unreachable, // invalid file descriptor
            else => |err| return unexpectedErrno(err),
        }
    }
}

pub const PipeError = error{
    SystemFdQuotaExceeded,
    ProcessFdQuotaExceeded,
} || UnexpectedError;

/// Creates a unidirectional data channel that can be used for interprocess communication.

/// Creates a unidirectional data channel that can be used for interprocess communication.
pub fn pipe() PipeError![2]fd_t {
    var fds: [2]fd_t = undefined;
    switch (errno(system.pipe(&fds))) {
        .SUCCESS => return fds,
        .INVAL => unreachable, // Invalid parameters to pipe()
        .FAULT => unreachable, // Invalid fds pointer
        .NFILE => return error.SystemFdQuotaExceeded,
        .MFILE => return error.ProcessFdQuotaExceeded,
        else => |err| return unexpectedErrno(err),
    }
}

pub fn pipe2(flags: O) PipeError![2]fd_t {
    if (@TypeOf(system.pipe2) != void) {
        var fds: [2]fd_t = undefined;
        switch (errno(system.pipe2(&fds, flags))) {
            .SUCCESS => return fds,
            .INVAL => unreachable, // Invalid flags
            .FAULT => unreachable, // Invalid fds pointer
            .NFILE => return error.SystemFdQuotaExceeded,
            .MFILE => return error.ProcessFdQuotaExceeded,
            else => |err| return unexpectedErrno(err),
        }
    }

    const fds: [2]fd_t = try pipe();
    errdefer {
        close(fds[0]);
        close(fds[1]);
    }

    // https://github.com/ziglang/zig/issues/18882
    if (@as(u32, @bitCast(flags)) == 0)
        return fds;

    // CLOEXEC is special, it's a file descriptor flag and must be set using
    // F.SETFD.
    if (flags.CLOEXEC) {
        for (fds) |fd| {
            switch (errno(system.fcntl(fd, F.SETFD, @as(u32, FD_CLOEXEC)))) {
                .SUCCESS => {},
                .INVAL => unreachable, // Invalid flags
                .BADF => unreachable, // Always a race condition
                else => |err| return unexpectedErrno(err),
            }
        }
    }

    const new_flags: u32 = f: {
        var new_flags = flags;
        new_flags.CLOEXEC = false;
        break :f @bitCast(new_flags);
    };
    // Set every other flag affecting the file status using F.SETFL.
    if (new_flags != 0) {
        for (fds) |fd| {
            switch (errno(system.fcntl(fd, F.SETFL, new_flags))) {
                .SUCCESS => {},
                .INVAL => unreachable, // Invalid flags
                .BADF => unreachable, // Always a race condition
                else => |err| return unexpectedErrno(err),
            }
        }
    }

    return fds;
}

pub const FcntlError = error{
    PermissionDenied,
    FileBusy,
    ProcessFdQuotaExceeded,
    Locked,
    DeadLock,
    LockedRegionLimitExceeded,
} || UnexpectedError;

pub fn fcntl(fd: fd_t, cmd: i32, arg: usize) FcntlError!usize {
    while (true) {
        const rc = system.fcntl(fd, cmd, arg);
        switch (errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            .AGAIN, .ACCES => return error.Locked,
            .BADF => unreachable,
            .BUSY => return error.FileBusy,
            .INVAL => unreachable, // invalid parameters
            .PERM => return error.PermissionDenied,
            .MFILE => return error.ProcessFdQuotaExceeded,
            .NOTDIR => unreachable, // invalid parameter
            .DEADLK => return error.DeadLock,
            .NOLCK => return error.LockedRegionLimitExceeded,
            else => |err| return unexpectedErrno(err),
        }
    }
}

/// Test whether a file descriptor refers to a terminal.
pub fn isatty(handle: fd_t) bool {
    if (native_os == .windows) {
        if (fs.File.isCygwinPty(.{ .handle = handle }))
            return true;

        var out: windows.DWORD = undefined;
        return windows.kernel32.GetConsoleMode(handle, &out) != 0;
    }
    if (builtin.link_libc) {
        return system.isatty(handle) != 0;
    }
    if (native_os == .wasi) {
        var statbuf: wasi.fdstat_t = undefined;
        const err = wasi.fd_fdstat_get(handle, &statbuf);
        if (err != .SUCCESS)
            return false;

        // A tty is a character device that we can't seek or tell on.
        if (statbuf.fs_filetype != .CHARACTER_DEVICE)
            return false;
        if (statbuf.fs_rights_base.FD_SEEK or statbuf.fs_rights_base.FD_TELL)
            return false;

        return true;
    }
    if (native_os == .linux) {
        while (true) {
            var wsz: winsize = undefined;
            const fd: usize = @bitCast(@as(isize, handle));
            const rc = linux.syscall3(.ioctl, fd, linux.T.IOCGWINSZ, @intFromPtr(&wsz));
            switch (linux.E.init(rc)) {
                .SUCCESS => return true,
                .INTR => continue,
                else => return false,
            }
        }
    }
    return system.isatty(handle) != 0;
}

/// Use this version of the `waitpid` wrapper if you spawned your child process using explicit
/// `fork` and `execve` method.
pub fn waitpid(pid: pid_t, flags: u32) WaitPidResult {
    var status: if (builtin.link_libc) c_int else u32 = undefined;
    while (true) {
        const rc = system.waitpid(pid, &status, @intCast(flags));
        switch (errno(rc)) {
            .SUCCESS => return .{
                .pid = @intCast(rc),
                .status = @bitCast(status),
            },
            .INTR => continue,
            .CHILD => unreachable, // The process specified does not exist. It would be a race condition to handle this error.
            .INVAL => unreachable, // Invalid flags.
            else => unreachable,
        }
    }
}

pub const WaitPidResult = struct {
    pid: pid_t,
    status: u32,
};

/// Use this version of the `waitpid` wrapper if you spawned your child process using explicit
/// `fork` and `execve` method.

pub const ShutdownError = error{
    ConnectionAborted,

    /// Connection was reset by peer, application should close socket as it is no longer usable.
    ConnectionResetByPeer,
    BlockingOperationInProgress,

    /// The network subsystem has failed.
    NetworkSubsystemFailed,

    /// The socket is not connected (connection-oriented sockets only).
    SocketNotConnected,
    SystemResources,
} || UnexpectedError;

pub const ShutdownHow = enum { recv, send, both };

/// Shutdown socket send/receive operations

/// Shutdown socket send/receive operations
pub fn shutdown(sock: socket_t, how: ShutdownHow) ShutdownError!void {
    if (native_os == .windows) {
        const result = windows.ws2_32.shutdown(sock, switch (how) {
            .recv => windows.ws2_32.SD_RECEIVE,
            .send => windows.ws2_32.SD_SEND,
            .both => windows.ws2_32.SD_BOTH,
        });
        if (0 != result) switch (windows.ws2_32.WSAGetLastError()) {
            .WSAECONNABORTED => return error.ConnectionAborted,
            .WSAECONNRESET => return error.ConnectionResetByPeer,
            .WSAEINPROGRESS => return error.BlockingOperationInProgress,
            .WSAEINVAL => unreachable,
            .WSAENETDOWN => return error.NetworkSubsystemFailed,
            .WSAENOTCONN => return error.SocketNotConnected,
            .WSAENOTSOCK => unreachable,
            .WSANOTINITIALISED => unreachable,
            else => |err| return windows.unexpectedWSAError(err),
        };
    } else {
        const rc = system.shutdown(sock, switch (how) {
            .recv => SHUT.RD,
            .send => SHUT.WR,
            .both => SHUT.RDWR,
        });
        switch (errno(rc)) {
            .SUCCESS => return,
            .BADF => unreachable,
            .INVAL => unreachable,
            .NOTCONN => return error.SocketNotConnected,
            .NOTSOCK => unreachable,
            .NOBUFS => return error.SystemResources,
            else => |err| return unexpectedErrno(err),
        }
    }
}

pub const SendError = error{
    /// (For UNIX domain sockets, which are identified by pathname) Write permission is  denied
    /// on  the destination socket file, or search permission is denied for one of the
    /// directories the path prefix.  (See path_resolution(7).)
    /// (For UDP sockets) An attempt was made to send to a network/broadcast address as  though
    /// it was a unicast address.
    AccessDenied,

    /// The socket is marked nonblocking and the requested operation would block, and
    /// there is no global event loop configured.
    /// It's also possible to get this error under the following condition:
    /// (Internet  domain datagram sockets) The socket referred to by sockfd had not previously
    /// been bound to an address and, upon attempting to bind it to an ephemeral port,  it  was
    /// determined that all port numbers in the ephemeral port range are currently in use.  See
    /// the discussion of /proc/sys/net/ipv4/ip_local_port_range in ip(7).
    WouldBlock,

    /// Another Fast Open is already in progress.
    FastOpenAlreadyInProgress,

    /// Connection reset by peer.
    ConnectionResetByPeer,

    /// The  socket  type requires that message be sent atomically, and the size of the message
    /// to be sent made this impossible. The message is not transmitted.
    MessageTooBig,

    /// The output queue for a network interface was full.  This generally indicates  that  the
    /// interface  has  stopped sending, but may be caused by transient congestion.  (Normally,
    /// this does not occur in Linux.  Packets are just silently dropped when  a  device  queue
    /// overflows.)
    /// This is also caused when there is not enough kernel memory available.
    SystemResources,

    /// The  local  end  has been shut down on a connection oriented socket.  In this case, the
    /// process will also receive a SIGPIPE unless MSG.NOSIGNAL is set.
    BrokenPipe,

    FileDescriptorNotASocket,

    /// Network is unreachable.
    NetworkUnreachable,

    /// The local network interface used to reach the destination is down.
    NetworkSubsystemFailed,

    /// The destination address is not listening.
    ConnectionRefused,
} || UnexpectedError;

pub const SendToError = SendMsgError || error{
    /// The destination address is not reachable by the bound address.
    UnreachableAddress,
    /// The destination address is not listening.
    ConnectionRefused,
};

/// Transmit a message to another socket.
///
/// The `sendto` call may be used only when the socket is in a connected state (so that the intended
/// recipient  is  known). The  following call
///
///     send(sockfd, buf, len, flags);
///
/// is equivalent to
///
///     sendto(sockfd, buf, len, flags, NULL, 0);
///
/// If  sendto()  is used on a connection-mode (`SOCK.STREAM`, `SOCK.SEQPACKET`) socket, the arguments
/// `dest_addr` and `addrlen` are asserted to be `null` and `0` respectively, and asserted
/// that the socket was actually connected.
/// Otherwise, the address of the target is given by `dest_addr` with `addrlen` specifying  its  size.
///
/// If the message is too long to pass atomically through the underlying protocol,
/// `SendError.MessageTooBig` is returned, and the message is not transmitted.
///
/// There is no  indication  of  failure  to  deliver.
///
/// When the message does not fit into the send buffer of  the  socket,  `sendto`  normally  blocks,
/// unless  the socket has been placed in nonblocking I/O mode.  In nonblocking mode it would fail
/// with `SendError.WouldBlock`.  The `select` call may be used  to  determine when it is
/// possible to send more data.

/// Transmit a message to another socket.
///
/// The `send` call may be used only when the socket is in a connected state (so that the intended
/// recipient  is  known).   The  only  difference  between `send` and `write` is the presence of
/// flags.  With a zero flags argument, `send` is equivalent to  `write`.   Also,  the  following
/// call
///
///     send(sockfd, buf, len, flags);
///
/// is equivalent to
///
///     sendto(sockfd, buf, len, flags, NULL, 0);
///
/// There is no  indication  of  failure  to  deliver.
///
/// When the message does not fit into the send buffer of  the  socket,  `send`  normally  blocks,
/// unless  the socket has been placed in nonblocking I/O mode.  In nonblocking mode it would fail
/// with `SendError.WouldBlock`.  The `select` call may be used  to  determine when it is
/// possible to send more data.
pub fn send(
    /// The file descriptor of the sending socket.
    sockfd: socket_t,
    buf: []const u8,
    flags: u32,
) SendError!usize {
    return sendto(sockfd, buf, flags, null, 0) catch |err| switch (err) {
        error.AddressFamilyNotSupported => unreachable,
        error.SymLinkLoop => unreachable,
        error.NameTooLong => unreachable,
        error.FileNotFound => unreachable,
        error.NotDir => unreachable,
        error.NetworkUnreachable => unreachable,
        error.AddressNotAvailable => unreachable,
        error.SocketNotConnected => unreachable,
        error.UnreachableAddress => unreachable,
        else => |e| return e,
    };
}

pub const RecvFromError = error{
    /// The socket is marked nonblocking and the requested operation would block, and
    /// there is no global event loop configured.
    WouldBlock,

    /// A remote host refused to allow the network connection, typically because it is not
    /// running the requested service.
    ConnectionRefused,

    /// Could not allocate kernel memory.
    SystemResources,

    ConnectionResetByPeer,
    ConnectionTimedOut,

    /// The socket has not been bound.
    SocketNotBound,

    /// The UDP message was too big for the buffer and part of it has been discarded
    MessageTooBig,

    /// The network subsystem has failed.
    NetworkSubsystemFailed,

    /// The socket is not connected (connection-oriented sockets only).
    SocketNotConnected,
} || UnexpectedError;

pub fn recv(sock: socket_t, buf: []u8, flags: u32) RecvFromError!usize {
    return recvfrom(sock, buf, flags, null, null);
}

/// If `sockfd` is opened in non blocking mode, the function will
/// return error.WouldBlock when EAGAIN is received.

pub const OpenError = error{
    /// In WASI, this error may occur when the file descriptor does
    /// not hold the required rights to open a new resource relative to it.
    AccessDenied,
    PermissionDenied,
    SymLinkLoop,
    ProcessFdQuotaExceeded,
    SystemFdQuotaExceeded,
    NoDevice,
    /// Either:
    /// * One of the path components does not exist.
    /// * Cwd was used, but cwd has been deleted.
    /// * The path associated with the open directory handle has been deleted.
    /// * On macOS, multiple processes or threads raced to create the same file
    ///   with `O.EXCL` set to `false`.
    FileNotFound,

    /// The path exceeded `max_path_bytes` bytes.
    NameTooLong,

    /// Insufficient kernel memory was available, or
    /// the named file is a FIFO and per-user hard limit on
    /// memory allocation for pipes has been reached.
    SystemResources,

    /// The file is too large to be opened. This error is unreachable
    /// for 64-bit targets, as well as when opening directories.
    FileTooBig,

    /// The path refers to directory but the `DIRECTORY` flag was not provided.
    IsDir,

    /// A new path cannot be created because the device has no room for the new file.
    /// This error is only reachable when the `CREAT` flag is provided.
    NoSpaceLeft,

    /// A component used as a directory in the path was not, in fact, a directory, or
    /// `DIRECTORY` was specified and the path was not a directory.
    NotDir,

    /// The path already exists and the `CREAT` and `EXCL` flags were provided.
    PathAlreadyExists,
    DeviceBusy,

    /// The underlying filesystem does not support file locks
    FileLocksNotSupported,

    /// Path contains characters that are disallowed by the underlying filesystem.
    BadPathName,

    /// WASI-only; file paths must be valid UTF-8.
    InvalidUtf8,

    /// Windows-only; file paths provided by the user must be valid WTF-8.
    /// https://simonsapin.github.io/wtf-8/
    InvalidWtf8,

    /// On Windows, `\\server` or `\\server\share` was not found.
    NetworkNotFound,

    /// This error occurs in Linux if the process to be open was not found.
    ProcessNotFound,

    /// One of these three things:
    /// * pathname  refers to an executable image which is currently being
    ///   executed and write access was requested.
    /// * pathname refers to a file that is currently in  use  as  a  swap
    ///   file, and the O_TRUNC flag was specified.
    /// * pathname  refers  to  a file that is currently being read by the
    ///   kernel (e.g., for module/firmware loading), and write access was
    ///   requested.
    FileBusy,

    WouldBlock,
} || UnexpectedError;

/// Open and possibly create a file. Keeps trying if it gets interrupted.
/// On Windows, `file_path` should be encoded as [WTF-8](https://simonsapin.github.io/wtf-8/).
/// On WASI, `file_path` should be encoded as valid UTF-8.
/// On other platforms, `file_path` is an opaque sequence of bytes with no particular encoding.
/// See also `openZ`.

/// Open and possibly create a file. Keeps trying if it gets interrupted.
/// On Windows, `file_path` should be encoded as [WTF-8](https://simonsapin.github.io/wtf-8/).
/// On WASI, `file_path` should be encoded as valid UTF-8.
/// On other platforms, `file_path` is an opaque sequence of bytes with no particular encoding.
/// See also `openZ`.
pub fn open(file_path: []const u8, flags: O, perm: mode_t) OpenError!fd_t {
    if (native_os == .windows) {
        @compileError("Windows does not support POSIX; use Windows-specific API or cross-platform std.fs API");
    } else if (native_os == .wasi and !builtin.link_libc) {
        return openat(AT.FDCWD, file_path, flags, perm);
    }
    const file_path_c = try toPosixPath(file_path);
    return openZ(&file_path_c, flags, perm);
}

/// Open and possibly create a file. Keeps trying if it gets interrupted.
/// On Windows, `file_path` should be encoded as [WTF-8](https://simonsapin.github.io/wtf-8/).
/// On WASI, `file_path` should be encoded as valid UTF-8.
/// On other platforms, `file_path` is an opaque sequence of bytes with no particular encoding.
/// See also `open`.

/// Open and possibly create a file. Keeps trying if it gets interrupted.
/// On Windows, `file_path` should be encoded as [WTF-8](https://simonsapin.github.io/wtf-8/).
/// On WASI, `file_path` should be encoded as valid UTF-8.
/// On other platforms, `file_path` is an opaque sequence of bytes with no particular encoding.
/// See also `open`.
pub fn openZ(file_path: [*:0]const u8, flags: O, perm: mode_t) OpenError!fd_t {
    if (native_os == .windows) {
        @compileError("Windows does not support POSIX; use Windows-specific API or cross-platform std.fs API");
    } else if (native_os == .wasi and !builtin.link_libc) {
        return open(mem.sliceTo(file_path, 0), flags, perm);
    }

    const open_sym = if (lfs64_abi) system.open64 else system.open;
    while (true) {
        const rc = open_sym(file_path, flags, perm);
        switch (errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,

            .FAULT => unreachable,
            .INVAL => return error.BadPathName,
            .ACCES => return error.AccessDenied,
            .FBIG => return error.FileTooBig,
            .OVERFLOW => return error.FileTooBig,
            .ISDIR => return error.IsDir,
            .LOOP => return error.SymLinkLoop,
            .MFILE => return error.ProcessFdQuotaExceeded,
            .NAMETOOLONG => return error.NameTooLong,
            .NFILE => return error.SystemFdQuotaExceeded,
            .NODEV => return error.NoDevice,
            .NOENT => return error.FileNotFound,
            .SRCH => return error.ProcessNotFound,
            .NOMEM => return error.SystemResources,
            .NOSPC => return error.NoSpaceLeft,
            .NOTDIR => return error.NotDir,
            .PERM => return error.PermissionDenied,
            .EXIST => return error.PathAlreadyExists,
            .BUSY => return error.DeviceBusy,
            .ILSEQ => |err| if (native_os == .wasi)
                return error.InvalidUtf8
            else
                return unexpectedErrno(err),
            else => |err| return unexpectedErrno(err),
        }
    }
}

/// Open and possibly create a file. Keeps trying if it gets interrupted.
/// `file_path` is relative to the open directory handle `dir_fd`.
/// On Windows, `file_path` should be encoded as [WTF-8](https://simonsapin.github.io/wtf-8/).
/// On WASI, `file_path` should be encoded as valid UTF-8.
/// On other platforms, `file_path` is an opaque sequence of bytes with no particular encoding.
/// See also `openatZ`.

pub const ForkError = error{SystemResources} || UnexpectedError;

pub fn fork() ForkError!pid_t {
    const rc = system.fork();
    switch (errno(rc)) {
        .SUCCESS => return @intCast(rc),
        .AGAIN => return error.SystemResources,
        .NOMEM => return error.SystemResources,
        else => |err| return unexpectedErrno(err),
    }
}

pub const AccessError = error{
    AccessDenied,
    PermissionDenied,
    FileNotFound,
    NameTooLong,
    InputOutput,
    SystemResources,
    BadPathName,
    FileBusy,
    SymLinkLoop,
    ReadOnlyFileSystem,
    /// WASI-only; file paths must be valid UTF-8.
    InvalidUtf8,
    /// Windows-only; file paths provided by the user must be valid WTF-8.
    /// https://simonsapin.github.io/wtf-8/
    InvalidWtf8,
} || UnexpectedError;

/// check user's permissions for a file
///
/// * On Windows, asserts `path` is valid [WTF-8](https://simonsapin.github.io/wtf-8/).
/// * On WASI, invalid UTF-8 passed to `path` causes `error.InvalidUtf8`.
/// * On other platforms, `path` is an opaque sequence of bytes with no particular encoding.
///
/// On Windows, `mode` is ignored. This is a POSIX API that is only partially supported by
/// Windows. See `fs` for the cross-platform file system API.

/// check user's permissions for a file
///
/// * On Windows, asserts `path` is valid [WTF-8](https://simonsapin.github.io/wtf-8/).
/// * On WASI, invalid UTF-8 passed to `path` causes `error.InvalidUtf8`.
/// * On other platforms, `path` is an opaque sequence of bytes with no particular encoding.
///
/// On Windows, `mode` is ignored. This is a POSIX API that is only partially supported by
/// Windows. See `fs` for the cross-platform file system API.
pub fn access(path: []const u8, mode: u32) AccessError!void {
    if (native_os == .windows) {
        const path_w = try windows.sliceToPrefixedFileW(null, path);
        _ = try windows.GetFileAttributesW(path_w.span().ptr);
        return;
    } else if (native_os == .wasi and !builtin.link_libc) {
        return faccessat(AT.FDCWD, path, mode, 0);
    }
    const path_c = try toPosixPath(path);
    return accessZ(&path_c, mode);
}

/// Same as `access` except `path` is null-terminated.

/// Same as `access` except `path` is null-terminated.
pub fn accessZ(path: [*:0]const u8, mode: u32) AccessError!void {
    if (native_os == .windows) {
        const path_w = try windows.cStrToPrefixedFileW(null, path);
        _ = try windows.GetFileAttributesW(path_w.span().ptr);
        return;
    } else if (native_os == .wasi and !builtin.link_libc) {
        return access(mem.sliceTo(path, 0), mode);
    }
    switch (errno(system.access(path, mode))) {
        .SUCCESS => return,
        .ACCES => return error.AccessDenied,
        .PERM => return error.PermissionDenied,
        .ROFS => return error.ReadOnlyFileSystem,
        .LOOP => return error.SymLinkLoop,
        .TXTBSY => return error.FileBusy,
        .NOTDIR => return error.FileNotFound,
        .NOENT => return error.FileNotFound,
        .NAMETOOLONG => return error.NameTooLong,
        .INVAL => unreachable,
        .FAULT => unreachable,
        .IO => return error.InputOutput,
        .NOMEM => return error.SystemResources,
        .ILSEQ => |err| if (native_os == .wasi)
            return error.InvalidUtf8
        else
            return unexpectedErrno(err),
        else => |err| return unexpectedErrno(err),
    }
}

/// Check user's permissions for a file, based on an open directory handle.
///
/// * On Windows, asserts `path` is valid [WTF-8](https://simonsapin.github.io/wtf-8/).
/// * On WASI, invalid UTF-8 passed to `path` causes `error.InvalidUtf8`.
/// * On other platforms, `path` is an opaque sequence of bytes with no particular encoding.
///
/// On Windows, `mode` is ignored. This is a POSIX API that is only partially supported by
/// Windows. See `fs` for the cross-platform file system API.

pub const AcceptError = error{
    ConnectionAborted,

    /// The file descriptor sockfd does not refer to a socket.
    FileDescriptorNotASocket,

    /// The per-process limit on the number of open file descriptors has been reached.
    ProcessFdQuotaExceeded,

    /// The system-wide limit on the total number of open files has been reached.
    SystemFdQuotaExceeded,

    /// Not enough free memory.  This often means that the memory allocation  is  limited
    /// by the socket buffer limits, not by the system memory.
    SystemResources,

    /// Socket is not listening for new connections.
    SocketNotListening,

    ProtocolFailure,

    /// Firewall rules forbid connection.
    BlockedByFirewall,

    /// This error occurs when no global event loop is configured,
    /// and accepting from the socket would block.
    WouldBlock,

    /// An incoming connection was indicated, but was subsequently terminated by the
    /// remote peer prior to accepting the call.
    ConnectionResetByPeer,

    /// The network subsystem has failed.
    NetworkSubsystemFailed,

    /// The referenced socket is not a type that supports connection-oriented service.
    OperationNotSupported,
} || UnexpectedError;

/// Accept a connection on a socket.
/// If `sockfd` is opened in non blocking mode, the function will
/// return error.WouldBlock when EAGAIN is received.

/// Accept a connection on a socket.
/// If `sockfd` is opened in non blocking mode, the function will
/// return error.WouldBlock when EAGAIN is received.
pub fn accept(
    /// This argument is a socket that has been created with `socket`, bound to a local address
    /// with `bind`, and is listening for connections after a `listen`.
    sock: socket_t,
    /// This argument is a pointer to a sockaddr structure.  This structure is filled in with  the
    /// address  of  the  peer  socket, as known to the communications layer.  The exact format of the
    /// address returned addr is determined by the socket's address  family  (see  `socket`  and  the
    /// respective  protocol  man  pages).
    addr: ?*sockaddr,
    /// This argument is a value-result argument: the caller must initialize it to contain  the
    /// size (in bytes) of the structure pointed to by addr; on return it will contain the actual size
    /// of the peer address.
    ///
    /// The returned address is truncated if the buffer provided is too small; in this  case,  `addr_size`
    /// will return a value greater than was supplied to the call.
    addr_size: ?*socklen_t,
    /// The following values can be bitwise ORed in flags to obtain different behavior:
    /// * `SOCK.NONBLOCK` - Set the `NONBLOCK` file status flag on the open file description (see `open`)
    ///   referred  to by the new file descriptor.  Using this flag saves extra calls to `fcntl` to achieve
    ///   the same result.
    /// * `SOCK.CLOEXEC`  - Set the close-on-exec (`FD_CLOEXEC`) flag on the new file descriptor.   See  the
    ///   description  of the `CLOEXEC` flag in `open` for reasons why this may be useful.
    flags: u32,
) AcceptError!socket_t {
    const have_accept4 = !(builtin.target.os.tag.isDarwin() or native_os == .windows or native_os == .haiku);
    assert(0 == (flags & ~@as(u32, SOCK.NONBLOCK | SOCK.CLOEXEC))); // Unsupported flag(s)

    const accepted_sock: socket_t = while (true) {
        const rc = if (have_accept4)
            system.accept4(sock, addr, addr_size, flags)
        else if (native_os == .windows)
            windows.accept(sock, addr, addr_size)
        else
            system.accept(sock, addr, addr_size);

        if (native_os == .windows) {
            if (rc == windows.ws2_32.INVALID_SOCKET) {
                switch (windows.ws2_32.WSAGetLastError()) {
                    .WSANOTINITIALISED => unreachable, // not initialized WSA
                    .WSAECONNRESET => return error.ConnectionResetByPeer,
                    .WSAEFAULT => unreachable,
                    .WSAENOTSOCK => return error.FileDescriptorNotASocket,
                    .WSAEINVAL => return error.SocketNotListening,
                    .WSAEMFILE => return error.ProcessFdQuotaExceeded,
                    .WSAENETDOWN => return error.NetworkSubsystemFailed,
                    .WSAENOBUFS => return error.FileDescriptorNotASocket,
                    .WSAEOPNOTSUPP => return error.OperationNotSupported,
                    .WSAEWOULDBLOCK => return error.WouldBlock,
                    else => |err| return windows.unexpectedWSAError(err),
                }
            } else {
                break rc;
            }
        } else {
            switch (errno(rc)) {
                .SUCCESS => break @intCast(rc),
                .INTR => continue,
                .AGAIN => return error.WouldBlock,
                .BADF => unreachable, // always a race condition
                .CONNABORTED => return error.ConnectionAborted,
                .FAULT => unreachable,
                .INVAL => return error.SocketNotListening,
                .NOTSOCK => unreachable,
                .MFILE => return error.ProcessFdQuotaExceeded,
                .NFILE => return error.SystemFdQuotaExceeded,
                .NOBUFS => return error.SystemResources,
                .NOMEM => return error.SystemResources,
                .OPNOTSUPP => unreachable,
                .PROTO => return error.ProtocolFailure,
                .PERM => return error.BlockedByFirewall,
                else => |err| return unexpectedErrno(err),
            }
        }
    };

    errdefer switch (native_os) {
        .windows => windows.closesocket(accepted_sock) catch unreachable,
        else => close(accepted_sock),
    };
    if (!have_accept4) {
        try setSockFlags(accepted_sock, flags);
    }
    return accepted_sock;
}

pub const SocketError = error{
    /// Permission to create a socket of the specified type and/or
    /// pro‐tocol is denied.
    AccessDenied,

    /// The implementation does not support the specified address family.
    AddressFamilyNotSupported,

    /// Unknown protocol, or protocol family not available.
    ProtocolFamilyNotAvailable,

    /// The per-process limit on the number of open file descriptors has been reached.
    ProcessFdQuotaExceeded,

    /// The system-wide limit on the total number of open files has been reached.
    SystemFdQuotaExceeded,

    /// Insufficient memory is available. The socket cannot be created until sufficient
    /// resources are freed.
    SystemResources,

    /// The protocol type or the specified protocol is not supported within this domain.
    ProtocolNotSupported,

    /// The socket type is not supported by the protocol.
    SocketTypeNotSupported,
} || UnexpectedError;

pub fn socket(domain: u32, socket_type: u32, protocol: u32) SocketError!socket_t {
    if (native_os == .windows) {
        // These flags are not actually part of the Windows API, instead they are converted here for compatibility
        const filtered_sock_type = socket_type & ~@as(u32, SOCK.NONBLOCK | SOCK.CLOEXEC);
        var flags: u32 = windows.ws2_32.WSA_FLAG_OVERLAPPED;
        if ((socket_type & SOCK.CLOEXEC) != 0) flags |= windows.ws2_32.WSA_FLAG_NO_HANDLE_INHERIT;

        const rc = try windows.WSASocketW(
            @bitCast(domain),
            @bitCast(filtered_sock_type),
            @bitCast(protocol),
            null,
            0,
            flags,
        );
        errdefer windows.closesocket(rc) catch unreachable;
        if ((socket_type & SOCK.NONBLOCK) != 0) {
            var mode: c_ulong = 1; // nonblocking
            if (windows.ws2_32.SOCKET_ERROR == windows.ws2_32.ioctlsocket(rc, windows.ws2_32.FIONBIO, &mode)) {
                switch (windows.ws2_32.WSAGetLastError()) {
                    // have not identified any error codes that should be handled yet
                    else => unreachable,
                }
            }
        }
        return rc;
    }

    const have_sock_flags = !builtin.target.os.tag.isDarwin() and native_os != .haiku;
    const filtered_sock_type = if (!have_sock_flags)
        socket_type & ~@as(u32, SOCK.NONBLOCK | SOCK.CLOEXEC)
    else
        socket_type;
    const rc = system.socket(domain, filtered_sock_type, protocol);
    switch (errno(rc)) {
        .SUCCESS => {
            const fd: fd_t = @intCast(rc);
            errdefer close(fd);
            if (!have_sock_flags) {
                try setSockFlags(fd, socket_type);
            }
            return fd;
        },
        .ACCES => return error.AccessDenied,
        .AFNOSUPPORT => return error.AddressFamilyNotSupported,
        .INVAL => return error.ProtocolFamilyNotAvailable,
        .MFILE => return error.ProcessFdQuotaExceeded,
        .NFILE => return error.SystemFdQuotaExceeded,
        .NOBUFS => return error.SystemResources,
        .NOMEM => return error.SystemResources,
        .PROTONOSUPPORT => return error.ProtocolNotSupported,
        .PROTOTYPE => return error.SocketTypeNotSupported,
        else => |err| return unexpectedErrno(err),
    }
}

pub const BindError = error{
    /// The address is protected, and the user is not the superuser.
    /// For UNIX domain sockets: Search permission is denied on  a  component
    /// of  the  path  prefix.
    AccessDenied,

    /// The given address is already in use, or in the case of Internet domain sockets,
    /// The  port number was specified as zero in the socket
    /// address structure, but, upon attempting to bind to  an  ephemeral  port,  it  was
    /// determined  that  all  port  numbers in the ephemeral port range are currently in
    /// use.  See the discussion of /proc/sys/net/ipv4/ip_local_port_range ip(7).
    AddressInUse,

    /// A nonexistent interface was requested or the requested address was not local.
    AddressNotAvailable,

    /// The address is not valid for the address family of socket.
    AddressFamilyNotSupported,

    /// Too many symbolic links were encountered in resolving addr.
    SymLinkLoop,

    /// addr is too long.
    NameTooLong,

    /// A component in the directory prefix of the socket pathname does not exist.
    FileNotFound,

    /// Insufficient kernel memory was available.
    SystemResources,

    /// A component of the path prefix is not a directory.
    NotDir,

    /// The socket inode would reside on a read-only filesystem.
    ReadOnlyFileSystem,

    /// The network subsystem has failed.
    NetworkSubsystemFailed,

    FileDescriptorNotASocket,

    AlreadyBound,
} || UnexpectedError;

/// addr is `*const T` where T is one of the sockaddr

/// addr is `*const T` where T is one of the sockaddr
pub fn bind(sock: socket_t, addr: *const sockaddr, len: socklen_t) BindError!void {
    if (native_os == .windows) {
        const rc = windows.bind(sock, addr, len);
        if (rc == windows.ws2_32.SOCKET_ERROR) {
            switch (windows.ws2_32.WSAGetLastError()) {
                .WSANOTINITIALISED => unreachable, // not initialized WSA
                .WSAEACCES => return error.AccessDenied,
                .WSAEADDRINUSE => return error.AddressInUse,
                .WSAEADDRNOTAVAIL => return error.AddressNotAvailable,
                .WSAENOTSOCK => return error.FileDescriptorNotASocket,
                .WSAEFAULT => unreachable, // invalid pointers
                .WSAEINVAL => return error.AlreadyBound,
                .WSAENOBUFS => return error.SystemResources,
                .WSAENETDOWN => return error.NetworkSubsystemFailed,
                else => |err| return windows.unexpectedWSAError(err),
            }
            unreachable;
        }
        return;
    } else {
        const rc = system.bind(sock, addr, len);
        switch (errno(rc)) {
            .SUCCESS => return,
            .ACCES, .PERM => return error.AccessDenied,
            .ADDRINUSE => return error.AddressInUse,
            .BADF => unreachable, // always a race condition if this error is returned
            .INVAL => unreachable, // invalid parameters
            .NOTSOCK => unreachable, // invalid `sockfd`
            .AFNOSUPPORT => return error.AddressFamilyNotSupported,
            .ADDRNOTAVAIL => return error.AddressNotAvailable,
            .FAULT => unreachable, // invalid `addr` pointer
            .LOOP => return error.SymLinkLoop,
            .NAMETOOLONG => return error.NameTooLong,
            .NOENT => return error.FileNotFound,
            .NOMEM => return error.SystemResources,
            .NOTDIR => return error.NotDir,
            .ROFS => return error.ReadOnlyFileSystem,
            else => |err| return unexpectedErrno(err),
        }
    }
    unreachable;
}

pub const ListenError = error{
    /// Another socket is already listening on the same port.
    /// For Internet domain sockets, the  socket referred to by sockfd had not previously
    /// been bound to an address and, upon attempting to bind it to an ephemeral port, it
    /// was determined that all port numbers in the ephemeral port range are currently in
    /// use.  See the discussion of /proc/sys/net/ipv4/ip_local_port_range in ip(7).
    AddressInUse,

    /// The file descriptor sockfd does not refer to a socket.
    FileDescriptorNotASocket,

    /// The socket is not of a type that supports the listen() operation.
    OperationNotSupported,

    /// The network subsystem has failed.
    NetworkSubsystemFailed,

    /// Ran out of system resources
    /// On Windows it can either run out of socket descriptors or buffer space
    SystemResources,

    /// Already connected
    AlreadyConnected,

    /// Socket has not been bound yet
    SocketNotBound,
} || UnexpectedError;

pub fn listen(sock: socket_t, backlog: u31) ListenError!void {
    if (native_os == .windows) {
        const rc = windows.listen(sock, backlog);
        if (rc == windows.ws2_32.SOCKET_ERROR) {
            switch (windows.ws2_32.WSAGetLastError()) {
                .WSANOTINITIALISED => unreachable, // not initialized WSA
                .WSAENETDOWN => return error.NetworkSubsystemFailed,
                .WSAEADDRINUSE => return error.AddressInUse,
                .WSAEISCONN => return error.AlreadyConnected,
                .WSAEINVAL => return error.SocketNotBound,
                .WSAEMFILE, .WSAENOBUFS => return error.SystemResources,
                .WSAENOTSOCK => return error.FileDescriptorNotASocket,
                .WSAEOPNOTSUPP => return error.OperationNotSupported,
                .WSAEINPROGRESS => unreachable,
                else => |err| return windows.unexpectedWSAError(err),
            }
        }
        return;
    } else {
        const rc = system.listen(sock, backlog);
        switch (errno(rc)) {
            .SUCCESS => return,
            .ADDRINUSE => return error.AddressInUse,
            .BADF => unreachable,
            .NOTSOCK => return error.FileDescriptorNotASocket,
            .OPNOTSUPP => return error.OperationNotSupported,
            else => |err| return unexpectedErrno(err),
        }
    }
}

pub const ConnectError = error{
    /// For UNIX domain sockets, which are identified by pathname: Write permission is denied on  the  socket
    /// file,  or  search  permission  is  denied  for  one of the directories in the path prefix.
    /// or
    /// The user tried to connect to a broadcast address without having the socket broadcast flag enabled  or
    /// the connection request failed because of a local firewall rule.
    AccessDenied,

    /// See AccessDenied
    PermissionDenied,

    /// Local address is already in use.
    AddressInUse,

    /// (Internet  domain  sockets)  The  socket  referred  to  by sockfd had not previously been bound to an
    /// address and, upon attempting to bind it to an ephemeral port, it was determined that all port numbers
    /// in    the    ephemeral    port    range    are   currently   in   use.    See   the   discussion   of
    /// /proc/sys/net/ipv4/ip_local_port_range in ip(7).
    AddressNotAvailable,

    /// The passed address didn't have the correct address family in its sa_family field.
    AddressFamilyNotSupported,

    /// Insufficient entries in the routing cache.
    SystemResources,

    /// A connect() on a stream socket found no one listening on the remote address.
    ConnectionRefused,

    /// Network is unreachable.
    NetworkUnreachable,

    /// Timeout  while  attempting  connection.   The server may be too busy to accept new connections.  Note
    /// that for IP sockets the timeout may be very long when syncookies are enabled on the server.
    ConnectionTimedOut,

    /// This error occurs when no global event loop is configured,
    /// and connecting to the socket would block.
    WouldBlock,

    /// The given path for the unix socket does not exist.
    FileNotFound,

    /// Connection was reset by peer before connect could complete.
    ConnectionResetByPeer,

    /// Socket is non-blocking and already has a pending connection in progress.
    ConnectionPending,
} || UnexpectedError;

/// Initiate a connection on a socket.
/// If `sockfd` is opened in non blocking mode, the function will
/// return error.WouldBlock when EAGAIN or EINPROGRESS is received.

/// Initiate a connection on a socket.
/// If `sockfd` is opened in non blocking mode, the function will
/// return error.WouldBlock when EAGAIN or EINPROGRESS is received.
pub fn connect(sock: socket_t, sock_addr: *const sockaddr, len: socklen_t) ConnectError!void {
    if (native_os == .windows) {
        const rc = windows.ws2_32.connect(sock, sock_addr, @intCast(len));
        if (rc == 0) return;
        switch (windows.ws2_32.WSAGetLastError()) {
            .WSAEADDRINUSE => return error.AddressInUse,
            .WSAEADDRNOTAVAIL => return error.AddressNotAvailable,
            .WSAECONNREFUSED => return error.ConnectionRefused,
            .WSAECONNRESET => return error.ConnectionResetByPeer,
            .WSAETIMEDOUT => return error.ConnectionTimedOut,
            .WSAEHOSTUNREACH, // TODO: should we return NetworkUnreachable in this case as well?
            .WSAENETUNREACH,
            => return error.NetworkUnreachable,
            .WSAEFAULT => unreachable,
            .WSAEINVAL => unreachable,
            .WSAEISCONN => unreachable,
            .WSAENOTSOCK => unreachable,
            .WSAEWOULDBLOCK => return error.WouldBlock,
            .WSAEACCES => unreachable,
            .WSAENOBUFS => return error.SystemResources,
            .WSAEAFNOSUPPORT => return error.AddressFamilyNotSupported,
            else => |err| return windows.unexpectedWSAError(err),
        }
        return;
    }

    while (true) {
        switch (errno(system.connect(sock, sock_addr, len))) {
            .SUCCESS => return,
            .ACCES => return error.AccessDenied,
            .PERM => return error.PermissionDenied,
            .ADDRINUSE => return error.AddressInUse,
            .ADDRNOTAVAIL => return error.AddressNotAvailable,
            .AFNOSUPPORT => return error.AddressFamilyNotSupported,
            .AGAIN, .INPROGRESS => return error.WouldBlock,
            .ALREADY => return error.ConnectionPending,
            .BADF => unreachable, // sockfd is not a valid open file descriptor.
            .CONNREFUSED => return error.ConnectionRefused,
            .CONNRESET => return error.ConnectionResetByPeer,
            .FAULT => unreachable, // The socket structure address is outside the user's address space.
            .INTR => continue,
            .ISCONN => unreachable, // The socket is already connected.
            .HOSTUNREACH => return error.NetworkUnreachable,
            .NETUNREACH => return error.NetworkUnreachable,
            .NOTSOCK => unreachable, // The file descriptor sockfd does not refer to a socket.
            .PROTOTYPE => unreachable, // The socket type does not support the requested communications protocol.
            .TIMEDOUT => return error.ConnectionTimedOut,
            .NOENT => return error.FileNotFound, // Returned when socket is AF.UNIX and the given path does not exist.
            .CONNABORTED => unreachable, // Tried to reuse socket that previously received error.ConnectionRefused.
            else => |err| return unexpectedErrno(err),
        }
    }
}

/// Get an environment variable.
/// See also `getenvZ`.
pub fn getenv(key: []const u8) ?[:0]const u8 {
    if (native_os == .windows) {
        @compileError("std.posix.getenv is unavailable for Windows because environment strings are in WTF-16 format. See std.process.getEnvVarOwned for a cross-platform API or std.process.getenvW for a Windows-specific API.");
    }
    if (mem.indexOfScalar(u8, key, '=') != null) {
        return null;
    }
    if (builtin.link_libc) {
        var ptr = std.c.environ;
        while (ptr[0]) |line| : (ptr += 1) {
            var line_i: usize = 0;
            while (line[line_i] != 0) : (line_i += 1) {
                if (line_i == key.len) break;
                if (line[line_i] != key[line_i]) break;
            }
            if ((line_i != key.len) or (line[line_i] != '=')) continue;

            return mem.sliceTo(line + line_i + 1, 0);
        }
        return null;
    }
    if (native_os == .wasi) {
        @compileError("std.posix.getenv is unavailable for WASI. See std.process.getEnvMap or std.process.getEnvVarOwned for a cross-platform API.");
    }
    // The simplified start logic doesn't populate environ.
    if (std.start.simplified_logic) return null;
    // TODO see https://github.com/ziglang/zig/issues/4524
    for (std.os.environ) |ptr| {
        var line_i: usize = 0;
        while (ptr[line_i] != 0) : (line_i += 1) {
            if (line_i == key.len) break;
            if (ptr[line_i] != key[line_i]) break;
        }
        if ((line_i != key.len) or (ptr[line_i] != '=')) continue;

        return mem.sliceTo(ptr + line_i + 1, 0);
    }
    return null;
}

/// Get an environment variable with a null-terminated name.
/// See also `getenv`.

/// Exits all threads of the program with the specified status code.
pub fn exit(status: u8) noreturn {
    if (builtin.link_libc) {
        std.c.exit(status);
    }
    if (native_os == .windows) {
        windows.kernel32.ExitProcess(status);
    }
    if (native_os == .wasi) {
        wasi.proc_exit(status);
    }
    if (native_os == .linux and !builtin.single_threaded) {
        linux.exit_group(status);
    }
    if (native_os == .uefi) {
        const uefi = std.os.uefi;
        // exit() is only available if exitBootServices() has not been called yet.
        // This call to exit should not fail, so we catch-ignore errors.
        if (uefi.system_table.boot_services) |bs| {
            bs.exit(uefi.handle, @enumFromInt(status), null) catch {};
        }
        // If we can't exit, reboot the system instead.
        uefi.system_table.runtime_services.resetSystem(.cold, @enumFromInt(status), null);
    }
    system.exit(status);
}

pub const SymLinkError = error{
    /// In WASI, this error may occur when the file descriptor does
    /// not hold the required rights to create a new symbolic link relative to it.
    AccessDenied,
    PermissionDenied,
    DiskQuota,
    PathAlreadyExists,
    FileSystem,
    SymLinkLoop,
    FileNotFound,
    SystemResources,
    NoSpaceLeft,
    ReadOnlyFileSystem,
    NotDir,
    NameTooLong,

    /// WASI-only; file paths must be valid UTF-8.
    InvalidUtf8,

    /// Windows-only; file paths provided by the user must be valid WTF-8.
    /// https://simonsapin.github.io/wtf-8/
    InvalidWtf8,

    BadPathName,
} || UnexpectedError;

/// Creates a symbolic link named `sym_link_path` which contains the string `target_path`.
/// A symbolic link (also known as a soft link) may point to an existing file or to a nonexistent
/// one; the latter case is known as a dangling link.
/// On Windows, both paths should be encoded as [WTF-8](https://simonsapin.github.io/wtf-8/).
/// On WASI, both paths should be encoded as valid UTF-8.
/// On other platforms, both paths are an opaque sequence of bytes with no particular encoding.
/// If `sym_link_path` exists, it will not be overwritten.
/// See also `symlinkZ.

/// Creates a symbolic link named `sym_link_path` which contains the string `target_path`.
/// A symbolic link (also known as a soft link) may point to an existing file or to a nonexistent
/// one; the latter case is known as a dangling link.
/// On Windows, both paths should be encoded as [WTF-8](https://simonsapin.github.io/wtf-8/).
/// On WASI, both paths should be encoded as valid UTF-8.
/// On other platforms, both paths are an opaque sequence of bytes with no particular encoding.
/// If `sym_link_path` exists, it will not be overwritten.
/// See also `symlinkZ.
pub fn symlink(target_path: []const u8, sym_link_path: []const u8) SymLinkError!void {
    if (native_os == .windows) {
        @compileError("symlink is not supported on Windows; use std.os.windows.CreateSymbolicLink instead");
    } else if (native_os == .wasi and !builtin.link_libc) {
        return symlinkat(target_path, AT.FDCWD, sym_link_path);
    }
    const target_path_c = try toPosixPath(target_path);
    const sym_link_path_c = try toPosixPath(sym_link_path);
    return symlinkZ(&target_path_c, &sym_link_path_c);
}

/// This is the same as `symlink` except the parameters are null-terminated pointers.
/// See also `symlink`.

/// This is the same as `symlink` except the parameters are null-terminated pointers.
/// See also `symlink`.
pub fn symlinkZ(target_path: [*:0]const u8, sym_link_path: [*:0]const u8) SymLinkError!void {
    if (native_os == .windows) {
        @compileError("symlink is not supported on Windows; use std.os.windows.CreateSymbolicLink instead");
    } else if (native_os == .wasi and !builtin.link_libc) {
        return symlinkatZ(target_path, fs.cwd().fd, sym_link_path);
    }
    switch (errno(system.symlink(target_path, sym_link_path))) {
        .SUCCESS => return,
        .FAULT => unreachable,
        .INVAL => unreachable,
        .ACCES => return error.AccessDenied,
        .PERM => return error.PermissionDenied,
        .DQUOT => return error.DiskQuota,
        .EXIST => return error.PathAlreadyExists,
        .IO => return error.FileSystem,
        .LOOP => return error.SymLinkLoop,
        .NAMETOOLONG => return error.NameTooLong,
        .NOENT => return error.FileNotFound,
        .NOTDIR => return error.NotDir,
        .NOMEM => return error.SystemResources,
        .NOSPC => return error.NoSpaceLeft,
        .ROFS => return error.ReadOnlyFileSystem,
        .ILSEQ => |err| if (native_os == .wasi)
            return error.InvalidUtf8
        else
            return unexpectedErrno(err),
        else => |err| return unexpectedErrno(err),
    }
}

/// Similar to `symlink`, however, creates a symbolic link named `sym_link_path` which contains the string
/// `target_path` **relative** to `newdirfd` directory handle.
/// A symbolic link (also known as a soft link) may point to an existing file or to a nonexistent
/// one; the latter case is known as a dangling link.
/// On Windows, both paths should be encoded as [WTF-8](https://simonsapin.github.io/wtf-8/).
/// On WASI, both paths should be encoded as valid UTF-8.
/// On other platforms, both paths are an opaque sequence of bytes with no particular encoding.
/// If `sym_link_path` exists, it will not be overwritten.
/// See also `symlinkatWasi`, `symlinkatZ` and `symlinkatW`.

pub const ClockGetTimeError = error{UnsupportedClock} || UnexpectedError;

pub fn clock_gettime(clock_id: clockid_t) ClockGetTimeError!timespec {
    var tp: timespec = undefined;

    if (native_os == .windows) {
        @compileError("Windows does not support POSIX; use Windows-specific API or cross-platform std.time API");
    } else if (native_os == .wasi and !builtin.link_libc) {
        var ts: timestamp_t = undefined;
        switch (system.clock_time_get(clock_id, 1, &ts)) {
            .SUCCESS => {
                tp = .{
                    .sec = @intCast(ts / std.time.ns_per_s),
                    .nsec = @intCast(ts % std.time.ns_per_s),
                };
            },
            .INVAL => return error.UnsupportedClock,
            else => |err| return unexpectedErrno(err),
        }
        return tp;
    }

    switch (errno(system.clock_gettime(clock_id, &tp))) {
        .SUCCESS => return tp,
        .FAULT => unreachable,
        .INVAL => return error.UnsupportedClock,
        else => |err| return unexpectedErrno(err),
    }
}

fn setSockFlags(sock: socket_t, flags: u32) !void {
    if ((flags & SOCK.CLOEXEC) != 0) {
        if (native_os == .windows) {
            // TODO: Find out if this is supported for sockets
        } else {
            var fd_flags = fcntl(sock, F.GETFD, 0) catch |err| switch (err) {
                error.FileBusy => unreachable,
                error.Locked => unreachable,
                error.PermissionDenied => unreachable,
                error.DeadLock => unreachable,
                error.LockedRegionLimitExceeded => unreachable,
                else => |e| return e,
            };
            fd_flags |= FD_CLOEXEC;
            _ = fcntl(sock, F.SETFD, fd_flags) catch |err| switch (err) {
                error.FileBusy => unreachable,
                error.Locked => unreachable,
                error.PermissionDenied => unreachable,
                error.DeadLock => unreachable,
                error.LockedRegionLimitExceeded => unreachable,
                else => |e| return e,
            };
        }
    }
    if ((flags & SOCK.NONBLOCK) != 0) {
        if (native_os == .windows) {
            var mode: c_ulong = 1;
            if (windows.ws2_32.ioctlsocket(sock, windows.ws2_32.FIONBIO, &mode) == windows.ws2_32.SOCKET_ERROR) {
                switch (windows.ws2_32.WSAGetLastError()) {
                    .WSANOTINITIALISED => unreachable,
                    .WSAENETDOWN => return error.NetworkSubsystemFailed,
                    .WSAENOTSOCK => return error.FileDescriptorNotASocket,
                    // TODO: handle more errors
                    else => |err| return windows.unexpectedWSAError(err),
                }
            }
        } else {
            var fl_flags = fcntl(sock, F.GETFL, 0) catch |err| switch (err) {
                error.FileBusy => unreachable,
                error.Locked => unreachable,
                error.PermissionDenied => unreachable,
                error.DeadLock => unreachable,
                error.LockedRegionLimitExceeded => unreachable,
                else => |e| return e,
            };
            fl_flags |= 1 << @bitOffsetOf(O, "NONBLOCK");
            _ = fcntl(sock, F.SETFL, fl_flags) catch |err| switch (err) {
                error.FileBusy => unreachable,
                error.Locked => unreachable,
                error.PermissionDenied => unreachable,
                error.DeadLock => unreachable,
                error.LockedRegionLimitExceeded => unreachable,
                else => |e| return e,
            };
        }
    }
}


// ---------------------------------------------------------------------------
// std.time (0.15.2)
// ---------------------------------------------------------------------------

/// Get a calendar timestamp, in seconds, relative to UTC 1970-01-01.
/// Precision of timing depends on the hardware and operating system.
/// The return value is signed because it is possible to have a date that is
/// before the epoch.
/// See `clock_gettime` for a POSIX timestamp.
pub fn timestamp() i64 {
    return @divFloor(milliTimestamp(), ms_per_s);
}

/// Get a calendar timestamp, in milliseconds, relative to UTC 1970-01-01.
/// Precision of timing depends on the hardware and operating system.
/// The return value is signed because it is possible to have a date that is
/// before the epoch.
/// See `clock_gettime` for a POSIX timestamp.

/// Get a calendar timestamp, in milliseconds, relative to UTC 1970-01-01.
/// Precision of timing depends on the hardware and operating system.
/// The return value is signed because it is possible to have a date that is
/// before the epoch.
/// See `clock_gettime` for a POSIX timestamp.
pub fn milliTimestamp() i64 {
    return @as(i64, @intCast(@divFloor(nanoTimestamp(), ns_per_ms)));
}

/// Get a calendar timestamp, in microseconds, relative to UTC 1970-01-01.
/// Precision of timing depends on the hardware and operating system.
/// The return value is signed because it is possible to have a date that is
/// before the epoch.
/// See `clock_gettime` for a POSIX timestamp.

/// Get a calendar timestamp, in microseconds, relative to UTC 1970-01-01.
/// Precision of timing depends on the hardware and operating system.
/// The return value is signed because it is possible to have a date that is
/// before the epoch.
/// See `clock_gettime` for a POSIX timestamp.
pub fn microTimestamp() i64 {
    return @as(i64, @intCast(@divFloor(nanoTimestamp(), ns_per_us)));
}

/// Get a calendar timestamp, in nanoseconds, relative to UTC 1970-01-01.
/// Precision of timing depends on the hardware and operating system.
/// On Windows this has a maximum granularity of 100 nanoseconds.
/// The return value is signed because it is possible to have a date that is
/// before the epoch.
/// See `clock_gettime` for a POSIX timestamp.

/// Get a calendar timestamp, in nanoseconds, relative to UTC 1970-01-01.
/// Precision of timing depends on the hardware and operating system.
/// On Windows this has a maximum granularity of 100 nanoseconds.
/// The return value is signed because it is possible to have a date that is
/// before the epoch.
/// See `clock_gettime` for a POSIX timestamp.
pub fn nanoTimestamp() i128 {
    switch (builtin.os.tag) {
        .windows => {
            // RtlGetSystemTimePrecise() has a granularity of 100 nanoseconds and uses the NTFS/Windows epoch,
            // which is 1601-01-01.
            const epoch_adj = epoch.windows * (ns_per_s / 100);
            return @as(i128, windows.ntdll.RtlGetSystemTimePrecise() + epoch_adj) * 100;
        },
        .wasi => {
            var ns: std.os.wasi.timestamp_t = undefined;
            const err = std.os.wasi.clock_time_get(.REALTIME, 1, &ns);
            assert(err == .SUCCESS);
            return ns;
        },
        .uefi => {
            const value, _ = std.os.uefi.system_table.runtime_services.getTime() catch return 0;
            return value.toEpoch();
        },
        else => {
            const ts = clock_gettime(.REALTIME) catch |err| switch (err) {
                error.UnsupportedClock, error.Unexpected => return 0, // "Precision of timing depends on hardware and OS".
            };
            return (@as(i128, ts.sec) * ns_per_s) + ts.nsec;
        },
    }
}

test milliTimestamp {
    const time_0 = milliTimestamp();
    sleep(ns_per_ms);
    const time_1 = milliTimestamp();
    const interval = time_1 - time_0;
    try testing.expect(interval > 0);
}

// Divisions of a nanosecond.

/// An Instant represents a timestamp with respect to the currently
/// executing program that ticks during suspend and can be used to
/// record elapsed time unlike `nanoTimestamp`.
///
/// It tries to sample the system's fastest and most precise timer available.
/// It also tries to be monotonic, but this is not a guarantee due to OS/hardware bugs.
/// If you need monotonic readings for elapsed time, consider `Timer` instead.
pub const Instant = struct {
    timestamp: if (is_posix) posix.timespec else u64,

    // true if we should use clock_gettime()
    const is_posix = switch (builtin.os.tag) {
        .windows, .uefi, .wasi => false,
        else => true,
    };

    /// Queries the system for the current moment of time as an Instant.
    /// This is not guaranteed to be monotonic or steadily increasing, but for
    /// most implementations it is.
    /// Returns `error.Unsupported` when a suitable clock is not detected.
    pub fn now() error{Unsupported}!Instant {
        const clock_id = switch (builtin.os.tag) {
            .windows => {
                // QPC on windows doesn't fail on >= XP/2000 and includes time suspended.
                return .{ .timestamp = windows.QueryPerformanceCounter() };
            },
            .wasi => {
                var ns: std.os.wasi.timestamp_t = undefined;
                const rc = std.os.wasi.clock_time_get(.MONOTONIC, 1, &ns);
                if (rc != .SUCCESS) return error.Unsupported;
                return .{ .timestamp = ns };
            },
            .uefi => {
                const value, _ = std.os.uefi.system_table.runtime_services.getTime() catch return error.Unsupported;
                return .{ .timestamp = value.toEpoch() };
            },
            // On darwin, use UPTIME_RAW instead of MONOTONIC as it ticks while
            // suspended.
            .macos, .ios, .tvos, .watchos, .visionos => posix.CLOCK.UPTIME_RAW,
            // On freebsd derivatives, use MONOTONIC_FAST as currently there's
            // no precision tradeoff.
            .freebsd, .dragonfly => posix.CLOCK.MONOTONIC_FAST,
            // On linux, use BOOTTIME instead of MONOTONIC as it ticks while
            // suspended.
            .linux => posix.CLOCK.BOOTTIME,
            // On other posix systems, MONOTONIC is generally the fastest and
            // ticks while suspended.
            else => posix.CLOCK.MONOTONIC,
        };

        const ts = clock_gettime(clock_id) catch return error.Unsupported;
        return .{ .timestamp = ts };
    }

    /// Quickly compares two instances between each other.
    pub fn order(self: Instant, other: Instant) std.math.Order {
        // windows and wasi timestamps are in u64 which is easily comparible
        if (!is_posix) {
            return std.math.order(self.timestamp, other.timestamp);
        }

        var ord = std.math.order(self.timestamp.sec, other.timestamp.sec);
        if (ord == .eq) {
            ord = std.math.order(self.timestamp.nsec, other.timestamp.nsec);
        }
        return ord;
    }

    /// Returns elapsed time in nanoseconds since the `earlier` Instant.
    /// This assumes that the `earlier` Instant represents a moment in time before or equal to `self`.
    /// This also assumes that the time that has passed between both Instants fits inside a u64 (~585 yrs).
    pub fn since(self: Instant, earlier: Instant) u64 {
        switch (builtin.os.tag) {
            .windows => {
                // We don't need to cache QPF as it's internally just a memory read to KUSER_SHARED_DATA
                // (a read-only page of info updated and mapped by the kernel to all processes):
                // https://docs.microsoft.com/en-us/windows-hardware/drivers/ddi/ntddk/ns-ntddk-kuser_shared_data
                // https://www.geoffchappell.com/studies/windows/km/ntoskrnl/inc/api/ntexapi_x/kuser_shared_data/index.htm
                const qpc = self.timestamp - earlier.timestamp;
                const qpf = windows.QueryPerformanceFrequency();

                // 10Mhz (1 qpc tick every 100ns) is a common enough QPF value that we can optimize on it.
                // https://github.com/microsoft/STL/blob/785143a0c73f030238ef618890fd4d6ae2b3a3a0/stl/inc/chrono#L694-L701
                const common_qpf = 10_000_000;
                if (qpf == common_qpf) {
                    return qpc * (ns_per_s / common_qpf);
                }

                // Convert to ns using fixed point.
                const scale = @as(u64, std.time.ns_per_s << 32) / @as(u32, @intCast(qpf));
                const result = (@as(u96, qpc) * scale) >> 32;
                return @as(u64, @truncate(result));
            },
            .uefi, .wasi => {
                // UEFI and WASI timestamps are directly in nanoseconds
                return self.timestamp - earlier.timestamp;
            },
            else => {
                // Convert timespec diff to ns
                const seconds = @as(u64, @intCast(self.timestamp.sec - earlier.timestamp.sec));
                const elapsed = (seconds * ns_per_s) + @as(u32, @intCast(self.timestamp.nsec));
                return elapsed - @as(u32, @intCast(earlier.timestamp.nsec));
            },
        }
    }
};

/// A monotonic, high performance timer.
///
/// Timer.start() is used to initialize the timer
/// and gives the caller an opportunity to check for the existence of a supported clock.
/// Once a supported clock is discovered,
/// it is assumed that it will be available for the duration of the Timer's use.
///
/// Monotonicity is ensured by saturating on the most previous sample.
/// This means that while timings reported are monotonic,
/// they're not guaranteed to tick at a steady rate as this is up to the underlying system.

/// A monotonic, high performance timer.
///
/// Timer.start() is used to initialize the timer
/// and gives the caller an opportunity to check for the existence of a supported clock.
/// Once a supported clock is discovered,
/// it is assumed that it will be available for the duration of the Timer's use.
///
/// Monotonicity is ensured by saturating on the most previous sample.
/// This means that while timings reported are monotonic,
/// they're not guaranteed to tick at a steady rate as this is up to the underlying system.
pub const Timer = struct {
    started: Instant,
    previous: Instant,

    pub const Error = error{TimerUnsupported};

    /// Initialize the timer by querying for a supported clock.
    /// Returns `error.TimerUnsupported` when such a clock is unavailable.
    /// This should only fail in hostile environments such as linux seccomp misuse.
    pub fn start() Error!Timer {
        const current = Instant.now() catch return error.TimerUnsupported;
        return Timer{ .started = current, .previous = current };
    }

    /// Reads the timer value since start or the last reset in nanoseconds.
    pub fn read(self: *Timer) u64 {
        const current = self.sample();
        return current.since(self.started);
    }

    /// Resets the timer value to 0/now.
    pub fn reset(self: *Timer) void {
        const current = self.sample();
        self.started = current;
    }

    /// Returns the current value of the timer in nanoseconds, then resets it.
    pub fn lap(self: *Timer) u64 {
        const current = self.sample();
        defer self.started = current;
        return current.since(self.started);
    }

    /// Returns an Instant sampled at the callsite that is
    /// guaranteed to be monotonic with respect to the timer's starting point.
    fn sample(self: *Timer) Instant {
        const current = Instant.now() catch unreachable;
        if (current.order(self.previous) == .gt) {
            self.previous = current;
        }
        return self.previous;
    }
};

test Timer {
    var timer = try Timer.start();

    sleep(10 * ns_per_ms);
    const time_0 = timer.read();
    try testing.expect(time_0 > 0);

    const time_1 = timer.lap();
    try testing.expect(time_1 >= time_0);
}

test {
    _ = epoch;
}

// ---------------------------------------------------------------------------
// Unix-socket helpers (replacing the std.net surface used by hty; Io.net has
// no unix-socket support in 0.16)
// ---------------------------------------------------------------------------

pub const Stream = struct {
    handle: socket_t,

    pub fn close(s: Stream) void {
        sys.close(s.handle);
    }

    pub fn read(s: Stream, buffer: []u8) posix.ReadError!usize {
        return posix.read(s.handle, buffer);
    }

    pub fn write(s: Stream, buffer: []const u8) !usize {
        return sys.write(s.handle, buffer);
    }

    pub fn writeAll(s: Stream, bytes: []const u8) !void {
        var index: usize = 0;
        while (index < bytes.len) {
            index += try sys.write(s.handle, bytes[index..]);
        }
    }
};

fn unixSockaddr(path: []const u8) error{NameTooLong}!sockaddr.un {
    var sa: sockaddr.un = std.mem.zeroes(sockaddr.un);
    sa.family = posix.AF.UNIX;
    if (path.len >= sa.path.len) return error.NameTooLong;
    @memcpy(sa.path[0..path.len], path);
    return sa;
}

pub fn connectUnixSocket(path: []const u8) !Stream {
    const sockfd = try socket(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0);
    errdefer close(sockfd);
    var sa = try unixSockaddr(path);
    try connect(sockfd, @ptrCast(&sa), @sizeOf(sockaddr.un));
    return .{ .handle = sockfd };
}

pub const UnixServer = struct {
    stream: Stream,

    pub fn deinit(s: *UnixServer) void {
        s.stream.close();
        s.* = undefined;
    }
};

pub fn listenUnix(path: []const u8, backlog: u31) !UnixServer {
    const sockfd = try socket(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0);
    errdefer close(sockfd);
    var sa = try unixSockaddr(path);
    try bind(sockfd, @ptrCast(&sa), @sizeOf(sockaddr.un));
    try listen(sockfd, backlog);
    return .{ .stream = .{ .handle = sockfd } };
}

// transitive helpers (0.15.2)
pub const UnlinkatError = UnlinkError || error{
    /// When passing `AT.REMOVEDIR`, this error occurs when the named directory is not empty.
    DirNotEmpty,
};

/// Delete a file name and possibly the file it refers to, based on an open directory handle.
/// On Windows, `file_path` should be encoded as [WTF-8](https://simonsapin.github.io/wtf-8/).
/// On WASI, `file_path` should be encoded as valid UTF-8.
/// On other platforms, `file_path` is an opaque sequence of bytes with no particular encoding.
/// Asserts that the path parameter has no null bytes.

pub fn unlinkat(dirfd: fd_t, file_path: []const u8, flags: u32) UnlinkatError!void {
    if (native_os == .windows) {
        const file_path_w = try windows.sliceToPrefixedFileW(dirfd, file_path);
        return unlinkatW(dirfd, file_path_w.span(), flags);
    } else if (native_os == .wasi and !builtin.link_libc) {
        return unlinkatWasi(dirfd, file_path, flags);
    } else {
        const file_path_c = try toPosixPath(file_path);
        return unlinkatZ(dirfd, &file_path_c, flags);
    }
}

/// WASI-only. Same as `unlinkat` but targeting WASI.
/// See also `unlinkat`.

pub fn unlinkatZ(dirfd: fd_t, file_path_c: [*:0]const u8, flags: u32) UnlinkatError!void {
    if (native_os == .windows) {
        const file_path_w = try windows.cStrToPrefixedFileW(dirfd, file_path_c);
        return unlinkatW(dirfd, file_path_w.span(), flags);
    } else if (native_os == .wasi and !builtin.link_libc) {
        return unlinkat(dirfd, mem.sliceTo(file_path_c, 0), flags);
    }
    switch (errno(system.unlinkat(dirfd, file_path_c, flags))) {
        .SUCCESS => return,
        .ACCES => return error.AccessDenied,
        .PERM => return error.PermissionDenied,
        .BUSY => return error.FileBusy,
        .FAULT => unreachable,
        .IO => return error.FileSystem,
        .ISDIR => return error.IsDir,
        .LOOP => return error.SymLinkLoop,
        .NAMETOOLONG => return error.NameTooLong,
        .NOENT => return error.FileNotFound,
        .NOTDIR => return error.NotDir,
        .NOMEM => return error.SystemResources,
        .ROFS => return error.ReadOnlyFileSystem,
        .EXIST => return error.DirNotEmpty,
        .NOTEMPTY => return error.DirNotEmpty,
        .ILSEQ => |err| if (native_os == .wasi)
            return error.InvalidUtf8
        else
            return unexpectedErrno(err),

        .INVAL => unreachable, // invalid flags, or pathname has . as last component
        .BADF => unreachable, // always a race condition

        else => |err| return unexpectedErrno(err),
    }
}

/// Same as `unlinkat` but `sub_path_w` is WTF16LE, NT prefixed. Windows only.

pub fn unlinkW(file_path_w: []const u16) UnlinkError!void {
    windows.DeleteFile(file_path_w, .{ .dir = fs.cwd().fd }) catch |err| switch (err) {
        error.DirNotEmpty => unreachable, // we're not passing .remove_dir = true
        else => |e| return e,
    };
}

pub const SendMsgError = SendError || error{
    /// The passed address didn't have the correct address family in its sa_family field.
    AddressFamilyNotSupported,

    /// Returned when socket is AF.UNIX and the given path has a symlink loop.
    SymLinkLoop,

    /// Returned when socket is AF.UNIX and the given path length exceeds `max_path_bytes` bytes.
    NameTooLong,

    /// Returned when socket is AF.UNIX and the given path does not point to an existing file.
    FileNotFound,
    NotDir,

    /// The socket is not connected (connection-oriented sockets only).
    SocketNotConnected,
    AddressNotAvailable,
};

pub fn sendto(
    /// The file descriptor of the sending socket.
    sockfd: socket_t,
    /// Message to send.
    buf: []const u8,
    flags: u32,
    dest_addr: ?*const sockaddr,
    addrlen: socklen_t,
) SendToError!usize {
    if (native_os == .windows) {
        switch (windows.sendto(sockfd, buf.ptr, buf.len, flags, dest_addr, addrlen)) {
            windows.ws2_32.SOCKET_ERROR => switch (windows.ws2_32.WSAGetLastError()) {
                .WSAEACCES => return error.AccessDenied,
                .WSAEADDRNOTAVAIL => return error.AddressNotAvailable,
                .WSAECONNRESET => return error.ConnectionResetByPeer,
                .WSAEMSGSIZE => return error.MessageTooBig,
                .WSAENOBUFS => return error.SystemResources,
                .WSAENOTSOCK => return error.FileDescriptorNotASocket,
                .WSAEAFNOSUPPORT => return error.AddressFamilyNotSupported,
                .WSAEDESTADDRREQ => unreachable, // A destination address is required.
                .WSAEFAULT => unreachable, // The lpBuffers, lpTo, lpOverlapped, lpNumberOfBytesSent, or lpCompletionRoutine parameters are not part of the user address space, or the lpTo parameter is too small.
                .WSAEHOSTUNREACH => return error.NetworkUnreachable,
                // TODO: WSAEINPROGRESS, WSAEINTR
                .WSAEINVAL => unreachable,
                .WSAENETDOWN => return error.NetworkSubsystemFailed,
                .WSAENETRESET => return error.ConnectionResetByPeer,
                .WSAENETUNREACH => return error.NetworkUnreachable,
                .WSAENOTCONN => return error.SocketNotConnected,
                .WSAESHUTDOWN => unreachable, // The socket has been shut down; it is not possible to WSASendTo on a socket after shutdown has been invoked with how set to SD_SEND or SD_BOTH.
                .WSAEWOULDBLOCK => return error.WouldBlock,
                .WSANOTINITIALISED => unreachable, // A successful WSAStartup call must occur before using this function.
                else => |err| return windows.unexpectedWSAError(err),
            },
            else => |rc| return @intCast(rc),
        }
    }
    while (true) {
        const rc = system.sendto(sockfd, buf.ptr, buf.len, flags, dest_addr, addrlen);
        switch (errno(rc)) {
            .SUCCESS => return @intCast(rc),

            .ACCES => return error.AccessDenied,
            .AGAIN => return error.WouldBlock,
            .ALREADY => return error.FastOpenAlreadyInProgress,
            .BADF => unreachable, // always a race condition
            .CONNREFUSED => return error.ConnectionRefused,
            .CONNRESET => return error.ConnectionResetByPeer,
            .DESTADDRREQ => unreachable, // The socket is not connection-mode, and no peer address is set.
            .FAULT => unreachable, // An invalid user space address was specified for an argument.
            .INTR => continue,
            .INVAL => return error.UnreachableAddress,
            .ISCONN => unreachable, // connection-mode socket was connected already but a recipient was specified
            .MSGSIZE => return error.MessageTooBig,
            .NOBUFS => return error.SystemResources,
            .NOMEM => return error.SystemResources,
            .NOTSOCK => unreachable, // The file descriptor sockfd does not refer to a socket.
            .OPNOTSUPP => unreachable, // Some bit in the flags argument is inappropriate for the socket type.
            .PIPE => return error.BrokenPipe,
            .AFNOSUPPORT => return error.AddressFamilyNotSupported,
            .LOOP => return error.SymLinkLoop,
            .NAMETOOLONG => return error.NameTooLong,
            .NOENT => return error.FileNotFound,
            .NOTDIR => return error.NotDir,
            .HOSTUNREACH => return error.NetworkUnreachable,
            .NETUNREACH => return error.NetworkUnreachable,
            .NOTCONN => return error.SocketNotConnected,
            .NETDOWN => return error.NetworkSubsystemFailed,
            else => |err| return unexpectedErrno(err),
        }
    }
}

/// Transmit a message to another socket.
///
/// The `send` call may be used only when the socket is in a connected state (so that the intended
/// recipient  is  known).   The  only  difference  between `send` and `write` is the presence of
/// flags.  With a zero flags argument, `send` is equivalent to  `write`.   Also,  the  following
/// call
///
///     send(sockfd, buf, len, flags);
///
/// is equivalent to
///
///     sendto(sockfd, buf, len, flags, NULL, 0);
///
/// There is no  indication  of  failure  to  deliver.
///
/// When the message does not fit into the send buffer of  the  socket,  `send`  normally  blocks,
/// unless  the socket has been placed in nonblocking I/O mode.  In nonblocking mode it would fail
/// with `SendError.WouldBlock`.  The `select` call may be used  to  determine when it is
/// possible to send more data.

pub fn recvfrom(
    sockfd: socket_t,
    buf: []u8,
    flags: u32,
    src_addr: ?*sockaddr,
    addrlen: ?*socklen_t,
) RecvFromError!usize {
    while (true) {
        const rc = system.recvfrom(sockfd, buf.ptr, buf.len, flags, src_addr, addrlen);
        if (native_os == .windows) {
            if (rc == windows.ws2_32.SOCKET_ERROR) {
                switch (windows.ws2_32.WSAGetLastError()) {
                    .WSANOTINITIALISED => unreachable,
                    .WSAECONNRESET => return error.ConnectionResetByPeer,
                    .WSAEINVAL => return error.SocketNotBound,
                    .WSAEMSGSIZE => return error.MessageTooBig,
                    .WSAENETDOWN => return error.NetworkSubsystemFailed,
                    .WSAENOTCONN => return error.SocketNotConnected,
                    .WSAEWOULDBLOCK => return error.WouldBlock,
                    .WSAETIMEDOUT => return error.ConnectionTimedOut,
                    // TODO: handle more errors
                    else => |err| return windows.unexpectedWSAError(err),
                }
            } else {
                return @intCast(rc);
            }
        } else {
            switch (errno(rc)) {
                .SUCCESS => return @intCast(rc),
                .BADF => unreachable, // always a race condition
                .FAULT => unreachable,
                .INVAL => unreachable,
                .NOTCONN => return error.SocketNotConnected,
                .NOTSOCK => unreachable,
                .INTR => continue,
                .AGAIN => return error.WouldBlock,
                .NOMEM => return error.SystemResources,
                .CONNREFUSED => return error.ConnectionRefused,
                .CONNRESET => return error.ConnectionResetByPeer,
                .TIMEDOUT => return error.ConnectionTimedOut,
                else => |err| return unexpectedErrno(err),
            }
        }
    }
}

pub fn faccessat(dirfd: fd_t, path: []const u8, mode: u32, flags: u32) AccessError!void {
    if (native_os == .windows) {
        const path_w = try windows.sliceToPrefixedFileW(dirfd, path);
        return faccessatW(dirfd, path_w.span().ptr);
    } else if (native_os == .wasi and !builtin.link_libc) {
        const resolved: RelativePathWasi = .{ .dir_fd = dirfd, .relative_path = path };

        const st = try std.os.fstatat_wasi(dirfd, path, .{
            .SYMLINK_FOLLOW = (flags & AT.SYMLINK_NOFOLLOW) == 0,
        });

        if (mode != F_OK) {
            var directory: wasi.fdstat_t = undefined;
            if (wasi.fd_fdstat_get(resolved.dir_fd, &directory) != .SUCCESS) {
                return error.AccessDenied;
            }

            var rights: wasi.rights_t = .{};
            if (mode & R_OK != 0) {
                if (st.filetype == .DIRECTORY) {
                    rights.FD_READDIR = true;
                } else {
                    rights.FD_READ = true;
                }
            }
            if (mode & W_OK != 0) {
                rights.FD_WRITE = true;
            }
            // No validation for X_OK

            // https://github.com/ziglang/zig/issues/18882
            const rights_int: u64 = @bitCast(rights);
            const inheriting_int: u64 = @bitCast(directory.fs_rights_inheriting);
            if ((rights_int & inheriting_int) != rights_int) {
                return error.AccessDenied;
            }
        }
        return;
    }
    const path_c = try toPosixPath(path);
    return faccessatZ(dirfd, &path_c, mode, flags);
}

/// Same as `faccessat` except the path parameter is null-terminated.

pub fn faccessatZ(dirfd: fd_t, path: [*:0]const u8, mode: u32, flags: u32) AccessError!void {
    if (native_os == .windows) {
        const path_w = try windows.cStrToPrefixedFileW(dirfd, path);
        return faccessatW(dirfd, path_w.span().ptr);
    } else if (native_os == .wasi and !builtin.link_libc) {
        return faccessat(dirfd, mem.sliceTo(path, 0), mode, flags);
    }
    switch (errno(system.faccessat(dirfd, path, mode, flags))) {
        .SUCCESS => return,
        .ACCES => return error.AccessDenied,
        .PERM => return error.PermissionDenied,
        .ROFS => return error.ReadOnlyFileSystem,
        .LOOP => return error.SymLinkLoop,
        .TXTBSY => return error.FileBusy,
        .NOTDIR => return error.FileNotFound,
        .NOENT => return error.FileNotFound,
        .NAMETOOLONG => return error.NameTooLong,
        .INVAL => unreachable,
        .FAULT => unreachable,
        .IO => return error.InputOutput,
        .NOMEM => return error.SystemResources,
        .ILSEQ => |err| if (native_os == .wasi)
            return error.InvalidUtf8
        else
            return unexpectedErrno(err),
        else => |err| return unexpectedErrno(err),
    }
}

/// Same as `faccessat` except asserts the target is Windows and the path parameter
/// is NtDll-prefixed, null-terminated, WTF-16 encoded.

pub fn faccessatW(dirfd: fd_t, sub_path_w: [*:0]const u16) AccessError!void {
    if (sub_path_w[0] == '.' and sub_path_w[1] == 0) {
        return;
    }
    if (sub_path_w[0] == '.' and sub_path_w[1] == '.' and sub_path_w[2] == 0) {
        return;
    }

    const path_len_bytes = cast(u16, mem.sliceTo(sub_path_w, 0).len * 2) orelse return error.NameTooLong;
    var nt_name = windows.UNICODE_STRING{
        .Length = path_len_bytes,
        .MaximumLength = path_len_bytes,
        .Buffer = @constCast(sub_path_w),
    };
    var attr = windows.OBJECT_ATTRIBUTES{
        .Length = @sizeOf(windows.OBJECT_ATTRIBUTES),
        .RootDirectory = if (fs.path.isAbsoluteWindowsW(sub_path_w)) null else dirfd,
        .Attributes = 0, // Note we do not use OBJ_CASE_INSENSITIVE here.
        .ObjectName = &nt_name,
        .SecurityDescriptor = null,
        .SecurityQualityOfService = null,
    };
    var basic_info: windows.FILE_BASIC_INFORMATION = undefined;
    switch (windows.ntdll.NtQueryAttributesFile(&attr, &basic_info)) {
        .SUCCESS => return,
        .OBJECT_NAME_NOT_FOUND => return error.FileNotFound,
        .OBJECT_PATH_NOT_FOUND => return error.FileNotFound,
        .OBJECT_NAME_INVALID => unreachable,
        .INVALID_PARAMETER => unreachable,
        .ACCESS_DENIED => return error.AccessDenied,
        .OBJECT_PATH_SYNTAX_BAD => unreachable,
        else => |rc| return windows.unexpectedStatus(rc),
    }
}

pub const FStatAtError = FStatError || error{
    NameTooLong,
    FileNotFound,
    SymLinkLoop,
    /// WASI-only; file paths must be valid UTF-8.
    InvalidUtf8,
};

/// Similar to `fstat`, but returns stat of a resource pointed to by `pathname`
/// which is relative to `dirfd` handle.
/// On WASI, `pathname` should be encoded as valid UTF-8.
/// On other platforms, `pathname` is an opaque sequence of bytes with no particular encoding.
/// See also `fstatatZ` and `std.os.fstatat_wasi`.

pub fn fstatat(dirfd: fd_t, pathname: []const u8, flags: u32) FStatAtError!Stat {
    if (native_os == .wasi and !builtin.link_libc) {
        const filestat = try std.os.fstatat_wasi(dirfd, pathname, .{
            .SYMLINK_FOLLOW = (flags & AT.SYMLINK_NOFOLLOW) == 0,
        });
        return Stat.fromFilestat(filestat);
    } else if (native_os == .windows) {
        @compileError("fstatat is not yet implemented on Windows");
    } else {
        const pathname_c = try toPosixPath(pathname);
        return fstatatZ(dirfd, &pathname_c, flags);
    }
}

pub fn openat(dir_fd: fd_t, file_path: []const u8, flags: O, mode: mode_t) OpenError!fd_t {
    if (native_os == .windows) {
        @compileError("Windows does not support POSIX; use Windows-specific API or cross-platform std.fs API");
    } else if (native_os == .wasi and !builtin.link_libc) {
        // `mode` is ignored on WASI, which does not support unix-style file permissions
        const opts = try openOptionsFromFlagsWasi(flags);
        const fd = try openatWasi(
            dir_fd,
            file_path,
            opts.lookup_flags,
            opts.oflags,
            opts.fs_flags,
            opts.fs_rights_base,
            opts.fs_rights_inheriting,
        );
        errdefer close(fd);

        if (flags.write) {
            const info = try std.os.fstat_wasi(fd);
            if (info.filetype == .DIRECTORY)
                return error.IsDir;
        }

        return fd;
    }
    const file_path_c = try toPosixPath(file_path);
    return openatZ(dir_fd, &file_path_c, flags, mode);
}

/// Open and possibly create a file in WASI.

pub fn openatZ(dir_fd: fd_t, file_path: [*:0]const u8, flags: O, mode: mode_t) OpenError!fd_t {
    if (native_os == .windows) {
        @compileError("Windows does not support POSIX; use Windows-specific API or cross-platform std.fs API");
    } else if (native_os == .wasi and !builtin.link_libc) {
        return openat(dir_fd, mem.sliceTo(file_path, 0), flags, mode);
    }

    const openat_sym = if (lfs64_abi) system.openat64 else system.openat;
    while (true) {
        const rc = openat_sym(dir_fd, file_path, flags, mode);
        switch (errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,

            .FAULT => unreachable,
            .INVAL => return error.BadPathName,
            .BADF => unreachable,
            .ACCES => return error.AccessDenied,
            .FBIG => return error.FileTooBig,
            .OVERFLOW => return error.FileTooBig,
            .ISDIR => return error.IsDir,
            .LOOP => return error.SymLinkLoop,
            .MFILE => return error.ProcessFdQuotaExceeded,
            .NAMETOOLONG => return error.NameTooLong,
            .NFILE => return error.SystemFdQuotaExceeded,
            .NODEV => return error.NoDevice,
            .NOENT => return error.FileNotFound,
            .SRCH => return error.ProcessNotFound,
            .NOMEM => return error.SystemResources,
            .NOSPC => return error.NoSpaceLeft,
            .NOTDIR => return error.NotDir,
            .PERM => return error.PermissionDenied,
            .EXIST => return error.PathAlreadyExists,
            .BUSY => return error.DeviceBusy,
            .OPNOTSUPP => return error.FileLocksNotSupported,
            .AGAIN => return error.WouldBlock,
            .TXTBSY => return error.FileBusy,
            .NXIO => return error.NoDevice,
            .ILSEQ => |err| if (native_os == .wasi)
                return error.InvalidUtf8
            else
                return unexpectedErrno(err),
            else => |err| return unexpectedErrno(err),
        }
    }
}

pub fn symlinkat(target_path: []const u8, newdirfd: fd_t, sym_link_path: []const u8) SymLinkError!void {
    if (native_os == .windows) {
        @compileError("symlinkat is not supported on Windows; use std.os.windows.CreateSymbolicLink instead");
    } else if (native_os == .wasi and !builtin.link_libc) {
        return symlinkatWasi(target_path, newdirfd, sym_link_path);
    }
    const target_path_c = try toPosixPath(target_path);
    const sym_link_path_c = try toPosixPath(sym_link_path);
    return symlinkatZ(&target_path_c, newdirfd, &sym_link_path_c);
}

/// WASI-only. The same as `symlinkat` but targeting WASI.
/// See also `symlinkat`.

pub fn symlinkatZ(target_path: [*:0]const u8, newdirfd: fd_t, sym_link_path: [*:0]const u8) SymLinkError!void {
    if (native_os == .windows) {
        @compileError("symlinkat is not supported on Windows; use std.os.windows.CreateSymbolicLink instead");
    } else if (native_os == .wasi and !builtin.link_libc) {
        return symlinkat(mem.sliceTo(target_path, 0), newdirfd, mem.sliceTo(sym_link_path, 0));
    }
    switch (errno(system.symlinkat(target_path, newdirfd, sym_link_path))) {
        .SUCCESS => return,
        .FAULT => unreachable,
        .INVAL => unreachable,
        .ACCES => return error.AccessDenied,
        .PERM => return error.PermissionDenied,
        .DQUOT => return error.DiskQuota,
        .EXIST => return error.PathAlreadyExists,
        .IO => return error.FileSystem,
        .LOOP => return error.SymLinkLoop,
        .NAMETOOLONG => return error.NameTooLong,
        .NOENT => return error.FileNotFound,
        .NOTDIR => return error.NotDir,
        .NOMEM => return error.SystemResources,
        .NOSPC => return error.NoSpaceLeft,
        .ROFS => return error.ReadOnlyFileSystem,
        .ILSEQ => |err| if (native_os == .wasi)
            return error.InvalidUtf8
        else
            return unexpectedErrno(err),
        else => |err| return unexpectedErrno(err),
    }
}

pub fn unlinkatW(dirfd: fd_t, sub_path_w: []const u16, flags: u32) UnlinkatError!void {
    const remove_dir = (flags & AT.REMOVEDIR) != 0;
    return windows.DeleteFile(sub_path_w, .{ .dir = dirfd, .remove_dir = remove_dir });
}

const RelativePathWasi = struct {
    /// Handle to directory
    dir_fd: fd_t,
    /// Path to resource within `dir_fd`.
    relative_path: []const u8,
};

/// Same as `renameat` except the parameters are null-terminated.

const cast = std.math.cast;

pub const FStatError = error{
    SystemResources,

    /// In WASI, this error may occur when the file descriptor does
    /// not hold the required rights to get its filestat information.
    AccessDenied,
    PermissionDenied,
} || UnexpectedError;

/// Return information about a file descriptor.

pub const Stat = system.Stat;

pub fn fstat(fd: fd_t) FStatError!Stat {
    if (native_os == .wasi and !builtin.link_libc) {
        return Stat.fromFilestat(try std.os.fstat_wasi(fd));
    }
    if (native_os == .windows) {
        @compileError("fstat is not yet implemented on Windows");
    }

    const fstat_sym = if (lfs64_abi) system.fstat64 else system.fstat;
    var stat = mem.zeroes(Stat);
    switch (errno(fstat_sym(fd, &stat))) {
        .SUCCESS => return stat,
        .INVAL => unreachable,
        .BADF => unreachable, // Always a race condition.
        .NOMEM => return error.SystemResources,
        .ACCES => return error.AccessDenied,
        else => |err| return unexpectedErrno(err),
    }
}

fn openOptionsFromFlagsWasi(oflag: O) OpenError!WasiOpenOptions {
    const w = std.os.wasi;

    // Next, calculate the read/write rights to request, depending on the
    // provided POSIX access mode
    var rights: w.rights_t = .{};
    if (oflag.read) {
        rights.FD_READ = true;
        rights.FD_READDIR = true;
    }
    if (oflag.write) {
        rights.FD_DATASYNC = true;
        rights.FD_WRITE = true;
        rights.FD_ALLOCATE = true;
        rights.FD_FILESTAT_SET_SIZE = true;
    }

    // https://github.com/ziglang/zig/issues/18882
    const flag_bits: u32 = @bitCast(oflag);
    const oflags_int: u16 = @as(u12, @truncate(flag_bits >> 12));
    const fs_flags_int: u16 = @as(u12, @truncate(flag_bits));

    return .{
        // https://github.com/ziglang/zig/issues/18882
        .oflags = @bitCast(oflags_int),
        .lookup_flags = .{
            .SYMLINK_FOLLOW = !oflag.NOFOLLOW,
        },
        .fs_rights_base = rights,
        .fs_rights_inheriting = rights,
        // https://github.com/ziglang/zig/issues/18882
        .fs_flags = @bitCast(fs_flags_int),
    };
}

/// Open and possibly create a file. Keeps trying if it gets interrupted.
/// `file_path` is relative to the open directory handle `dir_fd`.
/// On Windows, `file_path` should be encoded as [WTF-8](https://simonsapin.github.io/wtf-8/).
/// On WASI, `file_path` should be encoded as valid UTF-8.
/// On other platforms, `file_path` is an opaque sequence of bytes with no particular encoding.
/// See also `openat`.

pub fn symlinkatWasi(target_path: []const u8, newdirfd: fd_t, sym_link_path: []const u8) SymLinkError!void {
    switch (wasi.path_symlink(target_path.ptr, target_path.len, newdirfd, sym_link_path.ptr, sym_link_path.len)) {
        .SUCCESS => {},
        .FAULT => unreachable,
        .INVAL => unreachable,
        .BADF => unreachable,
        .ACCES => return error.AccessDenied,
        .PERM => return error.PermissionDenied,
        .DQUOT => return error.DiskQuota,
        .EXIST => return error.PathAlreadyExists,
        .IO => return error.FileSystem,
        .LOOP => return error.SymLinkLoop,
        .NAMETOOLONG => return error.NameTooLong,
        .NOENT => return error.FileNotFound,
        .NOTDIR => return error.NotDir,
        .NOMEM => return error.SystemResources,
        .NOSPC => return error.NoSpaceLeft,
        .ROFS => return error.ReadOnlyFileSystem,
        .NOTCAPABLE => return error.AccessDenied,
        .ILSEQ => return error.InvalidUtf8,
        else => |err| return unexpectedErrno(err),
    }
}

/// The same as `symlinkat` except the parameters are null-terminated pointers.
/// See also `symlinkat`.

pub fn fstatatZ(dirfd: fd_t, pathname: [*:0]const u8, flags: u32) FStatAtError!Stat {
    if (native_os == .wasi and !builtin.link_libc) {
        const filestat = try std.os.fstatat_wasi(dirfd, mem.sliceTo(pathname, 0), .{
            .SYMLINK_FOLLOW = (flags & AT.SYMLINK_NOFOLLOW) == 0,
        });
        return Stat.fromFilestat(filestat);
    }

    const fstatat_sym = if (lfs64_abi) system.fstatat64 else system.fstatat;
    var stat = mem.zeroes(Stat);
    switch (errno(fstatat_sym(dirfd, pathname, &stat, flags))) {
        .SUCCESS => return stat,
        .INVAL => unreachable,
        .BADF => unreachable, // Always a race condition.
        .NOMEM => return error.SystemResources,
        .ACCES => return error.AccessDenied,
        .PERM => return error.PermissionDenied,
        .FAULT => unreachable,
        .NAMETOOLONG => return error.NameTooLong,
        .LOOP => return error.SymLinkLoop,
        .NOENT => return error.FileNotFound,
        .NOTDIR => return error.FileNotFound,
        .ILSEQ => |err| if (native_os == .wasi)
            return error.InvalidUtf8
        else
            return unexpectedErrno(err),
        else => |err| return unexpectedErrno(err),
    }
}

pub fn unlinkatWasi(dirfd: fd_t, file_path: []const u8, flags: u32) UnlinkatError!void {
    const remove_dir = (flags & AT.REMOVEDIR) != 0;
    const res = if (remove_dir)
        wasi.path_remove_directory(dirfd, file_path.ptr, file_path.len)
    else
        wasi.path_unlink_file(dirfd, file_path.ptr, file_path.len);
    switch (res) {
        .SUCCESS => return,
        .ACCES => return error.AccessDenied,
        .PERM => return error.PermissionDenied,
        .BUSY => return error.FileBusy,
        .FAULT => unreachable,
        .IO => return error.FileSystem,
        .ISDIR => return error.IsDir,
        .LOOP => return error.SymLinkLoop,
        .NAMETOOLONG => return error.NameTooLong,
        .NOENT => return error.FileNotFound,
        .NOTDIR => return error.NotDir,
        .NOMEM => return error.SystemResources,
        .ROFS => return error.ReadOnlyFileSystem,
        .NOTEMPTY => return error.DirNotEmpty,
        .NOTCAPABLE => return error.AccessDenied,
        .ILSEQ => return error.InvalidUtf8,

        .INVAL => unreachable, // invalid flags, or pathname has . as last component
        .BADF => unreachable, // always a race condition

        else => |err| return unexpectedErrno(err),
    }
}

/// Same as `unlinkat` but `file_path` is a null-terminated string.

pub const F_OK = system.F_OK;

pub fn openatWasi(
    dir_fd: fd_t,
    file_path: []const u8,
    lookup_flags: wasi.lookupflags_t,
    oflags: wasi.oflags_t,
    fdflags: wasi.fdflags_t,
    base: wasi.rights_t,
    inheriting: wasi.rights_t,
) OpenError!fd_t {
    while (true) {
        var fd: fd_t = undefined;
        switch (wasi.path_open(dir_fd, lookup_flags, file_path.ptr, file_path.len, oflags, base, inheriting, fdflags, &fd)) {
            .SUCCESS => return fd,
            .INTR => continue,

            .FAULT => unreachable,
            // Provides INVAL with a linux host on a bad path name, but NOENT on Windows
            .INVAL => return error.BadPathName,
            .BADF => unreachable,
            .ACCES => return error.AccessDenied,
            .FBIG => return error.FileTooBig,
            .OVERFLOW => return error.FileTooBig,
            .ISDIR => return error.IsDir,
            .LOOP => return error.SymLinkLoop,
            .MFILE => return error.ProcessFdQuotaExceeded,
            .NAMETOOLONG => return error.NameTooLong,
            .NFILE => return error.SystemFdQuotaExceeded,
            .NODEV => return error.NoDevice,
            .NOENT => return error.FileNotFound,
            .NOMEM => return error.SystemResources,
            .NOSPC => return error.NoSpaceLeft,
            .NOTDIR => return error.NotDir,
            .PERM => return error.PermissionDenied,
            .EXIST => return error.PathAlreadyExists,
            .BUSY => return error.DeviceBusy,
            .NOTCAPABLE => return error.AccessDenied,
            .ILSEQ => return error.InvalidUtf8,
            else => |err| return unexpectedErrno(err),
        }
    }
}

/// A struct to contain all lookup/rights flags accepted by `wasi.path_open`

const WasiOpenOptions = struct {
    oflags: wasi.oflags_t,
    lookup_flags: wasi.lookupflags_t,
    fs_rights_base: wasi.rights_t,
    fs_rights_inheriting: wasi.rights_t,
    fs_flags: wasi.fdflags_t,
};

/// Compute rights + flags corresponding to the provided POSIX access mode.

pub const R_OK = system.R_OK;

pub const W_OK = system.W_OK;

pub const X_OK = system.X_OK;

pub fn nanosleep(seconds: u64, nanoseconds: u64) void {
    var req = timespec{
        .sec = cast(isize, seconds) orelse maxInt(isize),
        .nsec = cast(isize, nanoseconds) orelse maxInt(isize),
    };
    var rem: timespec = undefined;
    while (true) {
        switch (errno(system.nanosleep(&req, &rem))) {
            .FAULT => unreachable,
            .INVAL => {
                // Sometimes Darwin returns EINVAL for no reason.
                // We treat it as a spurious wakeup.
                return;
            },
            .INTR => {
                req = rem;
                continue;
            },
            // This prong handles success as well as unexpected errors.
            else => return,
        }
    }
}

pub fn clock_getres(clock_id: clockid_t, res: *timespec) ClockGetTimeError!void {
    if (native_os == .wasi and !builtin.link_libc) {
        var ts: timestamp_t = undefined;
        switch (system.clock_res_get(@bitCast(clock_id), &ts)) {
            .SUCCESS => res.* = .{
                .sec = @intCast(ts / std.time.ns_per_s),
                .nsec = @intCast(ts % std.time.ns_per_s),
            },
            .INVAL => return error.UnsupportedClock,
            else => |err| return unexpectedErrno(err),
        }
        return;
    }

    switch (errno(system.clock_getres(clock_id, res))) {
        .SUCCESS => return,
        .FAULT => unreachable,
        .INVAL => return error.UnsupportedClock,
        else => |err| return unexpectedErrno(err),
    }
}

/// Ported from Zig 0.15.2 std.Thread.sleep (removed in 0.16 in favor of Io.sleep).
pub fn sleep(nanoseconds: u64) void {
    const s = nanoseconds / ns_per_s;
    const ns = nanoseconds % ns_per_s;
    nanosleep(s, ns);
}

/// Write all of `bytes` to `fd` (0.15 std.fs.File.writeAll equivalent at fd level).
pub fn writeAll(fd: fd_t, bytes: []const u8) WriteError!void {
    var index: usize = 0;
    while (index < bytes.len) {
        index += try write(fd, bytes[index..]);
    }
}

pub const MakeDirError = error{
    /// In WASI, this error may occur when the file descriptor does
    /// not hold the required rights to create a new directory relative to it.
    AccessDenied,
    PermissionDenied,
    DiskQuota,
    PathAlreadyExists,
    SymLinkLoop,
    LinkQuotaExceeded,
    NameTooLong,
    FileNotFound,
    SystemResources,
    NoSpaceLeft,
    NotDir,
    ReadOnlyFileSystem,
    /// WASI-only; file paths must be valid UTF-8.
    InvalidUtf8,
    /// Windows-only; file paths provided by the user must be valid WTF-8.
    /// https://simonsapin.github.io/wtf-8/
    InvalidWtf8,
    BadPathName,
    NoDevice,
    /// On Windows, `\\server` or `\\server\share` was not found.
    NetworkNotFound,
} || UnexpectedError;

/// Create a directory.
/// `mode` is ignored on Windows and WASI.
/// On Windows, `dir_path` should be encoded as [WTF-8](https://simonsapin.github.io/wtf-8/).
/// On WASI, `dir_path` should be encoded as valid UTF-8.
/// On other platforms, `dir_path` is an opaque sequence of bytes with no particular encoding.

pub fn mkdir(dir_path: []const u8, mode: mode_t) MakeDirError!void {
    if (native_os == .wasi and !builtin.link_libc) {
        return mkdirat(AT.FDCWD, dir_path, mode);
    } else if (native_os == .windows) {
        const dir_path_w = try windows.sliceToPrefixedFileW(null, dir_path);
        return mkdirW(dir_path_w.span(), mode);
    } else {
        const dir_path_c = try toPosixPath(dir_path);
        return mkdirZ(&dir_path_c, mode);
    }
}

/// Same as `mkdir` but the parameter is null-terminated.
/// On Windows, `dir_path` should be encoded as [WTF-8](https://simonsapin.github.io/wtf-8/).
/// On WASI, `dir_path` should be encoded as valid UTF-8.
/// On other platforms, `dir_path` is an opaque sequence of bytes with no particular encoding.

pub fn mkdirZ(dir_path: [*:0]const u8, mode: mode_t) MakeDirError!void {
    if (native_os == .windows) {
        const dir_path_w = try windows.cStrToPrefixedFileW(null, dir_path);
        return mkdirW(dir_path_w.span(), mode);
    } else if (native_os == .wasi and !builtin.link_libc) {
        return mkdir(mem.sliceTo(dir_path, 0), mode);
    }
    switch (errno(system.mkdir(dir_path, mode))) {
        .SUCCESS => return,
        .ACCES => return error.AccessDenied,
        .PERM => return error.PermissionDenied,
        .DQUOT => return error.DiskQuota,
        .EXIST => return error.PathAlreadyExists,
        .FAULT => unreachable,
        .LOOP => return error.SymLinkLoop,
        .MLINK => return error.LinkQuotaExceeded,
        .NAMETOOLONG => return error.NameTooLong,
        .NOENT => return error.FileNotFound,
        .NOMEM => return error.SystemResources,
        .NOSPC => return error.NoSpaceLeft,
        .NOTDIR => return error.NotDir,
        .ROFS => return error.ReadOnlyFileSystem,
        .ILSEQ => |err| if (native_os == .wasi)
            return error.InvalidUtf8
        else
            return unexpectedErrno(err),
        else => |err| return unexpectedErrno(err),
    }
}

/// Windows-only. Same as `mkdir` but the parameters is WTF16LE encoded.

pub fn mkdirat(dir_fd: fd_t, sub_dir_path: []const u8, mode: mode_t) MakeDirError!void {
    if (native_os == .windows) {
        const sub_dir_path_w = try windows.sliceToPrefixedFileW(dir_fd, sub_dir_path);
        return mkdiratW(dir_fd, sub_dir_path_w.span(), mode);
    } else if (native_os == .wasi and !builtin.link_libc) {
        return mkdiratWasi(dir_fd, sub_dir_path, mode);
    } else {
        const sub_dir_path_c = try toPosixPath(sub_dir_path);
        return mkdiratZ(dir_fd, &sub_dir_path_c, mode);
    }
}

pub fn mkdiratZ(dir_fd: fd_t, sub_dir_path: [*:0]const u8, mode: mode_t) MakeDirError!void {
    if (native_os == .windows) {
        const sub_dir_path_w = try windows.cStrToPrefixedFileW(dir_fd, sub_dir_path);
        return mkdiratW(dir_fd, sub_dir_path_w.span(), mode);
    } else if (native_os == .wasi and !builtin.link_libc) {
        return mkdirat(dir_fd, mem.sliceTo(sub_dir_path, 0), mode);
    }
    switch (errno(system.mkdirat(dir_fd, sub_dir_path, mode))) {
        .SUCCESS => return,
        .ACCES => return error.AccessDenied,
        .BADF => unreachable,
        .PERM => return error.PermissionDenied,
        .DQUOT => return error.DiskQuota,
        .EXIST => return error.PathAlreadyExists,
        .FAULT => unreachable,
        .LOOP => return error.SymLinkLoop,
        .MLINK => return error.LinkQuotaExceeded,
        .NAMETOOLONG => return error.NameTooLong,
        .NOENT => return error.FileNotFound,
        .NOMEM => return error.SystemResources,
        .NOSPC => return error.NoSpaceLeft,
        .NOTDIR => return error.NotDir,
        .ROFS => return error.ReadOnlyFileSystem,
        // dragonfly: when dir_fd is unlinked from filesystem
        .NOTCONN => return error.FileNotFound,
        .ILSEQ => |err| if (native_os == .wasi)
            return error.InvalidUtf8
        else
            return unexpectedErrno(err),
        else => |err| return unexpectedErrno(err),
    }
}

/// Windows-only. Same as `mkdirat` except the parameter WTF16 LE encoded.

pub fn mkdiratW(dir_fd: fd_t, sub_path_w: []const u16, mode: mode_t) MakeDirError!void {
    _ = mode;
    const sub_dir_handle = windows.OpenFile(sub_path_w, .{
        .dir = dir_fd,
        .access_mask = windows.GENERIC_READ | windows.SYNCHRONIZE,
        .creation = windows.FILE_CREATE,
        .filter = .dir_only,
    }) catch |err| switch (err) {
        error.IsDir => return error.Unexpected,
        error.PipeBusy => return error.Unexpected,
        error.NoDevice => return error.Unexpected,
        error.WouldBlock => return error.Unexpected,
        error.AntivirusInterference => return error.Unexpected,
        else => |e| return e,
    };
    windows.CloseHandle(sub_dir_handle);
}

pub fn mkdirW(dir_path_w: []const u16, mode: mode_t) MakeDirError!void {
    _ = mode;
    const sub_dir_handle = windows.OpenFile(dir_path_w, .{
        .dir = fs.cwd().fd,
        .access_mask = windows.GENERIC_READ | windows.SYNCHRONIZE,
        .creation = windows.FILE_CREATE,
        .filter = .dir_only,
    }) catch |err| switch (err) {
        error.IsDir => return error.Unexpected,
        error.PipeBusy => return error.Unexpected,
        error.NoDevice => return error.Unexpected,
        error.WouldBlock => return error.Unexpected,
        error.AntivirusInterference => return error.Unexpected,
        else => |e| return e,
    };
    windows.CloseHandle(sub_dir_handle);
}

pub fn mkdiratWasi(dir_fd: fd_t, sub_dir_path: []const u8, mode: mode_t) MakeDirError!void {
    _ = mode;
    switch (wasi.path_create_directory(dir_fd, sub_dir_path.ptr, sub_dir_path.len)) {
        .SUCCESS => return,
        .ACCES => return error.AccessDenied,
        .BADF => unreachable,
        .PERM => return error.PermissionDenied,
        .DQUOT => return error.DiskQuota,
        .EXIST => return error.PathAlreadyExists,
        .FAULT => unreachable,
        .LOOP => return error.SymLinkLoop,
        .MLINK => return error.LinkQuotaExceeded,
        .NAMETOOLONG => return error.NameTooLong,
        .NOENT => return error.FileNotFound,
        .NOMEM => return error.SystemResources,
        .NOSPC => return error.NoSpaceLeft,
        .NOTDIR => return error.NotDir,
        .ROFS => return error.ReadOnlyFileSystem,
        .NOTCAPABLE => return error.AccessDenied,
        .ILSEQ => return error.InvalidUtf8,
        else => |err| return unexpectedErrno(err),
    }
}


/// Fill `buf` with cryptographically secure random bytes. Replacement for
/// 0.15 std.crypto.random.bytes at io-less call sites (0.16 moved entropy
/// onto the Io interface).
pub fn random(buf: []u8) void {
    switch (native_os) {
        .driverkit, .ios, .maccatalyst, .macos, .tvos, .visionos, .watchos => std.c.arc4random_buf(buf.ptr, buf.len),
        .linux => {
            var i: usize = 0;
            while (i < buf.len) {
                const rc = std.c.getrandom(buf[i..].ptr, buf.len - i, 0);
                switch (errno(rc)) {
                    .SUCCESS => i += @intCast(rc),
                    .INTR => continue,
                    else => unreachable, // getrandom with flags=0 cannot fail otherwise
                }
            }
        },
        else => @compileError("unsupported OS"),
    }
}

/// Plain thread mutex with 0.15 std.Thread.Mutex semantics (0.16 moved
/// Thread.Mutex to Io.Mutex, which requires an Io at every lock site).
/// hty always links libc, so pthread is the natural implementation.
pub const Mutex = struct {
    m: std.c.pthread_mutex_t = .{},

    pub fn lock(self: *Mutex) void {
        assert(std.c.pthread_mutex_lock(&self.m) == .SUCCESS);
    }

    pub fn unlock(self: *Mutex) void {
        assert(std.c.pthread_mutex_unlock(&self.m) == .SUCCESS);
    }
};
