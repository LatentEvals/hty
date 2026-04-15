#!/usr/bin/env bash
#
# Driver for the vim-edit fixture. Invoked by record-fixture.sh with
# $HTY and $SESSION in the environment.
#
# To re-record this fixture (identical invocation is required so the
# replayed grid is stable across re-records):
#
#   rm -f /tmp/hty-fixture-vim.txt
#   ./scripts/record-fixture.sh --name vim-edit \
#       --drive scripts/fixtures/vim-edit.sh -- \
#       vim -n -u NONE -U NONE /tmp/hty-fixture-vim.txt
#   UPDATE_GOLDENS=1 zig build test
#
# Sequence: type "hello" in insert mode, leave insert, settle.
# We deliberately do NOT quit — record-fixture.sh will kill vim abruptly,
# so the recorded log ends on a real vim frame (buffer with text, tildes,
# status line). A clean `:wq` would leave a blank screen, which gives the
# golden zero signal for catching engine regressions.
#
set -euo pipefail

"$HTY" send "$SESSION" --text "ihello"
"$HTY" wait "$SESSION" --idle 200 --timeout 2000 || true

"$HTY" send "$SESSION" --key esc
"$HTY" wait "$SESSION" --idle 300 --timeout 2000 || true
