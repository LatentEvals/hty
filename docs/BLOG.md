# Design notes / draft posts

Long-form notes on the design of `hty`, written with the intent of eventually polishing into blog posts. For now they live here so the thinking doesn't get lost between commits. Rough drafts — expect some loose edges.

---

## Why Zig + Ghostty

*Draft — first written during the Rust → Zig rewrite.*

This project started as a Rust prototype. The architecture was fine — [`tokio`](https://tokio.rs) + [`portable-pty`](https://crates.io/crates/portable-pty) + a channel-based event model + a snapshot API very similar to the current one. It fell over on a single concrete thing: the [`vt100`](https://crates.io/crates/vt100) crate it used to parse terminal output is a deliberately minimal VT parser. It couldn't faithfully reproduce `btop`. Rapid cursor moves, dynamic palettes, SGR edge cases, alt-screen transitions — the corners of real VT behavior that modern TUIs lean on hard.

The lesson wasn't "we need a better parser," it was **"don't write your own VT engine — use a production one."** Ghostty's terminal core (`ghostty-vt`) is exactly that: it's the state machine that powers a real, actively maintained terminal emulator, and it's exposed as a plain Zig module we can import as a dependency.

So the choice is:

- **Ghostty's VT engine** — production-grade fidelity, maintained by people whose day job is making `vim` and `btop` look right. We re-export it from [`src/lib.zig`](src/lib.zig) as `hty.ghostty_vt`.
- **Zig, not Rust** — because Ghostty's core is Zig-native, so there's no FFI boundary. And because `forkpty` + a reader thread + a mutex is genuinely simpler than a `tokio` runtime for this shape of problem. No async coloring, no runtime to hide bugs behind.

The architectural decisions from the Rust prototype (snapshot-based API, event enum, JSONL wire format) survived the rewrite essentially unchanged. The parser is what needed to die.
