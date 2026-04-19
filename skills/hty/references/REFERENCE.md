# hty command reference

Concise per-command flag reference. For the latest and most complete docs, fetch [hty.sh/llms-full.txt](https://hty.sh/llms-full.txt) or the per-command Markdown pages at `https://hty.sh/commands/<cmd>.md`.

## `hty run`

Spawn a program inside a fresh PTY session.

```
hty run [--name NAME] [--rows N] [--cols N] [--cwd PATH] [--scrollback N]
        [--remove] [--attach]
        [--snapshot [--ansi]] [--wait-until-* ...] [--timeout MS]
        -- program [args...]
```

| Flag | Default | Purpose |
|---|---|---|
| `--name NAME` | auto | Human-friendly alias. Must be unique across running sessions. |
| `--rows N` / `--cols N` | 24 / 80 | Initial PTY dimensions. |
| `--cwd PATH` | CWD | Child's working directory. |
| `--scrollback N` | 10000 | Scrollback buffer size. |
| `--remove` | off | Auto-delete the session when the child exits (any mechanism). |
| `--attach` | off | Foreground streaming mode. Mutually exclusive with `--snapshot` and `--wait-until-*`. |
| `--snapshot` | off | Print the post-spawn screen. Requires a `--wait-until-*` or `--wait-duration`. |
| `--ansi` | off | With `--snapshot`, print styled ANSI (not plain text). |
| `--wait-duration DUR` | — | Sleep DUR (ms), then snapshot. |
| `--wait-until-idle [MS]` | 100ms | Block until screen is quiet for MS. |
| `--wait-until-text STR` | — | Block until STR appears in rendered buffer. |
| `--wait-until-regex RE` | — | Block until POSIX extended regex matches. |
| `--wait-until-exit` | — | Block until the child process exits. |
| `--timeout DUR` | 30000 (ms) | Cap on any `--wait-until-*` (0 = none). |

`--detach` is accepted as a no-op (every `run` is detached by default). The `-d` short form was removed in v0.7.0.

## `hty send`

Send text, a named key, raw hex bytes, or a mouse event to a session.

```
hty send [SESSION] (--text STR | --key NAME | --hex HEX | --click ROW COL | --scroll-up | --scroll-down)
         [--snapshot] [--ansi] [--wait-until-* ...] [--timeout MS]
```

| Flag | Purpose |
|---|---|
| `--text "..."` | Literal text. Supports `\n`, `\r`, `\t`, `\\`. |
| `--key NAME` | Symbolic key. Run `hty keys` for the list. |
| `--hex HH` | Raw bytes (e.g. `--hex 1b5b41` for ESC `[` `A`). |
| `--click ROW COL` | 1-indexed mouse click. |
| `--scroll-up` / `--scroll-down` | Scroll events. |
| `--snapshot` + `--wait-until-*` | Fuse input + wait + snapshot into one round-trip. |

`SESSION` can be omitted when exactly one session is running.

## `hty snapshot`

Read the current rendered screen.

```
hty snapshot [SESSION] [--ansi] [--raw-text]
```

| Flag | Purpose |
|---|---|
| `--ansi` | Styled ANSI output (colors, cursor position). |
| `--raw-text` | Plain text, no escape sequences. Default is ANSI. |

## `hty wait`

Block until a session matches a condition. Exits non-zero on timeout (code 3).

```
hty wait [SESSION] (--text STR | --regex RE | --idle [MS] | --exit) [--timeout MS]
```

Useful standalone when you don't need the fused `--snapshot`.

## `hty list`

List running sessions. Columns: `ID | NAME | PROGRAM | STATUS | STARTED`.

Status values: `running`, `exited`, `failed`, `killed`. Exited/failed/killed records persist until `hty delete` (or auto-removed with `--remove`).

## `hty watch`

Real-time read-only stream of the session's rendered screen. Great for a human to see what the agent is doing.

```
hty watch [SESSION]
```

Ctrl-C to exit. Supports pre-creation: `hty watch foo` before `hty run --name foo -- …` parks the watcher until the session appears.

## `hty attach`

Interactive bidirectional attach. Your stdin is forwarded into the PTY; the session's output streams back. For agents, prefer `hty run --attach` if you're starting from scratch (fuses spawn + attach and avoids a tiny race window).

```
hty attach [SESSION]
```

Detach with `Ctrl-A d` (tmux-style prefix). `Ctrl-A Ctrl-A` sends a literal Ctrl-A to the session. Multiple clients can attach simultaneously.

## `hty kill`

Terminate the session's process. The session record stays for `hty replay` / `hty logs` until `hty delete`.

```
hty kill [SESSION]
```

## `hty delete`

Permanently remove the session record and its log file.

```
hty delete SESSION
```

## `hty logs`

Stream the JSONL event log for a session (works after the session has exited).

```
hty logs [SESSION] [--follow]
```

## `hty replay`

Replay a recorded session through a fresh VT engine. Pure, no side effects — the program isn't re-executed.

```
hty replay SESSION [--speed N]
```

## `hty export`

Convert a session log into a share-ready artifact.

```
hty export SESSION --format asciicast > run.cast
```

Currently supports [asciinema v2](https://docs.asciinema.org/manual/asciicast/v2/). Pairs with `agg` for GIF, `ffmpeg` for MP4.

## `hty keys`

Print all supported `--key` names. Includes arrow keys, function keys, Ctrl-/Alt-modifiers, and special keys like `enter`, `tab`, `esc`, `backspace`, `delete`.

## `hty info`

Print resolved paths (socket, log dir, install dir) and server status. Useful for debugging or for SSH-tunnel setups.

## `hty help`

Print help. `hty help <command>` for per-subcommand detail.

## Exit codes

| Code | Meaning |
|:---:|---|
| 0 | Success |
| 1 | Generic error |
| 2 | Session not found |
| 3 | `wait` timed out |
| 4 | Ambiguous session prefix |
| 5 | Session name already exists |

## Environment variables

| Variable | Purpose |
|---|---|
| `HTY_SOCKET` | Override the client's Unix socket path. Points at a remote server over SSH tunnel. When set, the client never auto-spawns a local server. |
| `HTY_INSTALL_DIR` | Install target for `scripts/install.sh`. Default: `~/.local/bin`. |
