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
  <a href="#install">Install</a> ·
  <a href="#try-it-git-add--p-in-6-lines">Try it</a> ·
  <a href="#what-you-unlock">Programs</a> ·
  <a href="#faq">FAQ</a> ·
  <a href="https://hty.sh">Docs</a> ·
  <a href="https://hty.sh/llms.txt">llms.txt</a>
</p>

---

Your agent writes great code. Then it hits `git add -p`, `gh auth login`, or `create-next-app` — programs that expect a human at the keyboard — and walls out. **hty puts a keyboard under its hands.**

`hty` wraps any interactive program in a persistent PTY session. Your agent reads the rendered terminal the way you do and types the way you would.

<!-- demo: side-by-side of Claude driving nethack via hty -->

## Install

**Driving hty from an agent?** (Claude Code, Codex, Cursor, Gemini — any agent that loads [skills](https://skills.sh))

Paste this into your agent:

> Install hty using this skill: https://hty.sh/skill.md

The agent fetches the skill, installs the `hty` CLI, and learns when and how to reach for it.

**Driving it yourself?**

```sh
curl -fsSL https://raw.githubusercontent.com/LatentEvals/hty/main/scripts/install.sh | sh
```

Auto-detects OS and architecture, verifies the checksum, and installs to `~/.local/bin`.

<details>
<summary>Homebrew, from source, skills CLI</summary>

**Homebrew**

```sh
brew install LatentEvals/tap/hty
```

**Skills CLI directly** (skips the agent prompt step)

```sh
npx skills add LatentEvals/hty --skill hty
```

**From source** — requires [Zig](https://ziglang.org) 0.15+.

```sh
git clone https://github.com/LatentEvals/hty.git
cd hty
zig build -Doptimize=ReleaseFast
sudo cp zig-out/bin/hty /usr/local/bin/
```

Prebuilt binaries for macOS (arm64, x86_64) and Linux (arm64, x86_64) are on the [releases page](https://github.com/LatentEvals/hty/releases/latest).

</details>

## Try it: `git add -p` in 6 lines

The interactive git workflow agents can't handle today:

```sh
# Start the session and wait for the first prompt in one call
hty run --name review --snapshot --wait-until-text "Stage this hunk" \
  --timeout 5000 -- git add -p

# Each send fuses input + wait + snapshot into a single round-trip
hty send review --text "y\n" --snapshot --wait-until-idle 200    # stage this hunk
hty send review --text "n\n" --snapshot --wait-until-idle 200    # skip the next
hty send review --text "q\n" --snapshot --wait-until-exit --timeout 2000
```

The server auto-starts on first use and persists across invocations, so sessions outlive individual `hty` calls. Open a second terminal and run `hty watch review` while the session is live to see exactly what the agent sees.

`hty run --remove` ties the session's lifetime to the child process — handy for one-shots like `hty run --attach --remove -- npm test` that should clean up after themselves.

Full walkthrough: [**hty.sh/get-started/quickstart**](https://hty.sh/get-started/quickstart). Agent-loop patterns: [**hty.sh/guides/ai-agents**](https://hty.sh/guides/ai-agents).

## What you unlock

Anything that runs in a terminal. A few common wins:

| | | |
| :--: | :--: | :--: |
| `git add -p` | `git rebase -i` | `gh auth login` |
| `create-next-app` | `npm init` | `ssh-keygen` |
| `vim` / `neovim` | `psql` | `redis-cli` |
| `htop` / `btop` | `k9s` | `lazygit` |

If a human can use it, an agent can too.

## Why not `expect` or `tmux send-keys`?

- **`expect` reads raw PTY bytes.** hty reads the **rendered screen** — the same thing a human sees. Cursor position, wide characters, and every escape sequence are handled correctly via [Ghostty](https://ghostty.org)'s VT engine.
- **`tmux send-keys` fires and hopes.** hty waits on conditions the agent can *read* before sending the next key — text, regex, idle, exit — each with a configurable timeout.
- **`asciinema-exec` records for humans.** hty is built to be read *by the agent, while running* — and every session is still recorded for later replay.

## Features

<table>
  <tr>
    <td width="33%" valign="top">
      <strong>Sessions persist</strong><br />
      The server auto-starts and keeps sessions alive across invocations. Multiple tools can drive one session concurrently.
    </td>
    <td width="33%" valign="top">
      <strong>Watch live</strong><br />
      Run <code>hty watch</code> from another terminal to see exactly what the agent sees, in real time. Read-only, no interference.
    </td>
    <td width="33%" valign="top">
      <strong>Full replay</strong><br />
      Every session is recorded to an append-only JSONL log. <code>hty replay</code> plays it back through a fresh VT engine.
    </td>
  </tr>
  <tr>
    <td width="33%" valign="top">
      <strong>Wait primitives</strong><br />
      <code>--text</code>, <code>--regex</code>, <code>--idle</code>, <code>--exit</code>. Fuse them into <code>run</code> and <code>send</code> with <code>--snapshot</code> for one-round-trip agent loops.
    </td>
    <td width="33%" valign="top">
      <strong>Remote observation</strong><br />
      Point <code>$HTY_SOCKET</code> at an SSH-tunneled remote server. <code>watch</code> or <code>attach</code> with zero protocol changes.
    </td>
    <td width="33%" valign="top">
      <strong>Single binary</strong><br />
      One <code>curl | sh</code> and you're running. Zero runtime dependencies. Fast startup, easy distribution.
    </td>
  </tr>
</table>

## FAQ

**Which AI agents work with hty?**
Any agent that can run shell commands. The [agent skill](https://hty.sh/skill.md) is wired up for Claude Code, Codex, Cursor, Gemini, and anything else the [skills CLI](https://skills.sh) supports. For everything else, point your agent at [`llms.txt`](https://hty.sh/llms.txt) and tell it to use `hty`.

**Does it work on Windows?**
Not natively — hty uses Unix PTYs. It works fine inside WSL.

**What happens to a session if my agent crashes?**
Nothing. Sessions live in the background server, not the agent's shell. Your next `hty` invocation finds the session exactly where it was.

**Can multiple tools drive the same session?**
Yes. The server is multi-writer: an agent can send keys while you `hty watch` from another terminal (read-only) or even `hty attach` (interactive, bidirectional).

**Does it play with MCP?**
hty is complementary to MCP. It's a single-binary CLI that any MCP server, slash command, or skill can shell out to. There's no hty MCP server because the subcommands themselves are already a clean, composable protocol.

**Can I drive a session on a remote machine?**
Yes — point `$HTY_SOCKET` at an SSH-tunneled Unix socket. See [remote observation](https://hty.sh/guides/remote-observation).

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

Run `hty help <command>` for per-subcommand flag details, or `hty keys` for the supported `--key` names. Full reference with examples: [**hty.sh/commands**](https://hty.sh/commands/run).

### Exit codes

| code | meaning |
| :--: | ------- |
| 0    | success |
| 1    | generic error |
| 2    | session not found |
| 3    | `wait` timed out |
| 4    | session prefix matched multiple sessions (ambiguous) |
| 5    | a session with that name already exists |

## Built with

- **[Ghostty](https://ghostty.org)** — production-grade VT engine for accurate terminal emulation.
- **[Zig](https://ziglang.org)** — fast startup, single-binary distribution, no runtime.

## Development

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
