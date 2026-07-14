# PRD: Single-threaded event-loop server

Status: draft — execution gated on a plan derived from this PRD
Owner: hty server
Supersedes: the *mechanisms* of hardening Unit 4 (non-blocking attach
buffers) and Unit 6 (session refcounts); their tests are kept as
regressions.

## 1. Problem statement

The hty server is a small local daemon (one user, a handful of sessions,
Unix-socket RPC) built with server-farm concurrency: every accepted
connection gets a worker thread, every session gets a PTY reader thread,
every attach client and pending watcher gets its own socket reader thread.
Correctness then rests on seven mutexes, a dozen atomics, a self-pipe, and
a timing-based grace window:

- Threads: the accept loop (`runServerWithOpts`, `src/server.zig:141`);
  one `Worker` per in-flight RPC (`WorkerPool.spawn`, `src/server.zig:76`);
  one PTY reader per session (`readerLoop`, `src/lib.zig:312`); one socket
  reader per attach client (`attachReaderLoop`, `src/server_attach.zig:260`);
  one reader per parked watcher (`pendingWatcherReaderLoop`,
  `src/registry.zig:94`) plus its wake self-pipe.
- Locks: `SessionRegistry.mutex` (`src/registry.zig:139`),
  `WorkerPool.mutex`, `Session.log_mutex`, `Session.attach_mutex`,
  `InteractiveTerminal.mutex`, `InteractiveTerminal.write_mutex`,
  `AttachClient.write_mutex` — with a documented lock order
  (registry → session-local) that every new feature must re-derive.
- Timing instead of ownership: wait/snapshot handlers hold a bare
  `*Session` from `resolveOrSole` for up to 30s with no lock, while
  `handleDelete` or the auto-remove sweep can free it; the only defence is
  `auto_remove_grace_ms = 100` (`src/registry.zig:125`) — a real
  use-after-free class. Unit 6 patches this with a refcount; the class
  itself exists only because independent threads share the pointer.
- Derived hazards: `drainAll` broadcasting to attach sockets via blocking
  `writeAll` under `registry.mutex` (`tryWriteFrame`,
  `src/session.zig:372`) lets one stalled observer wedge every RPC
  (Unit 4's bug); waits burn a thread on `std.Thread.sleep(25ms)` polls
  (`src/ops.zig:431` et al.); event delivery needs a mutex-guarded queue
  drained on a 25ms tick (`src/server.zig:195`).

This PRD proposes collapsing all of it into one thread running `poll()`
over the listen socket, every session's PTY master fd, and every client
socket. With a single thread there is no lock order, no atomic publication
protocol, no grace window, and no UAF class: a session freed during
dispatch cannot be concurrently touched, because there is no concurrently.

## 2. Goals / non-goals

Goals

- One server thread. Zero mutexes, zero atomics, zero auxiliary threads in
  `src/server.zig`, `src/registry.zig`, `src/session.zig`,
  `src/server_attach.zig`, and the server-side use of `src/lib.zig`.
- Wire-compatible: every RPC request/response byte shape, attach/watch
  frame sequence, and session log format unchanged. Clients (`hty` CLI)
  need no changes.
- Event-driven waits: `wait_for_*` becomes deadline bookkeeping on the
  loop, not a sleeping worker; PTY output wakes waiters on the same
  iteration it arrives.
- Latency no worse than today (25ms tick granularity is the current
  floor; the loop should beat it since PTY readability wakes `poll`
  immediately).
- Unit 4 and Unit 6 acceptance tests pass unchanged as regressions.

Non-goals

- No protocol changes, new ops, or new CLI surface.
- No performance work beyond what the architecture gives for free
  (snapshot cost is Unit 7's territory and stays valid here).
- No Windows/IOCP story; targets remain macOS + Linux.
- Not a general async runtime: no io_uring, no libxev dependency, no
  attempt to survive thousands of fds. Design center is < 100 fds.

## 3. Current architecture (what gets deleted)

- `src/server.zig` — accept loop polls only the listen fd with a 25ms
  timeout, calls `registry.drainAll()` every tick, sweeps finished
  workers, and spawns a thread per accepted connection which runs
  `handleConnection` → `dispatchRequest`.
- `src/registry.zig` — `drainAll` holds `registry.mutex` across the full
  session iteration: polls each terminal's event queue, writes the log,
  broadcasts to attach clients, runs the auto-remove sweep with its 100ms
  grace, and reaps pending watchers (duplicated inline at
  `src/registry.zig:657-691` to avoid self-deadlock).
- `src/session.zig` — lifecycle fields are atomics precisely so wait
  handlers can poll them without the registry lock
  (`status_atomic`, `last_screen_change_at_ms_atomic`, etc.,
  `src/session.zig:198`).
- `src/lib.zig` — `InteractiveTerminal` owns a reader thread doing
  blocking `read(master_fd)` → VT feed → mutex-guarded event append;
  consumers drain via `pollEvent` (`orderedRemove(0)`,
  `src/lib.zig:287`); the thread ends with a blocking `waitpid`.
- `src/server_attach.zig` — attach/watch connections are handed off to a
  per-client reader thread that blocks on `stream.read` and dispatches
  input/resize/detach frames.

## 4. Proposed architecture

### 4.1 The loop

One `poll()` per iteration over a rebuilt pollfd set:

1. listen socket (`POLLIN` → accept, register connection),
2. each connection socket (`POLLIN` always; `POLLOUT` only while its
   outbound buffer is non-empty),
3. each live session's PTY master fd (`POLLIN`; suppressed while the
   session's pending-input buffer is non-empty and waiting on `POLLOUT`).

Timeout = `min(nearest wait deadline, nearest housekeeping deadline,
infinite)`. The unconditional 25ms tick disappears; housekeeping
(auto-shutdown empty timer, idle-wait re-checks) registers explicit
deadlines instead. All fds are `O_NONBLOCK`.

After `poll` returns, the loop services in a fixed order: PTY reads →
waiter wake-ups → connection reads → connection writes/flushes → timer
expiries → deferred frees. Fixed ordering makes "output arrived, waiter
resolved, response written" happen in one iteration.

### 4.2 Per-connection state machine

Each accepted connection becomes a `Conn` struct owned by the loop:

- `reading_request`: accumulate bytes until `\n` (keeping Unit 2's size
  cap). On a full line: dispatch.
- `responding`: RPC handlers become synchronous calls that either
  complete immediately (snapshot, send, list, kill…) and queue the
  response into the conn's outbound buffer, or park the conn as a waiter
  (§4.3). `ConnectionResult.attached` disappears — attach is just another
  state.
- `attached` / `watching`: conn is subscribed to a session; inbound bytes
  are parsed as JSONL frames (the `dispatchAttachFrame` logic survives
  nearly verbatim, minus the thread); outbound carries broadcast frames.
- `pending_watch`: replaces `PendingWatcher` + its reader thread + self-
  pipe entirely — it is just a conn in a "waiting for session named X"
  state. Promotion on `create()` is a state flip. `src/registry.zig:38-118`
  and the duplicated reap logic are deleted outright.
- `draining`: response queued, flush then close.

Every conn has one bounded outbound buffer (1 MiB, Unit 4's number) with
overflow policy = mark closed and reap. This generalizes Unit 4: instead
of special-casing attach clients, *no* socket write in the server ever
blocks. `AttachClient.write_mutex` and `tryWriteFrame`'s blocking
`writeAll` go away.

### 4.3 Wait bookkeeping

A `Waiter` table replaces sleeping workers: `{conn, session id, condition
(text/regex | idle(idle_ms) | exit | duration), deadline, needs_snapshot}`
— exactly the parameterization Unit 5 extracts. Evaluation points:

- PTY output fed for session S → re-check S's text/regex waiters and
  reset idle timers (this also subsumes Unit 7: condition checks can run
  against a cheap plain-text snapshot, full snapshot only for the final
  response).
- Child exit observed for S → resolve exit waiters.
- Timer wheel (a sorted deadline list is enough at this scale) → resolve
  timeouts, idle expiries, and `duration` sleeps (the current
  `std.Thread.sleep(duration_ms)` in `handleWaitAndSnapshot`,
  `src/ops.zig:618`, becomes a timer entry).

Session deletion while waiters exist resolves them immediately with the
structured "session not found"-class result Unit 6 specifies. Since the
loop owns both the waiter and the session, this is an ordinary function
call, not a race.

### 4.4 PTY dispatch and session lifetime

`InteractiveTerminal` loses its reader thread, event queue, `mutex`, and
`write_mutex` for server use: the loop reads `master_fd` directly on
`POLLIN` and synchronously feeds the VT stream, appends to the session
log, broadcasts to subscribed conns, updates `last_screen_change`, and
wakes waiters. The `OutputEvent` queue and `pollEvent` survive only for
the library/embedding use-case (the in-process tests in `src/lib.zig`);
the server stops consuming them. `pushEventUnlocked`'s drop-on-OOM hazard
(Unit 8a) becomes moot server-side.

Exit detection stays EOF-driven as today (`src/lib.zig:342`): EOF/EIO on
the master fd → `waitpid(WNOHANG)` loop → status transition, exit
broadcast, log close. No SIGCHLD handler needed.

Writes to the PTY master go through a small per-session pending-input
buffer flushed on `POLLOUT`, so a child that stops reading its tty cannot
stall the loop (today it stalls one worker thread inside
`writeAll`, `src/lib.zig:358`).

Session lifetime: `resolveOrSole` returns a pointer that is valid for the
duration of the current dispatch, guaranteed structurally — nothing else
runs. Unit 6's refcount reduces to a single rule: never free a session in
the middle of dispatching on it; deletion marks it doomed and the loop
frees doomed sessions at the end of the iteration ("deferred frees" phase).
`auto_remove_grace_ms` is deleted; auto-remove happens on the iteration
that observes exit.

## 5. The four concerns

### 5.1 Blocking filesystem work on the single thread

Two FS surfaces run on the loop:

- **Session log appends** (`writeLogEvent`, `src/log.zig:28`): position —
  **keep them synchronous on the loop thread**. They are small appends
  (one JSONL line per event, output lines dominated by 8 KiB read chunks
  hex-encoded) to a local file, already best-effort with errors swallowed.
  A buffered `write(2)` to local disk is microseconds; the current design
  already performs these same writes inside `drainAll` while holding
  `registry.mutex` with every RPC blocked behind it — the event loop is
  strictly no worse. Trade-off: a pathological filesystem (network home
  dir, disk stall) freezes the whole server instead of one thread. Accepted
  for a local dev tool; the escape hatch, if profiling ever demands it, is
  one dedicated log-writer thread fed by a bounded queue (drop-on-full,
  consistent with logging being best-effort) — an isolated producer/
  consumer pair, not a return to shared-state locking. `log_mutex` is
  deleted either way.
- **`nameInUse` scans** (`src/log.zig:249`): opens and reads the first
  line of *every* `.jsonl` in the log dir, currently under
  `registry.mutex` (`src/registry.zig:199`). Position — **make it O(1)
  instead of moving it off-thread**: the by-name symlink
  (`by-name/<name>.jsonl`) already exists and is checked first; make the
  full-directory fallback scan a startup-only reconciliation (or drop it —
  the symlink is created at spawn and removed at delete), so the hot path
  is a single `faccessat`. Spawn is cold-path, but an unbounded directory
  scan on the loop thread is the one FS cost here that genuinely scales
  with user data, so we remove the scaling, not the thread.

### 5.2 macOS: `poll` vs `kqueue`

Position — **`poll()`**, one code path for macOS and Linux. The deciding
fact: on macOS, `kqueue` cannot reliably monitor PTY master fds
(`EVFILT_READ` on the master side of a pty does not fire; this is the
long-documented Darwin limitation that forces libuv to run a select-thread
fallback for TTYs). Since PTY masters are the highest-value fds in this
loop, kqueue on macOS would need a poll/select sidecar anyway — worst of
both worlds. `poll` handles PTYs, Unix sockets, and pipes uniformly on
both targets.

Trade-offs accepted: `poll` is O(n fds) per wakeup and re-registers the
set every iteration. At the design center (≤ ~16 sessions + ≤ ~32
clients ≈ 50 fds) rebuilding a 50-entry pollfd array per wakeup is
noise. The loop isolates readiness behind a small internal interface
(`registerFd/armWrite/waitReady`) so an epoll/kqueue backend could be
added later without touching dispatch, but no such backend ships in this
epic.

### 5.3 Attach input fan-in

Today, input frames from N attach clients converge on the PTY via N
reader threads calling `terminal.send` under `write_mutex`, each doing a
blocking `writeAll` (`src/server_attach.zig:301-315`, `src/lib.zig:358`).
Position — attach client sockets are ordinary loop fds; their input
frames are parsed by the conn state machine and appended to the owning
session's **single pending-input buffer**, which the loop flushes to the
master fd on writability. Consequences:

- Natural serialization: frames from concurrent clients and RPC
  `send_text`/`send_key` interleave at frame granularity (whole-frame
  appends), never mid-byte — strictly better than today's mutex, which
  serializes at `writeAll` granularity but with arbitrary thread ordering.
- Input logging (`logInputEvent` with `origin:"attach"` and `client_id`)
  happens at append time, preserving the log's ordering guarantee that
  connect events precede that client's input (`src/server_attach.zig:157`).
- Backpressure: the pending-input buffer is bounded (64 KiB per session).
  A child that stops reading its tty causes further input to be dropped
  with a `debug`-level note (interactive input is human-scale; a full
  64 KiB of unconsumed input means the session is wedged anyway). Read-
  only (`watch`) clients keep the existing silently-drop semantics.
- Resize frames bypass the buffer (`ioctl(TIOCSWINSZ)` doesn't block).

### 5.4 Migration and test strategy

Position — **staged replacement in three landable phases**, full suite
green after each; no long-lived rewrite branch.

1. **Conns onto the loop.** Delete `WorkerPool`/worker threads; RPC
   connections become loop-owned state machines; waits become waiter-table
   entries (building directly on Unit 5's unified wait core). PTY reader
   threads and `drainAll` remain temporarily — the loop adds the terminals'
   event-queue drain to its housekeeping. Registry mutex stays but is now
   only accept-loop vs PTY-reader threads.
2. **Attach/watch/pending onto the loop.** Delete `attachReaderLoop`,
   `PendingWatcher` + self-pipe, `attach_mutex`, `write_mutex` on
   `AttachClient`; conns gain `attached/watching/pending_watch` states and
   outbound buffers (Unit 4's mechanism is absorbed here).
3. **PTY fds onto the loop.** Delete per-session reader threads,
   `InteractiveTerminal.mutex` usage server-side, the event-queue hop,
   `registry.mutex`, all `Session` atomics (become plain fields),
   `auto_remove_grace_ms`, and Unit 6's refcount (reduced to the
   doomed-list deferred free).

Regression contract:

- Unit 4's stalled-reader test (attach client never reads; concurrent
  `list` completes on budget) is kept verbatim — it now exercises the
  conn outbound buffer + overflow-reap path.
- Unit 6's delete-during-wait test (wait in flight, concurrent `delete`;
  no UAF, structured result) is kept verbatim — the "concurrent" client
  requests now interleave through the loop, and the test asserts the same
  observable behavior with the race made impossible rather than survived.
- The full `src/tests.zig` suite (spawn/wait/snapshot/attach/watch/logs/
  replay, 179+ tests) is the primary migration harness, since it drives
  the server through the real socket protocol and asserts wire shapes.
- Add loop-specific tests: waiter resolves on the same iteration output
  arrives (no 25ms quantization); pending-input overflow drops without
  stalling; `poll` timeout math (nearest-deadline selection) unit-tested
  pure.

## 6. Risks

- **Any long synchronous call stalls everything.** Biggest offender is
  `snapshot()` (full scrollback `plainString`, ANSI render, cells grid,
  `Normalize.init` — see Unit 7). Unit 7's cheap-snapshot split is
  effectively a prerequisite for good loop hygiene and should land first.
  Spawn (`forkpty` + exec, `src/lib.zig:144`) is also synchronous but
  cold-path and fast.
- **Regression surface is the whole server.** Mitigated by the three-phase
  landing and the socket-level test suite; each phase deletes one thread
  family and its locks, so a bisect always lands on a small delta.
- **Subtle ordering changes.** Today attach broadcasts happen on a 25ms
  drain cadence; the loop broadcasts per-read. Frame *content* is
  identical but chunking differs; any test accidentally coupled to
  chunking must be fixed to assert content.
- **fd exhaustion behavior changes**: with fds central, accept-time
  `EMFILE` needs a deliberate response (reject with structured error,
  keep serving) rather than thread-spawn failure semantics.

## 7. Open questions

1. Does `zig build test`'s in-process server harness assume it can call
   `processRequestLine` from test threads while the loop runs? If so,
   tests may need to switch to socket-only interaction (preferred) or the
   loop needs a test-only injection channel.
2. Should the library surface of `InteractiveTerminal` (event queue +
   reader thread) be kept long-term for embedders, or should the library
   also expose the fd for caller-driven loops and deprecate the thread?
   Out of scope to change here, but the split should be named in the plan.
3. Is dropping the `nameInUse` full-directory fallback acceptable, i.e.
   is the by-name symlink guaranteed present for every named session's
   log across upgrade from older on-disk state? If not, do the one-time
   scan at server startup.
4. Exact bounds: 1 MiB per-conn outbound (from Unit 4) and 64 KiB
   per-session pending-input are proposed defaults; confirm during
   planning with a hex-encoding expansion factor (2x) in mind.

## 8. Success criteria

- `grep -rn "std.Thread" src/server.zig src/registry.zig src/session.zig
  src/server_attach.zig src/attach.zig src/ops.zig` returns nothing
  (no threads, no mutexes, no sleeps in server code).
- No atomics in `src/session.zig`/`src/registry.zig`; `auto_remove_grace_ms`
  and `PendingWatcher` no longer exist.
- Unit 4 and Unit 6 acceptance tests pass unmodified.
- Full test suite green on macOS and Linux; wire shapes byte-identical
  for all cases asserted in `src/tests.zig`.
- A `wait_for_text` resolves in the same loop iteration the matching
  output arrives (measurable: median wait-resolve latency well under the
  old 25ms tick in a timing test).
- A stalled attach reader, a stalled PTY child, and a wedged log
  filesystem each degrade only their own session/connection — `list`
  keeps answering (first two structurally; third accepted as residual
  risk per §5.1).
