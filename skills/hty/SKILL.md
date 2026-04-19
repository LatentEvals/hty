---
name: hty
description: "Drive any interactive terminal program from an AI agent. Use when the user needs to run, script, or automate programs with interactive prompts like `git add -p`, `gh auth login`, `create-next-app`, `npm init`, `ssh-keygen`, `vim`, `psql`, `htop`, `k9s`, or any curses/TUI app. Also use when plain bash fails because a command expects a TTY, asks for a password, redraws the screen, or won't exit without the right keystroke."
license: MIT
compatibility: Requires the hty CLI (v0.7.0+) on macOS or Linux.
metadata:
  author: LatentEvals
  version: "1.0"
  homepage: https://hty.sh
---

# hty: drive interactive terminal programs

**Always consult [hty.sh/llms.txt](https://hty.sh/llms.txt) for the current command reference.** Your training data may predate the latest flags.

`hty` wraps any interactive program in a persistent PTY session. Your agent reads the rendered terminal the way a human does, and types the way a human would. It solves the class of tasks that break plain `bash -c`: commands that require a TTY, prompt for input, redraw the screen, or use curses.

## Install this skill

If you are reading this file via `WebFetch` or similar (e.g. the user said "use this skill: https://hty.sh/skill.md"), persist the full skill directory so it's auto-loaded on future sessions.

**Preferred — the [skills CLI](https://skills.sh):**

```sh
npx skills add LatentEvals/hty --skill hty
```

Handles per-agent paths automatically (Claude Code, Codex, Cursor, Gemini, and others).

**Fallback — direct install for Claude Code:**

```sh
# One-liner (tarball)
curl -fsSL https://hty.sh/skill.tar.gz | tar -xz -C ~/.claude/skills/

# Or explicit per-file
mkdir -p ~/.claude/skills/hty/references
curl -fsSL -o ~/.claude/skills/hty/SKILL.md                    https://hty.sh/skills/hty/SKILL.md
curl -fsSL -o ~/.claude/skills/hty/references/REFERENCE.md     https://hty.sh/skills/hty/references/REFERENCE.md
curl -fsSL -o ~/.claude/skills/hty/references/RECIPES.md       https://hty.sh/skills/hty/references/RECIPES.md
```

Also make sure the `hty` CLI itself is installed — see [Install hty](#install-hty) below.

## When to use

Use `hty` when any of these are true:

| Signal | Example |
|---|---|
| The command prompts for input | `gh auth login`, `npm init`, `create-next-app` |
| The command uses full-screen UI | `vim`, `nano`, `emacs`, `htop`, `btop`, `k9s` |
| The command steps through a wizard | `git add -p`, `git rebase -i`, `ssh-keygen` |
| A REPL / interactive shell | `psql`, `mysql`, `ipython`, `node`, `redis-cli` |
| Bash returns an error like "not a tty" | `ssh -t` alternatives, `sudo`, `gpg --edit-key` |
| You need to react to output before sending more input | Any multi-step interactive flow |

## When NOT to use

Skip `hty` for:

- Plain non-interactive commands. `ls`, `cat file.txt`, `npm test`, `git status` — just use Bash.
- One-shot commands that read from stdin but don't need PTY semantics. `cat < file.txt` works fine in Bash.
- Output-only commands where stdout capture is enough. `hty` adds a session lifecycle; if you don't need state between calls, don't pay the cost.

If in doubt: try Bash first. Reach for `hty` only when Bash fails or the interaction is inherently multi-step.

## Install hty

Check if the `hty` CLI is already installed, and install it if not:

```sh
command -v hty || curl -fsSL https://raw.githubusercontent.com/LatentEvals/hty/main/scripts/install.sh | sh
```

Installs to `~/.local/bin` (make sure it's on `PATH`). Also available via `brew install LatentEvals/tap/hty`.

## Core loop — the mental model

There are two ways to drive a session. Pick based on whether you (the agent) have a background-process mechanism that streams stdout live.

### Pattern A — polling loop (works in any agent)

Use when you don't have a way to stream a long-running process's output. The classic "start, sample, send, sample, send" pattern:

```
1.  hty run --name <task> --snapshot --wait-until-text "..."   # spawn + wait for readiness + get screen
2.  hty send <task> --text "..." --snapshot --wait-until-idle  # send input + wait for quiet + get screen
3.  …repeat…
4.  hty send <task> --text "q\n" --snapshot --wait-until-exit  # terminate + read final screen
```

Every `run` and `send` call can fuse input, wait condition, and snapshot into **one round-trip**. This is what keeps the loop fast.

### Pattern B — attach + remove (agents with background-process support)

Use when your harness streams stdout from backgrounded shells (e.g. Claude Code's `run_in_background`). Launch once, read output as it streams:

```sh
hty run --attach --remove -- <program>   # run in background; stdout streams live; session auto-deletes on exit
```

Then use `hty send <name> --text "..."` from a second (foreground) call to feed input. When the child exits or you detach, `--remove` cleans up the session record. This eliminates the leak problem — no stray entries in `hty list` — and avoids polling entirely.

**Rule of thumb:** Pattern B when you can background processes; Pattern A when you can't.

## Essential commands

| Command | Purpose | Key flag |
|---|---|---|
| `hty run -- program` | Spawn a session | `--name` for addressable names; `--remove` to auto-delete on exit; `--attach` to foreground |
| `hty send <s> --text "..."` | Type into a session | `--snapshot --wait-until-*` to fuse input+wait+read |
| `hty snapshot <s>` | Read current screen | `--ansi` for styled output |
| `hty wait <s> --text "..."` | Block until condition | `--timeout 5000` (ms); also `--idle`, `--regex`, `--exit` |
| `hty list` | Show running sessions | — |
| `hty watch <s>` | Stream screen in real time | Read-only; a human can watch what the agent sees |
| `hty kill <s>` | Terminate the process | Record stays for replay until `hty delete` |
| `hty delete <s>` | Remove session record + log | — |
| `hty keys` | List symbolic key names for `--key` | — |

Run `hty help <command>` for full flag details, or see [references/REFERENCE.md](references/REFERENCE.md) bundled with this skill.

## Input: text, keys, mouse

### Text

```sh
hty send my-session --text "hello\n"     # \n, \t, \r, \\ are escaped
```

### Named keys (preferred over raw escape sequences)

```sh
hty send my-session --key enter
hty send my-session --key c-c            # Ctrl-C
hty send my-session --key c-d            # Ctrl-D (EOF)
hty send my-session --key tab
hty send my-session --key up
hty send my-session --key esc
```

Run `hty keys` for the full list. Prefer `--key` over typing raw bytes — it handles modifier combinations and terminal quirks.

### Mouse

```sh
hty send my-session --click 10 5          # row 10, col 5 (1-indexed)
hty send my-session --scroll-up
```

Only works when the target program has enabled mouse mode (`vim`, `btop`, `htop`, etc.).

## Recipes

### Stage hunks with `git add -p`

```sh
hty run --name review --snapshot --wait-until-text "Stage this hunk" \
  --timeout 5000 -- git add -p
hty send review --text "y\n" --snapshot --wait-until-idle 200
hty send review --text "n\n" --snapshot --wait-until-idle 200
hty send review --text "q\n" --snapshot --wait-until-exit --timeout 2000
```

### Scaffold a Next.js app (wizard with defaults)

```sh
hty run --name scaffold --remove --snapshot --wait-until-text "project name" \
  --timeout 10000 -- npx create-next-app@latest
hty send scaffold --text "my-app\n" --snapshot --wait-until-text "TypeScript"
hty send scaffold --text "\n" --snapshot --wait-until-text "ESLint"
# …and so on through the wizard
hty send scaffold --snapshot --wait-until-exit --timeout 60000
```

`--remove` cleans up the session after the wizard exits so `hty list` stays tidy.

### Authenticate with the GitHub CLI

```sh
hty run --name gh-auth --snapshot --wait-until-text "one-time code" \
  --timeout 10000 -- gh auth login
# Scrape the code out of the snapshot, open the URL, then:
hty send gh-auth --key enter --snapshot --wait-until-text "Logged in" \
  --timeout 120000
hty kill gh-auth && hty delete gh-auth
```

### Query Postgres via `psql`

```sh
hty run --name db --snapshot --wait-until-text "=>" -- psql mydb
hty send db --text "SELECT count(*) FROM users;\n" \
  --snapshot --wait-until-text "=>"
hty send db --text "\\q\n" --snapshot --wait-until-exit
```

### Foreground one-shot (Pattern B)

For harnesses that stream background-process stdout:

```sh
hty run --attach --remove -- ./migrate.sh    # run, stream, auto-clean
```

## Debugging

| Symptom | Check |
|---|---|
| Send doesn't seem to land | Am I using `\n` (newline) not `\r` (carriage return)? Most TUIs want `\n`. |
| "session not found" | `hty list` — did the session exit or get reaped by `--remove`? |
| Wait timed out (exit code 3) | The text/regex never appeared within `--timeout`. Snapshot the screen to see what the program actually printed. |
| Output looks corrupted | Terminal size may be wrong. Pass `--rows` and `--cols` to `hty run` to match the program's expectations. |
| Session list has zombie entries | Use `hty kill && hty delete`, or spawn with `--remove` next time to auto-clean. |

For live observation from a second terminal (or a human watching what the agent sees):

```sh
hty watch my-session
```

Read-only, no interference with the agent's input.

## Common gotchas

1. **`\n` vs `\r`.** Use `\n` (newline) in `--text` for most programs. `\r` (carriage return) is rarely what you want. When in doubt, `--key enter`.
2. **Session name collisions.** `--name` must be unique across running sessions. Pick task-specific names (`review`, `gh-auth`, `db`) — not generic ones that might already exist. `hty list` before spawning if you're unsure.
3. **Sessions persist by default.** After the child exits, the record stays for `hty replay` / `hty logs` until `hty delete`. Use `--remove` if you don't want this.
4. **Timeouts are in milliseconds.** `--timeout 5000` = 5 seconds. `--wait-until-idle 200` = 200ms of quiet.
5. **Pattern A vs B choice matters.** Don't use `--attach` without a background-process mechanism — it blocks the foreground call with no way to send input. Use Pattern A (polling) instead.
6. **`--attach` and `--snapshot`/`--wait-until-*` are mutually exclusive.** Attach is a streaming mode; the fused wait flags are for the polling pattern.
7. **Session identifiers.** Any unambiguous prefix of a UUID resolves. `--name` is usually clearer in agent code than UUID prefixes.

## Exit codes

| Code | Meaning |
|:---:|---|
| 0 | Success |
| 1 | Generic error |
| 2 | Session not found |
| 3 | `wait` timed out |
| 4 | Ambiguous session prefix (multiple matches) |
| 5 | Session name already exists |

Non-zero exit codes are stable — key off them in agent scripts rather than parsing error messages.

## Resources

- **Full command reference:** [references/REFERENCE.md](references/REFERENCE.md) (bundled)
- **Workflow recipes:** [references/RECIPES.md](references/RECIPES.md) (bundled)
- **Live docs:** [hty.sh](https://hty.sh) — every page also available as `.md` for agent ingestion
- **Compact LLM reference:** [hty.sh/llms.txt](https://hty.sh/llms.txt) — start here when a flag seems wrong
- **Source & issues:** [github.com/LatentEvals/hty](https://github.com/LatentEvals/hty)
