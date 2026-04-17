#!/usr/bin/env python3
"""Mouse-mode fixture for hty issue #24 integration tests.

Enables the mouse modes passed in argv (e.g. `1002 1006`), then reads
bytes from stdin and appends them to the file path given by
$HTY_MOUSE_RECORD. Exits when it reads a byte 0x04 (Ctrl-D / EOT) so
the test can terminate the session deterministically.

The test driver spawns this under `hty run`, drives `hty send --click`
/ `--drag` / `--scroll`, then reads the record file to assert the exact
bytes the target app received.
"""
import os
import sys
import termios
import tty

def main() -> int:
    modes = sys.argv[1:] or ["1002", "1006"]
    record_path = os.environ.get("HTY_MOUSE_RECORD")
    if not record_path:
        print("HTY_MOUSE_RECORD env var required", file=sys.stderr)
        return 1

    # Emit the enables in one write so the server's sniffer sees them
    # in a single raw_bytes event (the stream drainer may split writes
    # across events under load, but one human-scale print() fits easily).
    fd = sys.stdin.fileno()
    # Put the PTY in raw mode so bytes are delivered immediately without
    # line buffering or input processing — hty sends mouse sequences
    # without trailing newlines, so cooked mode would swallow them.
    try:
        old_attrs = termios.tcgetattr(fd)
        tty.setraw(fd)
    except termios.error:
        old_attrs = None

    seq = "".join(f"\x1b[?{m}h" for m in modes)
    sys.stdout.write(seq)
    sys.stdout.write("READY\n")
    sys.stdout.flush()
    with open(record_path, "ab", buffering=0) as f:
        while True:
            chunk = os.read(fd, 4096)
            if not chunk:
                break
            if b"\x04" in chunk:
                f.write(chunk.split(b"\x04", 1)[0])
                break
            f.write(chunk)
    return 0

if __name__ == "__main__":
    sys.exit(main())
