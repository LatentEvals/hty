# Roadmap

**Current status: beta.** Phases 1–3 are shipped and the core feature surface is complete. Everything below Phase 3 is optional polish — none of it gates normal use.

## What hty is for

Three audiences, one primitive (a rendered screen plus a way to drive it):

- **AI agents** that need to drive interactive programs they can't reach through `bash -c` — editors, REPLs, TUIs, scaffolding wizards, CLI setup and auth flows, interactive git.
- **Humans** who want to see what an agent (or anyone) is doing inside a session, live or in replay.
- **CI/CD** pipelines that need to automate interactive CLIs and assert on their rendered state.

### Core use cases

Roughly ordered by how often a typical developer hits them:

- **Scaffolding wizards.** `create-next-app`, `create-react-app`, `create-vite`, `nuxi init`, `bun create`, `cargo generate`, Rails `new`. Every modern framework ships its "new project" flow as an interactive Q&A — project name, template, TypeScript y/n, ESLint y/n, Tailwind y/n, package manager. Agents today either can't answer these prompts or have to hand-maintain a fragile list of `--flag` equivalents that silently rot as tools add new questions.
- **CLI setup and auth flows.** `gh auth login`, `firebase init`, `supabase init`, `vercel`, `railway login`, `aws configure`, `stripe login`, `gcloud init`, `openclaw onboard`, installing and configuring Claude Code / Codex / Gemini CLI themselves. All interactive. All blocking for agents.
- **Package manager prompts.** `npm init`, `yarn create`, `pnpm create`, interactive `cargo` workflows — anything that walks you through a questionnaire before writing a file.
- **Interactive git flows.** `git add -p` for hunk-level staging, `git rebase -i` for history rewrites, `git mergetool` for conflict resolution.
- **In-editor edits.** Agent drives `nano` or `vim` to make targeted changes where diff-based editing is awkward.
- **REPLs with mixed output.** `psql`, `ipython`, `ghci`, `redis-cli`, `mongosh` — where the "screen state" is the meaningful unit, not a stream.
- **TUI dashboards.** Agent observes [`btop`](https://github.com/aristocratos/btop), [`k9s`](https://k9scli.io), [`lazygit`](https://github.com/jesseduffield/lazygit), [`htop`](https://htop.dev) and responds to what's on screen.
- **End-to-end smoke tests.** Validate that your own shell-based tool actually works for a human, by having an agent do exactly that.

## Shipping phases

### Phase 1 — shipped

Persistent background server with tmux-style auto-start, UUIDv7 named sessions with prefix-growth display, multi-writer attach, the subcommand surface (`hty run`/`list`/`watch`/`send`/`snapshot`/`wait`/`kill`), the `wait_for_text` / `wait_for_idle` / `wait_for_exit` primitives, and the two-terminal vim observer demo.

### Phase 2 — shipped

- **Cleanup sweep.** Server auto-shuts-down after ten seconds with no running sessions. Socket lives at `$XDG_RUNTIME_DIR/hty/sock` (fallback `/tmp/hty-$UID/sock`) with 0700 on the enclosing directory. Server is now `exec`-ed as `hty __server__ <sock>` so `ps`/`pgrep` can find it by a distinct argv. Dead `poll`/`wait` ops from the pre-subcommand era are gone.
- **Session event log.** Every session writes an append-only JSONL log of spawn, input, output, title, bell, exit, killed, and failure events to `$XDG_STATE_HOME/hty/logs/<uuid>.jsonl` (fallback `~/.local/state/hty/logs`). A `by-name/<name>.jsonl` symlink points at the canonical file so `hty logs NAME` works without consulting the running server.
- **`hty logs [SESSION] [--follow|-f] [--since DUR] [--json]`** reads the log file directly from disk — works for exited sessions and even after the server has been restarted. Default output is a human-readable table; `--json` emits raw JSONL; `--follow` tails the file as new events are appended; `--since` trims to the last N ms/s/m/h of logged activity.
- **`hty replay [SESSION] [--speed Nx] [--at T] [--to T] [--loop]`** visually replays a session by feeding recorded output bytes through a fresh in-memory Ghostty VT engine. **Zero side effects** — no program is ever re-executed, no input is ever re-sent. Pure visualization, like watching a video of the session. This is the observability story's post-mortem half; the live half is Phase 1's `hty watch`.

Replay is the feature I care most about, because nothing else in the terminal automation space treats it as a first-class capability and it's the debugging tool that actually answers "what did my agent do that made the test fail?"

### Phase 3 — shipped

- **Interactive `hty attach`.** Read-write attach that mirrors your terminal into a running session so a human can take over work an agent started (or vice versa). Sets up alt-screen + raw mode, forwards stdin bytes as framed JSONL input frames, decodes output frames back to the observer's terminal, and forwards SIGWINCH so the child program sees the right LINES/COLUMNS. Tmux-style detach: `Ctrl-A d` detaches cleanly, `Ctrl-A Ctrl-A` passes a literal Ctrl-A through. Multiple clients can attach to the same session concurrently — input frames are atomic per-frame and output is broadcast.
- **Remote observation via `$HTY_SOCKET`.** The client's socket path is overridable via the `$HTY_SOCKET` environment variable, so the standard `ssh -L` tunnel pattern works out of the box: `ssh -L /tmp/hty-remote.sock:/tmp/hty-501/sock user@remote` on your laptop, then `HTY_SOCKET=/tmp/hty-remote.sock hty attach foo`. When the override is set, the client never auto-spawns a local server — a broken tunnel fails fast instead of being silently shadowed.

None of these later phases break the Phase 1 subcommand surface. They extend it.

### Phase 4 — later

- **Native TCP listener with auth.** An alternative to SSH tunneling: the server optionally binds a TCP port, clients authenticate via a shared token or public key. Cleaner UX for teams that don't want to deal with SSH forwarding but a bigger auth surface area.
- **End-to-end agent benchmarks.** Drive `hty` from Claude, Codex, and Gemini against a fixed set of TUI scenarios (edit a file in `nano`, stage a hunk in `git add -p`, find the top process in `btop`, run a SQL query in `psql`). Assert on expected screen state. See the Ergonomics backlog below for the rationale.

## Ergonomics backlog

Small improvements on deck once the bigger phases land:

1. **End-to-end agent tests.** Drive `hty` from Claude, Codex, and Gemini against a fixed set of TUI scenarios (edit a file in `nano`, stage a hunk in `git add -p`, find the top process in `btop`, run a SQL query in `psql`). Assert on expected screen state. This is the real correctness signal for the project — unit tests can't tell us whether the *protocol shape* is usable by a real agent.

2. **Regex-based `hty wait --regex`.** Today `--text` does substring matching. Regex adds anchored-match and alternation.

3. **Snapshot diffs.** Return only cells that changed since the last snapshot. A 24×80 `screen_ansi` is ~3-5KB with styling; fifty snapshots in a session is real token cost. Diff mode would cut that by an order of magnitude.

4. **Region snapshots.** `hty snapshot --region row,col,rows,cols` — constrain to a bounding box. For 120×40 `htop`, the agent usually only cares about one pane.

5. **Key-sequence dry-run.** `hty send --key ctrl-o --dry-run` returns the bytes it *would* send without sending them. Lets agents verify their key-naming assumptions before committing.

6. **Mouse passthrough.** Some TUIs (`lazygit`, modern `vim` configs) accept mouse input. Expose it behind an explicit opt-in.

7. **Richer key coverage.** Arrow keys, function keys, keypad, modifier combos beyond `ctrl-*`.

The unifying idea: **treat this like [Puppeteer](https://pptr.dev) for terminals.** The primitives that make headless-browser automation usable — `waitForSelector`, `waitForNetworkIdle`, bounding-box screenshots, retry-with-timeout — map almost directly onto TUI automation. That's the shape to aim for.

## Design notes

Long-form thinking about why `hty` exists and the calls that shaped it — Zig, Ghostty, the subcommand surface, the replay strategy — lives in [BLOG.md](BLOG.md). Those entries are rough drafts intended to eventually become proper blog posts.
