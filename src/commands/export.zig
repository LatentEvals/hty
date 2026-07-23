//! `hty export` — convert a recorded session log into a share-ready artifact.
//!
//! Lives alongside `hty logs` (which dumps the raw JSONL for debugging /
//! piping) but is deliberately a separate verb: exporting is about producing
//! an artifact for another tool, not about reading the log. Today only
//! `--format asciicast` is supported; the command exists as a home for future
//! exports (`--format svg`, `--format jsonl-canonical`, ...) without polluting
//! `logs` with artifact-generation flags.

const std = @import("std");
const Allocator = std.mem.Allocator;

const common = @import("common.zig");
const logs = @import("logs.zig");
const asciicast = @import("asciicast.zig");

pub fn helpText() []const u8 {
    return
    \\hty export [SESSION] --format FMT
    \\
    \\Convert a recorded session log to a share-ready artifact and write it
    \\to stdout. SESSION may be a --name, a full UUID, or any unambiguous
    \\prefix; if omitted and exactly one log exists, that one is used.
    \\
    \\Flags:
    \\  --format FMT   Output format. Required. Supported:
    \\                   asciicast   asciinema v2 .cast — pipe into `agg`,
    \\                               `vhs`, or upload to asciinema.org.
    \\
    \\Example:
    \\  hty export my-session --format asciicast > run.cast
    \\  agg run.cast run.gif
    \\
    ;
}

const Format = enum { asciicast };

const ExportOptions = struct {
    session: ?[]const u8 = null,
    format: ?Format = null,
};

pub fn run(alloc: Allocator, io: std.Io, args: []const []const u8) !void {
    var opts = ExportOptions{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--format")) {
            i += 1;
            if (i >= args.len) common.printUsageAndExit("--format requires an argument");
            if (std.mem.eql(u8, args[i], "asciicast")) {
                opts.format = .asciicast;
            } else {
                common.printUsageAndExit("unknown --format value (supported: asciicast)");
            }
        } else if (std.mem.startsWith(u8, arg, "--")) {
            common.printUsageAndExit("unknown flag for `hty export`");
        } else {
            if (opts.session != null) common.printUsageAndExit("only one session argument is allowed");
            opts.session = arg;
        }
    }

    const fmt = opts.format orelse {
        common.printUsageAndExit("`hty export` requires --format (e.g. --format asciicast)");
    };

    const path = logs.resolveLogPath(alloc, io, opts.session) catch |err| {
        switch (err) {
            error.SessionNotFound => try common.printErr("session log not found"),
            error.AmbiguousPrefix => try common.printErr("ambiguous session prefix"),
            error.AmbiguousSole => try common.printErr("more than one session log exists — name one explicitly"),
            else => try common.printErrFmt("failed to resolve session log: {s}", .{@errorName(err)}),
        }
        std.process.exit(common.ExitCode.not_found);
    };
    defer alloc.free(path);

    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(64 * 1024 * 1024)) catch |err| {
        try common.printErrFmt("cannot read {s}: {s}", .{ path, @errorName(err) });
        std.process.exit(common.ExitCode.generic);
    };
    defer alloc.free(bytes);

    switch (fmt) {
        .asciicast => {
            // Build the whole cast in memory, then write it to stdout in a
            // single call. Session logs are capped at 64 MB by the reader
            // above, so this is bounded.
            var buf: std.Io.Writer.Allocating = .init(alloc);
            defer buf.deinit();
            asciicast.writeCast(alloc, &buf.writer, bytes) catch |err| {
                try common.printErrFmt("asciicast conversion failed: {s}", .{@errorName(err)});
                std.process.exit(common.ExitCode.generic);
            };
            try common.printRaw(buf.writer.buffered());
        },
    }
}
