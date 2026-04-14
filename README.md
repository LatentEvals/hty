<p align="center">
  <img src="website/app/icon.svg" alt="hty" width="96">
</p>

<h1 align="center">hty</h1>

<p align="center">
  <strong>Puppeteer for the terminal. Drive any interactive CLI with AI.</strong>
</p>

<p align="center">
  <a href="https://github.com/LatentEvals/hty/actions/workflows/test.yml"><img alt="CI" src="https://img.shields.io/github/actions/workflow/status/LatentEvals/hty/test.yml?branch=main&label=tests"></a>
  <a href="https://github.com/LatentEvals/hty/releases/latest"><img alt="Release" src="https://img.shields.io/github/v/release/LatentEvals/hty?include_prereleases"></a>
  <a href="#license"><img alt="License" src="https://img.shields.io/badge/license-MIT-blue.svg"></a>
  <a href="https://ziglang.org"><img alt="Built with Zig" src="https://img.shields.io/badge/built%20with-Zig-F7A41D?logo=zig&logoColor=white"></a>
  <a href="https://hty.sh"><img alt="Docs" src="https://img.shields.io/badge/docs-hty.sh-0969da"></a>
</p>

<p align="center">
  <a href="#quickstart">Quickstart</a> ·
  <a href="#install">Install</a> ·
  <a href="#commands">Commands</a> ·
  <a href="https://hty.sh">Docs</a> ·
  <a href="https://hty.sh/llms.txt">llms.txt</a>
</p>

---

## Why hty exists

Unlock a world of TUI and CLI software for your AI agent.

If you've used agents, you've seen them struggle with things like `create-next-app`, or watched them try to stage a sprawling diff by shuffling files into `/tmp`, `rm`-ing changes, and getting hopelessly confused. If only they could use `git add -p`. Well, now they can.

`hty` wraps any interactive program in a persistent PTY session. Your agent reads the rendered terminal the way you do and types the way you would.

## Quickstart

```sh
hty run --name app -- create-next-app my-app
hty wait app --text "TypeScript" --timeout 5000
hty send app --text "y\n"
hty wait app --exit --timeout 60000
hty delete app
```

That's the whole loop: **start → wait → send → repeat → delete**. Open a second terminal and run `hty watch app` to see the session rendered live while the agent drives it.

### Full example: driving `git add -p`

```sh
hty run --name review -- git add -p
hty wait review --text "Stage this hunk" --timeout 5000
hty snapshot review                       # read the screen
hty send review --text "y\n"              # stage this hunk
hty wait review --idle 200 --timeout 3000
hty send review --text "n\n"              # skip the next one
hty send review --text "q\n"
hty wait review --exit --timeout 2000
```

The server auto-starts on first use and persists across invocations, so sessions outlive individual `hty` calls and can be observed from other terminals with `hty watch`.

### Try it live

`scripts/demo-vim.sh` drives `vim` end-to-end through `hty` while you watch it from a second terminal.

```sh
# terminal A
zig build && ./scripts/demo-vim.sh

# terminal B (any time during the demo)
./zig-out/bin/hty watch demo-vim
```

Terminal B shows vim opening, `watched by another terminal` typed character-by-character in insert mode, `:wq` at the status bar, and vim exiting — all unattended. Because every session is logged, you can re-watch the whole thing later with `hty replay demo-vim`.

## Features

<table>
  <tr>
    <td width="33%" valign="top">
      <h4>🖥️ Any interactive program</h4>
      <code>vim</code>, <code>psql</code>, <code>btop</code>, <code>git add -p</code>, <code>gh auth login</code>, <code>create-next-app</code> — if a human can use it, an agent can too.
    </td>
    <td width="33%" valign="top">
      <h4>🔁 Sessions persist</h4>
      The server auto-starts and keeps sessions alive across invocations. Pick up where you left off; multiple tools can drive the same session.
    </td>
    <td width="33%" valign="top">
      <h4>👀 Watch live</h4>
      Open another terminal and run <code>hty watch</code> to see exactly what the agent sees, in real time. Read-only — no interference.
    </td>
  </tr>
  <tr>
    <td width="33%" valign="top">
      <h4>🎬 Full replay</h4>
      Every session is recorded to an append-only JSONL log. <code>hty replay</code> plays it back through a fresh VT engine — debug what happened, or demo it.
    </td>
    <td width="33%" valign="top">
      <h4>⏱️ Wait primitives</h4>
      <code>--text</code> for substring match, <code>--idle</code> for output settling, <code>--exit</code> for process completion — all with timeouts. No <code>sleep 2</code> and hope.
    </td>
    <td width="33%" valign="top">
      <h4>🌐 Remote observation</h4>
      Point <code>$HTY_SOCKET</code> at a remote server over an SSH tunnel — <code>watch</code> or <code>attach</code> to sessions running there. No protocol changes.
    </td>
  </tr>
  <tr>
    <td width="33%" valign="top">
      <h4>📦 Single binary</h4>
      One <code>curl | sh</code> and you're running. Zero runtime dependencies. Built in Zig for fast startup and easy distribution.
    </td>
    <td width="33%" valign="top">
      <h4>⚙️ Production VT engine</h4>
      Powered by <a href="https://ghostty.org">Ghostty</a>'s terminal emulator. Handles color, cursor position, wide characters, and every escape sequence real TUIs emit.
    </td>
    <td width="33%" valign="top">
      <h4>🤖 AI-readable docs</h4>
      The <a href="https://hty.sh">docs site</a> serves <a href="https://hty.sh/llms.txt">llms.txt</a> and a <code>.md</code> version of every page, so agents can ingest hty's own docs cleanly.
    </td>
  </tr>
</table>

## Install

### Install script

```sh
curl -fsSL https://raw.githubusercontent.com/LatentEvals/hty/main/scripts/install.sh | sh
```

Auto-detects your OS and architecture, downloads the latest release binary, verifies the checksum, and installs to `~/.local/bin`. Use `--install-dir` or `HTY_INSTALL_DIR` to change the target.

Or grab a specific platform from the [releases page](https://github.com/LatentEvals/hty/releases/latest).

### Homebrew

```sh
brew install LatentEvals/tap/hty
```

### From source

Requires [Zig](https://ziglang.org) 0.15+.

```sh
git clone https://github.com/LatentEvals/hty.git
cd hty
zig build -Doptimize=ReleaseFast
sudo cp zig-out/bin/hty /usr/local/bin/
```

## How it works

```
┌─────────────┐   unix       ┌──────────────┐   PTY    ┌────────────┐
│ hty <cmd>   │  ──socket──▶ │  hty server  │ ──fork─▶ │  program   │
│ (client)    │              │ (persistent) │          │ (vim, etc) │
└─────────────┘              └──────┬───────┘          └────────────┘
                                    │
                                    ▼
                             append-only
                            JSONL event log
                             (hty logs /
                              hty replay)
```

- **Clients** — every `hty` command you run is a short-lived client that serializes a JSON request, sends it over a Unix socket, and exits.
- **Server** — a persistent background process owns all session state. It auto-starts on first use and runs unattended.
- **PTY sessions** — each session is a real pseudoterminal running your program. The server reads the program's output through a VT engine (Ghostty's) and exposes the rendered screen to clients.
- **JSONL logs** — every input and output byte is written to a per-session append-only log. `hty logs` streams raw events; `hty replay` feeds them back through a fresh VT engine long after the session has ended.

See [docs.hty.sh/concepts](https://hty.sh/concepts/sessions) for the full architecture.

## Status

hty is in **beta**. The core surface is shipped and stable in everyday use.

|   | Feature                                                  | Status |
| - | -------------------------------------------------------- | :----: |
| 1 | Persistent background server + Unix socket protocol      |   ✅   |
| 2 | Named sessions with UUIDv7 and prefix resolution         |   ✅   |
| 3 | Live observers (`hty watch`) — read-only rendering       |   ✅   |
| 4 | Interactive multi-writer `hty attach`                    |   ✅   |
| 5 | Append-only JSONL event logs + `hty logs` / `hty replay` |   ✅   |
| 6 | Wait primitives (`--text`, `--idle`, `--exit`)           |   ✅   |
| 7 | Explicit session lifecycle (`hty kill` / `hty delete`)   |   ✅   |
| 8 | Remote observation via `$HTY_SOCKET` + SSH               |   ✅   |
| 9 | Post-beta polish — stabilized protocol, more platforms   |   🚧   |

## Commands

<details>
<summary><code>hty --help</code></summary>

```
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
  info      Show resolved paths and server status
  help      Print help. Pass a subcommand for details.

Sessions are identified by a UUIDv7 (shown as its first 8 chars) or by a
human-friendly `--name`. Any unambiguous prefix resolves to a full ID.
If only one session is running, the session argument can be omitted.
```

</details>

Run `hty help <command>` for per-subcommand flag details, or `hty keys` for the supported `--key` names. Full reference with examples lives at **[hty.sh/commands](https://hty.sh/commands/run)**.

### Exit codes

| code | meaning |
| :--: | ------- |
| 0    | success |
| 1    | generic error |
| 2    | session not found |
| 3    | `wait` timed out |
| 4    | session prefix matched multiple sessions (ambiguous) |
| 5    | a session with that name already exists |

## Remote observation

The client's socket path can be overridden with `$HTY_SOCKET`, which makes it straightforward to watch, attach to, or drive a session running on another machine via an SSH tunnel:

```sh
# on the remote machine — find the socket path
hty info

# on your laptop — tunnel the remote socket locally
ssh -L ~/.local/state/hty/remote.sock:<socket-from-hty-info> user@remote
HTY_SOCKET=~/.local/state/hty/remote.sock hty attach foo
```

When `$HTY_SOCKET` is set, the client never auto-spawns a local server — if the endpoint isn't reachable it fails fast, so a broken tunnel is obvious instead of silently shadowed by a fresh local server.

## Built with

- **[Ghostty](https://ghostty.org)** — production-grade VT engine for accurate terminal emulation.
- **[Zig](https://ziglang.org)** — fast startup, single-binary distribution, no runtime.

<details>
<summary>Development</summary>

### Tests

```sh
zig build test
```

Coverage includes library spawn/snapshot/input/title, ANSI styling round-trip, UUIDv7 generation, session registry behavior, subcommand dispatch, and end-to-end integration against `/bin/cat`, `nano`, `emacs`, and `top` using the wait primitives.

### Debug utilities

`hty-demo` is a standalone framed wrapper that opens its own PTY in its own process — it does **not** talk to the session server. It's kept as a development aid for the VT engine. For normal use, prefer `hty run` + `hty watch`.

```sh
./zig-out/bin/hty-demo btop
./zig-out/bin/hty-demo vim
```

`Ctrl-Q` kills the child and exits.

</details>

## License

MIT © Montana Flynn · [LatentEvals](https://latentevals.com)
