# Roadmap

**Current status: beta.** The core feature surface is complete and shipped. Everything below is optional polish — none of it gates normal use.

## What hty is for

Three audiences, one primitive (a rendered screen plus a way to drive it):

- **AI agents** that need to drive interactive programs they can't reach through `bash -c` — editors, REPLs, TUIs, scaffolding wizards, CLI setup and auth flows, interactive git.
- **Humans** who want to see what an agent (or anyone) is doing inside a session, live or in replay.
- **CI/CD** pipelines that need to automate interactive CLIs and assert on their rendered state.

### Core use cases

Roughly ordered by how often a typical developer hits them:

- **Scaffolding wizards.** `create-next-app`, `create-vite`, `nuxi init`, `bun create`, `cargo generate`, Rails `new`. Every modern framework ships its "new project" flow as an interactive Q&A. Agents today either can't answer these prompts or have to hand-maintain a fragile list of `--flag` equivalents that silently rot as tools add new questions.
- **CLI setup and auth flows.** `gh auth login`, `firebase init`, `supabase init`, `vercel`, `railway login`, `aws configure`, `stripe login`, `gcloud init`. All interactive. All blocking for agents.
- **Package manager prompts.** `npm init`, `yarn create`, `pnpm create`, interactive `cargo` workflows — anything that walks you through a questionnaire before writing a file.
- **Interactive git flows.** `git add -p` for hunk-level staging, `git rebase -i` for history rewrites, `git mergetool` for conflict resolution.
- **In-editor edits.** Agent drives `nano` or `vim` to make targeted changes where diff-based editing is awkward.
- **REPLs with mixed output.** `psql`, `ipython`, `ghci`, `redis-cli`, `mongosh` — where the "screen state" is the meaningful unit, not a stream.
- **TUI dashboards.** Agent observes `btop`, `k9s`, `lazygit`, `htop` and responds to what's on screen.
- **End-to-end smoke tests.** Validate that your own shell-based tool actually works for a human, by having an agent do exactly that.

## What's shipped

- **Persistent background server** with tmux-style auto-start, 10s idle auto-shutdown, XDG runtime/state paths with 0700 perms, exec-based server fork.
- **Flat subcommand CLI:** `run`, `list`, `watch`, `send`, `snapshot`, `wait`, `kill`, `delete`, `logs`, `replay`, `attach`, `keys`, `help`.
- **UUIDv7 sessions** with prefix-growth display and optional `--name` alias.
- **Session lifecycle:** `kill` terminates the process but keeps the record for replay/logs. `delete` permanently removes the record and frees the name. Sessions persist across server restarts — `list` disk-scans the log directory for historical sessions.
- **Wait primitives:** `--text` (substring match), `--idle MS`, `--exit`, all with `--timeout MS`.
- **Live observer** (`hty watch`) — read-only, real-time screen rendering.
- **Interactive multi-writer attach** (`hty attach`) — bidirectional, Ctrl-A d detach, SIGWINCH forwarding. Multiple clients can attach concurrently.
- **Append-only JSONL event log** per session. Captures spawn, input, output (raw PTY bytes), title, bell, exited, failed, killed events. Stored at `$XDG_STATE_HOME/hty/logs/` with by-name symlinks.
- **`hty logs`** — reads the log from disk (works for exited sessions, across server restarts). `--follow`, `--since`, `--json`.
- **`hty replay`** — pure-visualization replay through a fresh in-memory Ghostty VT engine. `--speed`, `--at`, `--to`, `--loop`. Holds on the final frame until Ctrl-C.
- **Remote observation** via `$HTY_SOCKET` + SSH tunnels. No protocol changes needed.
- **Install tooling:** `curl | sh` installer, prebuilt release binaries (macOS arm64, Linux x86_64, Linux arm64), Homebrew tap (`brew install montanaflynn/tap/hty`), auto-updated on each release.
- **CI:** GitHub Actions test matrix (macOS arm64, Linux x86_64, Linux arm64), tag-triggered release workflow with Homebrew tap auto-update.

## Backlog

The unifying idea: **treat this like [Puppeteer](https://pptr.dev) for terminals.** The primitives that make headless-browser automation usable — `waitForSelector`, `waitForNetworkIdle`, bounding-box screenshots, retry-with-timeout — map almost directly onto TUI automation. That's the shape to aim for.

1. **End-to-end agent tests.** Drive `hty` from Claude, Codex, and Gemini against a fixed set of TUI scenarios (edit a file in `nano`, stage a hunk in `git add -p`, find the top process in `btop`, run a SQL query in `psql`). Assert on expected screen state. This is the real correctness signal — unit tests can't tell us whether the *protocol shape* is usable by a real agent.

2. **Regex-based `hty wait --regex`.** Today `--text` does substring matching. Regex adds anchored-match and alternation.

3. **Snapshot diffs.** Return only cells that changed since the last snapshot. A 24×80 `screen_ansi` is ~3-5KB with styling; fifty snapshots in a session is real token cost. Diff mode would cut that by an order of magnitude.

4. **Region snapshots.** `hty snapshot --region row,col,rows,cols` — constrain to a bounding box. For 120×40 `htop`, the agent usually only cares about one pane.

5. **Function keys and modifier combos.** Currently supports arrows, ctrl-* chords, and common named keys. Missing F1-F12, Alt-* combos, and shift-arrow sequences.

6. **Mouse passthrough.** Some TUIs (`lazygit`, modern `vim` configs) accept mouse input. Expose it behind an explicit opt-in.

7. **Native TCP listener with auth.** An alternative to SSH tunneling: the server optionally binds a TCP port with shared-token or public-key authentication. Cleaner UX for teams but a bigger auth surface.

## Design notes

Long-form thinking about why `hty` exists and the calls that shaped it — Zig, Ghostty, the subcommand surface, the replay strategy — lives in [BLOG.md](BLOG.md).
