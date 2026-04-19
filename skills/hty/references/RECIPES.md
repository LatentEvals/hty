# hty recipes

Copy-paste workflows for common interactive programs. Each recipe shows the Pattern A (polling) form, which works in any agent. If your harness can background processes, Pattern B (`hty run --attach --remove -- ...`) is often shorter — see the SKILL.md for when to prefer it.

## Git

### `git add -p` — stage hunks selectively

```sh
hty run --name review --snapshot --wait-until-text "Stage this hunk" \
  --timeout 5000 -- git add -p
hty send review --text "y\n" --snapshot --wait-until-idle 200   # stage
hty send review --text "n\n" --snapshot --wait-until-idle 200   # skip
hty send review --text "s\n" --snapshot --wait-until-idle 200   # split
hty send review --text "q\n" --snapshot --wait-until-exit --timeout 2000
```

Keys: `y` (stage), `n` (skip), `s` (split), `e` (edit), `q` (quit), `?` (help).

### `git rebase -i` — interactive rebase

vim opens on the rebase todo. Use the vim recipe below, then save-and-quit with `:wq`.

```sh
hty run --name rebase --snapshot --wait-until-idle 500 \
  -- git rebase -i HEAD~5
# Edit the todo list in vim, e.g. swap pick → reword on line 2:
hty send rebase --text "jciw" --key esc    # j (down), ciw (change word)
hty send rebase --text "reword" --key esc
hty send rebase --text ":wq\n" --snapshot --wait-until-exit --timeout 30000
```

## GitHub CLI

### `gh auth login` — device-code flow

```sh
hty run --name gh-auth --snapshot --wait-until-text "one-time code" \
  --timeout 10000 -- gh auth login
# Parse the 8-char code and URL out of the snapshot, open the URL in the
# browser, paste the code. Then continue:
hty send gh-auth --key enter --snapshot --wait-until-text "Logged in" \
  --timeout 120000
hty kill gh-auth && hty delete gh-auth
```

## Package scaffolders

### `create-next-app` — step through the wizard

```sh
hty run --name scaffold --remove --snapshot --wait-until-text "project name" \
  --timeout 10000 -- npx create-next-app@latest
hty send scaffold --text "my-app\n" --snapshot --wait-until-text "TypeScript"
hty send scaffold --text "\n"       --snapshot --wait-until-text "ESLint"
hty send scaffold --text "\n"       --snapshot --wait-until-text "Tailwind"
hty send scaffold --text "\n"       --snapshot --wait-until-text "src/"
hty send scaffold --text "\n"       --snapshot --wait-until-text "App Router"
hty send scaffold --text "\n"       --snapshot --wait-until-text "import alias"
hty send scaffold --text "N\n"      --snapshot --wait-until-exit --timeout 120000
```

`--remove` cleans up the session on exit so `hty list` stays empty.

### `npm init` / `yarn create` / `pnpm create`

Same pattern — wait for each prompt, send the answer, move on.

## REPLs and databases

### `psql` — Postgres prompt

```sh
hty run --name db --snapshot --wait-until-text "=>" -- psql mydb
hty send db --text "SELECT count(*) FROM users;\n" \
  --snapshot --wait-until-text "=>"
hty send db --text "\\dt\n" --snapshot --wait-until-text "=>"   # list tables
hty send db --text "\\q\n" --snapshot --wait-until-exit
```

### `mysql` — MySQL prompt

```sh
hty run --name my --snapshot --wait-until-text "mysql>" -- mysql -u root
hty send my --text "SHOW DATABASES;\n" --snapshot --wait-until-text "mysql>"
hty send my --text "exit\n" --snapshot --wait-until-exit
```

### `redis-cli`

```sh
hty run --name r --snapshot --wait-until-text ">" -- redis-cli
hty send r --text "KEYS *\n" --snapshot --wait-until-text ">"
hty send r --text "QUIT\n" --snapshot --wait-until-exit
```

### Python REPL

```sh
hty run --name py --snapshot --wait-until-text ">>>" -- python3
hty send py --text "import sys; sys.version\n" \
  --snapshot --wait-until-text ">>>"
hty send py --key c-d --snapshot --wait-until-exit   # Ctrl-D = EOF
```

## Editors

### `vim` — basic edit and save

```sh
hty run --name edit --snapshot --wait-until-idle 300 \
  -- vim /tmp/notes.md
hty send edit --text "i"                             # enter insert mode
hty send edit --text "hello from hty\n"
hty send edit --key esc                              # exit insert mode
hty send edit --text ":wq\n" --snapshot --wait-until-exit
```

Pattern B (foreground, if supported):

```sh
hty run --attach --remove -- vim /tmp/notes.md
# User/agent types directly; Ctrl-A d to detach (session persists unless --remove).
```

### `nano` — save with Ctrl-O, exit with Ctrl-X

```sh
hty run --name n --snapshot --wait-until-idle 300 -- nano /tmp/x
hty send n --text "hello\n"
hty send n --key c-o --snapshot --wait-until-text "File Name"   # save
hty send n --key enter
hty send n --key c-x --snapshot --wait-until-exit               # exit
```

## TUIs

### `htop` / `btop` / `top` — snapshot system stats

```sh
hty run --name mon --snapshot --wait-until-idle 500 -- htop
# Wait a moment for stats to populate, grab a snapshot:
hty wait mon --idle 500 --timeout 2000
hty snapshot mon --ansi > htop.txt
hty send mon --text "q"     # htop exits on 'q' with no newline
hty wait mon --exit --timeout 5000
hty delete mon
```

### `k9s` — Kubernetes TUI

```sh
hty run --name k9s --rows 40 --cols 160 --snapshot --wait-until-text "Context" \
  --timeout 10000 -- k9s
hty send k9s --text ":pods\n" --snapshot --wait-until-text "NAME"
hty snapshot k9s --ansi
hty send k9s --text ":q\n" --snapshot --wait-until-exit
```

Note `--rows 40 --cols 160` — k9s needs enough room to render tables cleanly.

## SSH and secrets

### `ssh-keygen` — generate a key with a passphrase

```sh
hty run --name keygen --remove --snapshot --wait-until-text "file in which to save" \
  -- ssh-keygen -t ed25519 -C "agent@example.com"
hty send keygen --text "/tmp/id_ed25519_demo\n" \
  --snapshot --wait-until-text "passphrase"
hty send keygen --text "secret-passphrase\n" \
  --snapshot --wait-until-text "same passphrase"
hty send keygen --text "secret-passphrase\n" \
  --snapshot --wait-until-exit --timeout 10000
```

### `sudo` — enter a password

```sh
hty run --name s --remove --snapshot --wait-until-text "password" \
  --timeout 5000 -- sudo apt update
hty send s --text "$SUDO_PASSWORD\n" --snapshot --wait-until-exit --timeout 60000
```

**Security note:** Session logs capture all input. For real credential handling, consider `--no-logs` (if available) or clean up with `hty delete` immediately after.

## Remote observation

Watch what an agent is doing from your laptop, over SSH:

```sh
# On the remote machine
hty info                      # note the socket path

# On your laptop
ssh -L /tmp/hty.sock:<remote-socket-path> user@remote
HTY_SOCKET=/tmp/hty.sock hty watch <session-name>
```

When `$HTY_SOCKET` is set, the client never auto-spawns a local server — a broken tunnel fails fast instead of silently creating a separate session.

## Pattern B — foreground one-shots

When your harness streams background-process stdout (e.g. Claude Code's `run_in_background`), this is the shortest form:

```sh
hty run --attach --remove -- ./migrate.sh          # run, stream, auto-clean
hty run --attach --remove -- npm test              # ditto
hty run --attach --remove -- bundle exec rspec     # ditto
```

No polling, no session leaks, no follow-up `hty delete`. If you need to send input while the program runs, use `hty send <name> --text "..."` from a separate call — but most one-shots don't.
