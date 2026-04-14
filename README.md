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

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/LatentEvals/hty/main/scripts/install.sh | sh
```

Auto-detects OS and architecture, downloads the latest release binary, verifies the checksum, and installs to `~/.local/bin`. Use `--install-dir` or `HTY_INSTALL_DIR` to change the target. Or grab a specific platform from the [releases page](https://github.com/LatentEvals/hty/releases/latest).

<details>
<summary>Other install methods</summary>

**Homebrew**

```sh
brew install LatentEvals/tap/hty
```

**From source** — requires [Zig](https://ziglang.org) 0.15+.

```sh
git clone https://github.com/LatentEvals/hty.git
cd hty
zig build -Doptimize=ReleaseFast
sudo cp zig-out/bin/hty /usr/local/bin/
```

</details>

## Quickstart

Drive `git add -p` — the interactive git workflow agents can't handle today:

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

The server auto-starts on first use and persists across invocations, so sessions outlive individual `hty` calls. Open a second terminal and run `hty watch review` while the session is live to see exactly what the agent sees.

## Features

<table>
  <tr>
    <td width="33%" valign="top">
      <strong>Any interactive program</strong><br />
      <code>vim</code>, <code>psql</code>, <code>btop</code>, <code>git add -p</code>, <code>gh auth login</code>, <code>create-next-app</code>. If a human can use it, an agent can.
    </td>
    <td width="33%" valign="top">
      <strong>Sessions persist</strong><br />
      The server auto-starts and keeps sessions alive across invocations. Multiple tools can drive one session concurrently.
    </td>
    <td width="33%" valign="top">
      <strong>Watch live</strong><br />
      Run <code>hty watch</code> from another terminal to see exactly what the agent sees, in real time. Read-only, no interference.
    </td>
  </tr>
  <tr>
    <td width="33%" valign="top">
      <strong>Full replay</strong><br />
      Every session is recorded to an append-only JSONL log. <code>hty replay</code> plays it back through a fresh VT engine.
    </td>
    <td width="33%" valign="top">
      <strong>Wait primitives</strong><br />
      <code>--text</code> for substring, <code>--idle</code> for output settling, <code>--exit</code> for process end. All with timeouts.
    </td>
    <td width="33%" valign="top">
      <strong>Remote observation</strong><br />
      Point <code>$HTY_SOCKET</code> at an SSH-tunneled remote server. <code>watch</code> or <code>attach</code> with zero protocol changes.
    </td>
  </tr>
  <tr>
    <td width="33%" valign="top">
      <strong>Single binary</strong><br />
      One <code>curl | sh</code> and you're running. Zero runtime dependencies. Fast startup, easy distribution.
    </td>
    <td width="33%" valign="top">
      <strong>Production VT engine</strong><br />
      Powered by <a href="https://ghostty.org">Ghostty</a>. Accurate color, cursor, wide characters, and every escape sequence.
    </td>
    <td width="33%" valign="top">
      <strong>AI-readable docs</strong><br />
      The <a href="https://hty.sh">docs site</a> serves <a href="https://hty.sh/llms.txt">llms.txt</a> and a <code>.md</code> of every page for agent ingestion.
    </td>
  </tr>
</table>

## Concepts

- **[Sessions](https://hty.sh/concepts/sessions)** — a session is a real PTY running your program, identified by a UUID or a human-friendly `--name`. Sessions are isolated from each other and from your terminal.
- **[Background server](https://hty.sh/concepts/server)** — a persistent process that owns all session state. It auto-starts on first use, talks to clients over a Unix socket, and keeps sessions alive across individual `hty` commands.
- **[Session logs](https://hty.sh/concepts/session-logs)** — every input and output byte is written to a per-session append-only JSONL log. `hty logs` streams raw events; `hty replay` feeds them back through a fresh VT engine long after the session has ended.

## Commands

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

## Development

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

## License

MIT License

Copyright (c) 2026 Montana Flynn & [LatentEvals](https://latentevals.com)

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
