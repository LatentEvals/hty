#!/usr/bin/env bash
#
# demo-vim.sh — drive vim through hty to prove the two-terminal observer flow.
#
# In terminal A:
#     ./scripts/demo-vim.sh
#
# The script has three confirmation prompts:
#   1. If a previous "demo-vim" session already exists, the script pauses
#      so you can replay or inspect it before it's deleted. Press Enter
#      to delete it and start a fresh vim session.
#   2. After vim is up and idle, the script pauses again so you have time
#      to open a second terminal and run `hty watch demo-vim` (or
#      `hty attach demo-vim`). Press Enter to start driving the session;
#      terminal B will show input appearing character by character in
#      insert mode, `:wq` at the status bar, and vim exiting — all
#      happening "by itself".
#   3. After vim exits the script pauses once more before deleting the
#      now-zombie session, so you can replay / inspect it one last time.
#      Ctrl-C at this prompt keeps the session around for later.
#
set -e

HTY="${HTY:-./zig-out/bin/hty}"
SESSION="demo-vim"
FILE="/tmp/hty-demo.txt"

if [[ ! -x "$HTY" ]]; then
    echo "hty binary not found at $HTY; build it first with 'zig build'" >&2
    exit 1
fi

# Prompt 1: before any destructive action, give the user a chance to
# inspect (or replay) the previous run. Nothing is deleted until they
# press Enter here.
if "$HTY" list 2>/dev/null | grep -q " $SESSION "; then
    echo "=============================================================="
    echo "  An existing \"$SESSION\" session will be deleted before the"
    echo "  new run. If you want to replay the previous one first, do it"
    echo "  now from another terminal:"
    echo "      $HTY replay $SESSION"
    echo "      $HTY logs $SESSION"
    echo
    echo "  Press Enter here to delete it and start a fresh vim session."
    echo "=============================================================="
    read -r _
fi

# Clean slate. Remove the session record AND any vim swap file a previous
# interrupted run may have left behind — the swap file lives at
# ".<basename>.swp" in the same directory as the target. `delete` (not
# `kill`) frees the session name for reuse.
"$HTY" delete "$SESSION" 2>/dev/null || true
FILE_DIR="$(dirname "$FILE")"
FILE_BASE="$(basename "$FILE")"
rm -f "$FILE" "$FILE_DIR/.$FILE_BASE.swp" "$FILE.swp"

echo "[demo] spawning vim in hty session \"$SESSION\""
# -n disables swap file creation so an interrupted demo can never leave
# state behind that trips the next run's "ATTENTION" swap-file prompt.
"$HTY" run --name "$SESSION" -- vim -n -u NONE -U NONE --noplugin "$FILE"

echo "[demo] waiting for vim to settle..."
"$HTY" wait "$SESSION" --idle 400 --timeout 5000

# Prompt 2: vim is up and idle. Give the user time to attach a watcher.
echo
echo "=============================================================="
echo "  Vim is ready. In another terminal, run:"
echo "      $HTY watch $SESSION"
echo "  (or '$HTY attach $SESSION' for bidirectional)"
echo
echo "  Then come back here and press Enter to drive the session."
echo "=============================================================="
read -r _

echo "[demo] typing into the buffer (character by character)..."
for ch in i w a t c h e d " " b y " " a n o t h e r " " t e r m i n a l; do
    "$HTY" send "$SESSION" --text "$ch"
    sleep 0.15
done
"$HTY" wait "$SESSION" --idle 200 --timeout 2000
sleep 1

echo "[demo] leaving insert mode..."
"$HTY" send "$SESSION" --key esc
"$HTY" wait "$SESSION" --idle 200 --timeout 2000
sleep 1

echo "[demo] saving and quitting..."
"$HTY" send "$SESSION" --text ":"
sleep 0.3
"$HTY" send "$SESSION" --text "w"
sleep 0.3
"$HTY" send "$SESSION" --text "q"
sleep 0.3
"$HTY" send "$SESSION" --key enter

echo "[demo] waiting for vim to exit..."
"$HTY" wait "$SESSION" --exit --timeout 5000

echo "[demo] done."
echo
echo "file contents:"
cat "$FILE"
echo

# Prompt 3: the session is a zombie now (vim exited cleanly) but the
# record, log file, and by-name symlink are all still on disk so you
# can replay or inspect it. Only delete after the user opts in.
echo "=============================================================="
echo "  Session \"$SESSION\" is done but still on disk. You can:"
echo "      $HTY replay $SESSION"
echo "      $HTY logs $SESSION"
echo
echo "  Press Enter to delete it, or Ctrl-C to keep it around."
echo "=============================================================="
read -r _

"$HTY" delete "$SESSION" 2>/dev/null || true
echo "[demo] session deleted."
