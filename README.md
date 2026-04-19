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

**Using an AI agent?** Install the [hty agent skill](https://hty.sh/skill.md) so Claude Code, Codex, Cursor, Gemini, and others know when and how to reach for `hty`:

```sh
npx skills add LatentEvals/hty --skill hty
```

Or point your agent at `https://hty.sh/skill.md` directly.

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
# Start the session and get the first screen in one call
hty run --name review --snapshot --wait-until-text "Stage this hunk" \
  --timeout 5000 -- git add -p

# Each send fuses input + wait + snapshot into a single round-trip
hty send review --text "y\n" --snapshot --wait-until-idle 200    # stage this hunk
hty send review --text "n\n" --snapshot --wait-until-idle 200    # skip the next
hty send review --text "q\n" --snapshot --wait-until-exit --timeout 2000
```

The server auto-starts on first use and persists across invocations, so sessions outlive individual `hty` calls. Open a second terminal and run `hty watch review` while the session is live to see exactly what the agent sees.

For one-shot invocations where you don't want the session record to linger, pass `hty run --remove`: the session is automatically deleted from the registry the moment the child process exits (success, failure, or signal). Handy for migration scripts, test runs, and agent-driven wizards where "fire and forget" is the whole point.

Want to spawn and attach in one call? `hty run --attach -- vim foo.txt` drops you straight into the session (streams output to stdout, forwards stdin with raw mode and SIGWINCH, `Ctrl-A d` to detach). Combine with `--remove` for a fully self-cleaning one-shot: `hty run --attach --remove -- npm test`.

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
      <code>--text</code>, <code>--regex</code>, <code>--idle</code>, <code>--exit</code>. Fuse them into <code>run</code> and <code>send</code> with <code>--snapshot</code> for one-round-trip agent loops.
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
  send      Send text, a named key, raw hex bytes, or a mouse event
            (click / scroll) to a session
  snapshot  Read the current rendered screen of a session
  wait      Block until the session matches a condition (text/idle/exit)
  kill      Terminate a session's process (the record stays for replay)
  delete    Permanently remove a session record and its log file
  logs      Show the event log for a session (works after it has exited)
  export    Convert a recorded session log into a share-ready artifact
            (currently asciinema v2 .cast)
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

## Export to GIF / MP4

Every session is recorded to a JSONL log. `hty export --format asciicast` converts that log into an [asciinema v2 cast](https://docs.asciinema.org/manual/asciicast/v2/), which plugs straight into the existing asciicast ecosystem:

```sh
hty export my-session --format asciicast > run.cast

# GIF — agg reads asciicast directly
agg run.cast run.gif

# MP4 — convert the GIF with ffmpeg
agg run.cast run.gif && ffmpeg -i run.gif run.mp4

# Share on asciinema.org
asciinema upload run.cast
```

Output and resize events are emitted faithfully. Input keystrokes are also included as `"i"` events with bursts coalesced (e.g. `hty send --text "hello"` becomes a single `"i"` frame). Most asciicast players ignore input frames during playback, which is the spec-correct behavior; any downstream renderer that wants to surface agent keystrokes has the data.

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

## License

MIT License

Copyright (c) 2026 Montana Flynn & [LatentEvals](https://latentevals.com)

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
