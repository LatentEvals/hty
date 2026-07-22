//! Golden-frame tests for the bundled `ghostty-vt` engine.
//!
//! Each case feeds a curated byte sequence directly into a fresh VT (no PTY,
//! no subprocess) and asserts the rendered grid matches a committed golden.
//! This isolates regressions in the engine itself — if bumping `ghostty-vt`
//! changes any of these outputs, we see the diff in `testdata/vt/` and decide
//! whether it's a fix or a regression.
//!
//! ## Updating goldens
//!
//! When an upstream change is intentional, regenerate all goldens:
//!
//!     UPDATE_GOLDENS=1 zig build test
//!
//! Review the `testdata/vt/*.golden` diff before committing.

const std = @import("std");
const hty = @import("hty");

/// Feed `input` into a fresh VT, render the final screen, and compare the
/// rendered + plain buffers against committed golden files. In UPDATE mode
/// the goldens are written (creating the directory if needed) and the
/// comparison is skipped.
fn runGoldenCase(
    comptime name: []const u8,
    input: []const u8,
    target_rows: u16,
    target_cols: u16,
) !void {
    try runGoldenChunks(name, &.{input}, target_rows, target_cols);
}

/// Same as `runGoldenCase` but feeds the input as a sequence of chunks,
/// simulating the way real PTY output arrives mid-escape or mid-codepoint.
fn runGoldenChunks(
    comptime name: []const u8,
    chunks: []const []const u8,
    target_rows: u16,
    target_cols: u16,
) !void {
    const alloc = std.testing.allocator;

    var terminal = try hty.ghostty_vt.Terminal.init(alloc, .{
        .cols = target_cols,
        .rows = target_rows,
        .max_scrollback = 10_000,
    });
    defer terminal.deinit(alloc);

    const handler = terminal.vtHandler();
    var stream = hty.ghostty_vt.TerminalStream.initAlloc(alloc, handler);
    defer stream.deinit();

    for (chunks) |chunk| stream.nextSlice(chunk);

    const ansi = try hty.renderScreenAnsi(alloc, &terminal, target_rows, target_cols);
    defer alloc.free(ansi);

    const plain = try terminal.plainString(alloc);
    defer alloc.free(plain);

    try compareOrUpdateGolden(alloc, name ++ ".ansi.golden", ansi);
    try compareOrUpdateGolden(alloc, name ++ ".plain.golden", plain);
}

fn compareOrUpdateGolden(
    alloc: std.mem.Allocator,
    basename: []const u8,
    actual: []const u8,
) !void {
    const path = try std.fmt.allocPrint(alloc, "testdata/vt/{s}", .{basename});
    defer alloc.free(path);

    if (std.posix.getenv("UPDATE_GOLDENS") != null) {
        try std.fs.cwd().makePath("testdata/vt");
        const file = try std.fs.cwd().createFile(path, .{ .truncate = true });
        defer file.close();
        try file.writeAll(actual);
        return;
    }

    const file = std.fs.cwd().openFile(path, .{ .mode = .read_only }) catch |err| switch (err) {
        error.FileNotFound => {
            std.debug.print(
                \\
                \\  golden not found: {s}
                \\  run `UPDATE_GOLDENS=1 zig build test` to create it
                \\
                \\
            , .{path});
            return error.GoldenMissing;
        },
        else => return err,
    };
    defer file.close();
    const expected = try file.readToEndAlloc(alloc, 4 * 1024 * 1024);
    defer alloc.free(expected);

    if (!std.mem.eql(u8, expected, actual)) {
        std.debug.print(
            \\
            \\  golden mismatch: {s}
            \\  expected ({d} bytes):
            \\{s}
            \\  actual ({d} bytes):
            \\{s}
            \\
            \\  if this change is intentional, run:
            \\    UPDATE_GOLDENS=1 zig build test
            \\
            \\
        , .{ path, expected.len, expected, actual.len, actual });
        return error.GoldenMismatch;
    }
}

// ===========================================================================
// Cases
// ===========================================================================
//
// Inputs are inline string literals so each test advertises exactly what
// sequence it's exercising. Keep inputs small and focused — one concept per
// case. Larger real-world captures belong in the fixture suite (step 3 of the
// test plan), not here.

test "golden: plain ascii sanity" {
    try runGoldenCase("plain_ascii", "hello world", 24, 80);
}

test "golden: ascii wraps at col 80" {
    // 85 'a's forces a wrap onto the second row. Nothing fancy — this is the
    // canary that soft-wrap still works at all.
    try runGoldenCase("ascii_wrap", "a" ** 85, 24, 80);
}

test "golden: SGR 4-bit foreground colors" {
    try runGoldenCase(
        "sgr_4bit",
        "\x1b[31mred\x1b[32mgreen\x1b[34mblue\x1b[0mplain",
        24,
        80,
    );
}

test "golden: SGR 24-bit truecolor" {
    try runGoldenCase(
        "sgr_truecolor",
        "\x1b[38;2;255;100;50mwarm\x1b[48;2;10;20;30m bg\x1b[0m",
        24,
        80,
    );
}

test "golden: cursor positioning (CUP)" {
    // Jump to row 3 col 5, write "X"; jump to row 10 col 40, write "Y".
    try runGoldenCase(
        "cursor_move",
        "\x1b[3;5HX\x1b[10;40HY",
        24,
        80,
    );
}

test "golden: erase in line (EL 0)" {
    // Write "keep me|drop me", move cursor back 7, then EL 0 (erase to end).
    try runGoldenCase(
        "erase_in_line",
        "keep me|drop me\x1b[7D\x1b[0K",
        24,
        80,
    );
}

test "golden: erase in line (EL 1 - cursor to start)" {
    // Write line, move cursor back 4, then EL 1 (erase from start to cursor).
    try runGoldenCase(
        "erase_in_line_left",
        "drop me|keep me\x1b[7D\x1b[1K",
        24,
        80,
    );
}

test "golden: erase in line (EL 2 - whole line)" {
    try runGoldenCase(
        "erase_in_line_all",
        "anything at all\x1b[2K",
        24,
        80,
    );
}

test "golden: erase in display (ED 2 - whole screen)" {
    // Write across three rows, then erase the whole display.
    try runGoldenCase(
        "erase_in_display_all",
        "row1\r\nrow2\r\nrow3\x1b[2J",
        24,
        80,
    );
}

test "golden: SGR 8-bit palette color" {
    try runGoldenCase(
        "sgr_palette",
        "\x1b[38;5;208morange\x1b[48;5;17mbg\x1b[0mreset",
        24,
        80,
    );
}

test "golden: save/restore cursor (DECSC/DECRC)" {
    // ABC, save, jump to row 5, write XY, restore, write Z at the saved spot.
    // Expect: row 1 = "ABCZ", row 5 col 10 = "XY".
    try runGoldenCase(
        "decsc_decrc",
        "ABC\x1b7\x1b[5;10HXY\x1b8Z",
        24,
        80,
    );
}

test "golden: scroll region (DECSTBM)" {
    // Set scroll region to rows 3-5, fill with content that wraps through
    // the region. Rows 1-2 and 6+ should be untouched.
    try runGoldenCase(
        "scroll_region",
        "top\r\n\x1b[3;5r\x1b[3;1Haaa\r\nbbb\r\nccc\r\nddd\r\neee",
        24,
        80,
    );
}

test "golden: alt screen round-trip preserves primary" {
    // Write to primary, enter alt screen, write there, exit alt — the grid
    // we snapshot is the primary, so it should still show "primary".
    try runGoldenCase(
        "alt_screen_roundtrip",
        "primary\x1b[?1049hSOMETHING ELSE\x1b[?1049l",
        24,
        80,
    );
}

test "golden: CJK wide characters occupy two cells each" {
    // "日本語" — three CJK glyphs, six cells wide.
    try runGoldenCase("cjk_wide", "日本語", 24, 80);
}

test "golden: combining marks fold into one cell" {
    // "e" + U+0301 (combining acute) should render as "é" in one cell.
    try runGoldenCase("combining_mark", "e\xcc\x81", 24, 80);
}

test "golden: UTF-8 codepoint split across chunk boundaries" {
    // "日本語" is 9 bytes. Feed as 4 + 5, splitting "本" in half.
    try runGoldenChunks(
        "utf8_split",
        &.{ "\xe6\x97\xa5\xe6", "\x9c\xac\xe8\xaa\x9e" },
        24,
        80,
    );
}

test "golden: narrow char overwrites a wide glyph's spacer tail" {
    // Print a wide emoji (cols 1-2), then move onto its spacer tail and
    // print a narrow char. The engine must clear the orphaned wide cell.
    // This exact sequence crashed release builds when ghostty-vt was
    // compiled with its integrity checks on but the root binary's
    // runtime safety off (mismatched optimize modes): the spacer-tail
    // fixup in `Terminal.print` was compiled out while the page
    // integrity check in `Screen.clearCells` wasn't, panicking the
    // server on emoji-dense TUI repaints.
    try runGoldenCase("narrow_over_spacer_tail", "🏆\x1b[1;2Hx", 24, 80);
}

test "golden: mode-set escapes (bracketed paste) are silently consumed" {
    // The paste/mouse toggles must not leak visible bytes into the grid.
    try runGoldenCase(
        "mode_toggle_silent",
        "\x1b[?2004h\x1b[?1000hhello\x1b[?1000l\x1b[?2004l",
        24,
        80,
    );
}

test "golden: OSC 8 hyperlink renders the visible label" {
    // Whatever ANSI pass-through the engine chooses, the plain buffer must
    // contain only "link text" (escape payload stripped).
    try runGoldenCase(
        "osc8_hyperlink",
        "\x1b]8;;https://example.com\x07link text\x1b]8;;\x07",
        24,
        80,
    );
}

test "OSC 0 sets the terminal title" {
    // Title is a tiny string, not grid state — assert inline rather than
    // committing a one-field golden file.
    const alloc = std.testing.allocator;

    var terminal = try hty.ghostty_vt.Terminal.init(alloc, .{
        .cols = 80,
        .rows = 24,
        .max_scrollback = 10_000,
    });
    defer terminal.deinit(alloc);

    const handler = terminal.vtHandler();
    var stream = hty.ghostty_vt.TerminalStream.initAlloc(alloc, handler);
    defer stream.deinit();

    stream.nextSlice("before\x1b]0;My Title\x07after");

    const title = terminal.getTitle() orelse "";
    try std.testing.expectEqualStrings("My Title", title);

    // And the visible text should be "beforeafter" — title escape stripped.
    const plain = try terminal.plainString(alloc);
    defer alloc.free(plain);
    try std.testing.expect(std.mem.indexOf(u8, plain, "beforeafter") != null);
}
