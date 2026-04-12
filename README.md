# hty

`hty` gives AI agents a way to use interactive TUI and CLI programs — `vim`, `git add -p`, `create-next-app`, `psql`, `btop`, `gh auth login` — by reading the rendered screen and sending keys.

## Install

### Install script

```sh
curl -fsSL https://raw.githubusercontent.com/montanaflynn/hty/main/scripts/install.sh | sh
```

Auto-detects your OS and architecture, downloads the latest release binary, verifies the checksum, and installs to `~/.local/bin`. Use `--install-dir` or `HTY_INSTALL_DIR` to change the target directory.

Or download a specific platform from the [releases page](https://github.com/montanaflynn/hty/releases/latest).

### Homebrew

```sh
brew install montanaflynn/tap/hty
```

### From source

Requires [Zig](https://ziglang.org) 0.15+. Ghostty's VT engine is fetched automatically by the Zig package manager.

```sh
git clone https://github.com/montanaflynn/hty.git
cd hty
zig build -Doptimize=ReleaseFast
sudo cp zig-out/bin/hty /usr/local/bin/
```

## Quick start

An agent walking through `git add -p` to stage specific hunks:

```sh
hty run --name review -- git add -p
hty wait review --text "Stage this hunk" --timeout 5000
hty snapshot review                       # read the screen
hty send review --text "y"                # stage this hunk
hty send review --key enter
hty wait review --idle 200 --timeout 3000
hty send review --text "n"                # skip the next one
hty send review --key enter
hty send review --text "q"
hty send review --key enter
hty wait review --exit --timeout 2000
```

The server auto-starts on first use and persists across invocations, so sessions outlive individual `hty` calls and can be observed from other terminals with `hty watch`.

### Try the demo

`scripts/demo-vim.sh` drives `vim` end-to-end through `hty` while you watch it live from a second terminal.

In terminal A:

```sh
zig build
./scripts/demo-vim.sh
```

In terminal B (any time during the demo):

```sh
./zig-out/bin/hty watch demo-vim
```

Terminal B shows vim opening, `watched by another terminal` appearing character-by-character in insert mode, `:wq` at the status bar, and vim exiting — all unattended.

Because every session is logged, you can re-watch the whole thing later with:

```sh
./zig-out/bin/hty replay demo-vim
```

## Commands

```
$ hty --help
Usage:
  hty <command> [args...]

Commands:
  run       Start a new detached session in a fresh PTY
  list      List running sessions
  watch     Observe a session's rendered screen in real time (read-only)
  send      Send text, a named key, or raw hex bytes to a session
  snapshot  Read the current rendered screen of a session
  wait      Block until the session matches a condition (text/idle/exit)
  kill      Terminate a session's process (the record stays for replay)
  delete    Permanently remove a session record and its log file
  logs      Show the event log for a session (works after it has exited)
  replay    Replay a recorded session by feeding its logged output back
            through a fresh in-memory VT engine. No side effects.
  attach    Interactively attach to a running session (bidirectional)
  keys      Print supported symbolic key names for `hty send --key`
  help      Print help. Pass a subcommand for details.

Sessions are identified by a UUIDv7 (shown as its first 8 chars) or by a
human-friendly `--name`. Any unambiguous prefix resolves to a full ID.
If only one session is running, the session argument can be omitted.

Examples:
  hty run --name debug-vim -- vim /tmp/foo.txt
  hty list
  hty watch debug-vim
  hty send debug-vim --text "ihello"
  hty send debug-vim --key esc
  hty wait debug-vim --idle 300 --timeout 2000
  hty kill debug-vim
```

Run `hty help <command>` for per-subcommand flag details, or `hty keys` for the supported `--key` names.

### Exit codes

| code | meaning |
| --- | --- |
| 0 | success |
| 1 | generic error |
| 2 | session not found |
| 3 | `wait` timed out |
| 4 | session prefix matched multiple sessions (ambiguous) |
| 5 | a session with that name already exists |

## Remote observation

The client's socket path can be overridden with `$HTY_SOCKET`, which makes it straightforward to watch, attach to, or drive a session running on another machine via an SSH tunnel:

```sh
# on the remote machine
hty run --name foo -- vim /tmp/bar.txt

# on your laptop
ssh -L /tmp/hty-remote.sock:/tmp/hty-501/sock user@remote
HTY_SOCKET=/tmp/hty-remote.sock hty attach foo
```

When `$HTY_SOCKET` is set, the client never auto-spawns a local server — if the endpoint isn't reachable it fails fast, so a broken tunnel is obvious instead of silently shadowed by a fresh local server.

## Under the hood

A PTY runtime built on [Ghostty](https://ghostty.org)'s VT engine, a persistent background server, and a flat subcommand CLI. Sessions live in the server across invocations; clients talk to it over a Unix socket. Every session is logged to an append-only JSONL file on disk so `hty logs` and `hty replay` work long after the session has ended.

**Status:** beta. The core surface is shipped — persistent server, named sessions, live observers (`hty watch`), interactive multi-writer attach (`hty attach`), append-only session event logs with `hty logs` / `hty replay`, the wait primitives, explicit session lifecycle (`hty kill` / `hty delete`), and remote observation via `$HTY_SOCKET` + SSH tunnels. See [docs/ROADMAP.md](docs/ROADMAP.md) for the post-beta polish backlog.

## Tests

```sh
zig build test
```

Coverage includes library spawn/snapshot/input/title, ANSI styling round-trip, UUIDv7 generation, session registry behavior, the subcommand dispatch, and end-to-end integration against `/bin/cat`, `nano`, `emacs`, and `top` using the wait primitives.

## Debug utilities

`hty-demo` is a standalone framed wrapper that opens its own PTY in its own process — it does **not** talk to the session server. It's kept as a development aid for the VT engine and as the base code `hty attach` will be built on top of in a future phase. For normal use, prefer `hty run` + `hty watch`.

```sh
./zig-out/bin/hty-demo btop
./zig-out/bin/hty-demo vim
```

`Ctrl-Q` kills the child and exits.

## More

- [docs/ROADMAP.md](docs/ROADMAP.md) — vision, shipped phases, and what's next.
- [docs/BLOG.md](docs/BLOG.md) — long-form design notes and draft blog posts.
