#!/usr/bin/env bash
#
# record-fixture.sh — capture a real-program session as a committed fixture
# for the VT fixture test suite (src/vt_fixture_test.zig).
#
# What it does:
#   1. Spawn `program args...` inside a fresh hty session (fixed rows/cols
#      so the resulting log replays deterministically).
#   2. Optionally run a driver script that sends keys / waits via `hty send`
#      and `hty wait`. The driver sees $HTY and $SESSION in its environment.
#   3. Kill the session and export its JSONL log into
#      testdata/sessions/<name>.jsonl.
#   4. Delete the session record so the local log dir stays clean.
#
# Usage:
#   scripts/record-fixture.sh \
#       --name NAME \
#       [--rows N] [--cols N] \
#       [--settle MS] \
#       [--drive SCRIPT] \
#       -- program [args...]
#
# After recording, generate the goldens:
#   UPDATE_GOLDENS=1 zig build test
#
# Then review the diff and commit the .jsonl plus both .golden files.
#
set -euo pipefail

HTY="${HTY:-./zig-out/bin/hty}"

NAME=""
ROWS=24
COLS=80
SETTLE_MS=500
DRIVE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --name) NAME="$2"; shift 2 ;;
        --rows) ROWS="$2"; shift 2 ;;
        --cols) COLS="$2"; shift 2 ;;
        --settle) SETTLE_MS="$2"; shift 2 ;;
        --drive) DRIVE="$2"; shift 2 ;;
        --) shift; break ;;
        -h|--help)
            sed -n '2,/^set -euo/p' "$0" | sed 's/^# \{0,1\}//' | head -n -1
            exit 0
            ;;
        *)
            echo "unknown flag: $1" >&2
            echo "run with --help for usage" >&2
            exit 2
            ;;
    esac
done

if [[ -z "$NAME" ]]; then
    echo "--name is required" >&2
    exit 2
fi
if [[ $# -eq 0 ]]; then
    echo "missing program after --" >&2
    exit 2
fi
if [[ ! -x "$HTY" ]]; then
    echo "hty binary not found at $HTY — build it with 'zig build'" >&2
    exit 1
fi

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="$REPO_ROOT/testdata/sessions"
OUT="$OUT_DIR/$NAME.jsonl"
mkdir -p "$OUT_DIR"

# Make sure any previous record under this name is gone — the name
# must be free for `hty run` to claim it.
"$HTY" delete "$NAME" >/dev/null 2>&1 || true

echo "[record] spawning: $*"
"$HTY" run --name "$NAME" --rows "$ROWS" --cols "$COLS" -- "$@"

# Initial settle: let the program paint its first frame.
"$HTY" wait "$NAME" --idle "$SETTLE_MS" --timeout 5000 || true

if [[ -n "$DRIVE" ]]; then
    if [[ ! -r "$DRIVE" ]]; then
        echo "driver script not readable: $DRIVE" >&2
        "$HTY" kill "$NAME" >/dev/null 2>&1 || true
        "$HTY" delete "$NAME" >/dev/null 2>&1 || true
        exit 1
    fi
    echo "[record] driving via $DRIVE"
    HTY="$HTY" SESSION="$NAME" bash "$DRIVE"
    # Final settle after the driver finishes — catches any trailing
    # animation frames before we kill.
    "$HTY" wait "$NAME" --idle "$SETTLE_MS" --timeout 5000 || true
fi

echo "[record] killing session"
"$HTY" kill "$NAME" >/dev/null 2>&1 || true

echo "[record] exporting log → $OUT"
"$HTY" logs "$NAME" --json > "$OUT"

echo "[record] cleaning up session record"
"$HTY" delete "$NAME" >/dev/null 2>&1 || true

echo
echo "Recorded $(wc -l < "$OUT" | tr -d ' ') events ($(wc -c < "$OUT" | tr -d ' ') bytes)."
echo "Next:"
echo "  UPDATE_GOLDENS=1 zig build test"
echo "  git add testdata/sessions/$NAME.*"
