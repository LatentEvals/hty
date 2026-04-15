//! Wire types for the `hty` JSON-RPC protocol and the canonical error-to-
//! string mapping used when a request handler fails.
//!
//! Every request from the client lands on the server as one line of JSON;
//! every response is one `Response` struct serialized back to JSON. These
//! structs are the serialization contract, nothing more — they don't own
//! the data they wrap (pointers reference arena-scoped buffers during
//! request handling).

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Response = struct {
    id: ?i64 = null,
    ok: bool,
    @"error": ?[]const u8 = null,
    timed_out: bool = false,
    snapshot: ?SnapshotPayload = null,
    event: ?EventPayload = null,
    session: ?SessionSummary = null,
    sessions: ?[]const SessionSummary = null,
};

pub const SnapshotPayload = struct {
    rows: u16,
    cols: u16,
    cursor_row: u16,
    cursor_col: u16,
    title: ?[]const u8,
    buffer: []const u8,
    screen_ansi: []const u8,
    lines: []const []const u8,
    /// Column-accurate grid view: `cells.len == rows` and every
    /// `cells[r].len == cols`. Each entry is a UTF-8 grapheme string.
    /// - Blank cell: `" "` (single space).
    /// - Leading cell of a wide character: the grapheme (e.g. `"日"`).
    /// - Spacer-tail cell (trailing half of a wide char): `""`.
    /// Purely positional; carries no styling.
    cells: []const []const []const u8,
    status: []const u8 = "running",
};

pub const EventPayload = struct {
    kind: []const u8,
    code: ?i32 = null,
    title: ?[]const u8 = null,
    message: ?[]const u8 = null,
    bytes_hex: ?[]const u8 = null,
};

pub const SessionSummary = struct {
    id: []const u8,
    name: ?[]const u8,
    program: []const u8,
    args: []const u8,
    status: []const u8,
    created_at_ms: i64,
};

/// Serialize a response and append a trailing newline for the JSONL stream.
pub fn encodeResponse(alloc: Allocator, response: Response) ![]u8 {
    const json = try std.json.Stringify.valueAlloc(alloc, response, .{});
    defer alloc.free(json);
    return std.fmt.allocPrint(alloc, "{s}\n", .{json});
}

/// Map internal errors to the short, user-facing strings returned in the
/// `error` field of a failed response. Anything not in this table falls
/// through to `@errorName` which is a stable-enough contract for debugging
/// but not meant for user display.
pub fn requestErrorMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.SessionNotFound => "session not found",
        error.AmbiguousPrefix => "ambiguous session prefix; match is not unique",
        error.NameAlreadyExists => "a session with that name already exists — use `hty delete NAME` to free it",
        error.MissingField => "missing required field",
        error.InvalidFieldType => "invalid field type",
        error.InvalidFieldValue => "invalid field value",
        error.InvalidKey => "invalid key name; run `hty keys` for the list",
        error.InvalidHex => "invalid hex bytes; expected an even-length hexadecimal string",
        error.UnknownOperation => "unknown op",
        error.InvalidRegex => "invalid regex pattern",
        else => @errorName(err),
    };
}
