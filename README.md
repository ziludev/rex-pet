# Rex Pet

An unofficial, ambient desktop pet for [Rex](https://superlogical.com), the terminal workspace
by Superlogical. A transparent cat sits on your desktop, mirrors what your agent panes are doing,
and — when one of them is blocked waiting for you — lets you answer without switching panes.

![Every state, drawn by the app itself](docs/demo.gif)

Zero dependencies: plain AppKit, no Xcode project, no image assets, no third-party packages.
`./build.sh` and you have an `.app`.

## Why

Rex already has plenty of ways to tell you that an agent needs attention: menu bar apps, an
attention board, even an ESP32 desk display. All of them make you *look*. Rex Pet puts the state
where your eyes already drift, and closes the loop: click the cat, hit **允许 (y)**, and the
answer goes straight into the blocked pane.

## Requirements

| | |
| --- | --- |
| OS | macOS 14 or newer |
| Rex | installed, so that `rex` is on `PATH` (or point `REX_PET_REX_BIN` at it) |
| Toolchain | Xcode Command Line Tools (`swiftc`) — no full Xcode needed |

A GUI-launched app inherits launchd's minimal `PATH`, so the pet looks for `rex` in the usual install
locations (`/opt/homebrew/bin`, `/usr/local/bin`, `~/.local/bin`, …) and inside the Rex app itself
before giving up. If it still cannot find one, the cat says so and offers **"选择 rex 可执行文件…"**
in its menu; the chosen path is remembered. It also keeps retrying every 30 s, so installing Rex
afterwards just starts working.

## Build and run

```sh
./build.sh                              # -> build/RexPet.app (host arch)
ARCHS="arm64 x86_64" ./build.sh          # universal binary
open build/RexPet.app
REX_PET_DEBUG=1 ./build/RexPet.app/Contents/MacOS/RexPet   # logs clicks and sends to stderr
```

The bundle is ad-hoc signed (`codesign --force --sign -`), which is enough to run locally and keeps
the TCC identity stable across rebuilds. There is no notarized binary yet.

## Using it

- **The cat is the only clickable part.** Everywhere else in its window, clicks fall through to
  whatever is underneath: the window polls the mouse position at 20 Hz and flips
  `ignoresMouseEvents`, which needs no accessibility permission.
- **Left click** — idle/working: a bubble naming the state and the pane. Blocked: the reply panel.
- **Drag** — moves the window; the position is remembered in `UserDefaults`.
- **Menu bar cat** — set a state, demo mode, toggle click-through, reset position, reply to the
  blocked pane, pick the `rex` binary, launch at login, quit. The same menu is on a right click.
  The menu bar glyph is a template image, so it follows the light/dark menu bar.

The reply panel is a small HUD that becomes the key window just long enough to type, then hands
focus back to whatever you were using:

| Button | Sends |
| --- | --- |
| 允许 (y) | `y\r` |
| 选 1 | `1\r` |
| 拒绝 (n) | `n\r` |
| Ctrl+C | `\x03` |
| free text + Enter | the text and `\r` |

Delivery is the same call [rex-beacon](https://github.com/ziludev/rex-beacon) uses:

```sh
rex block call -b <block> write '{"data":"y\r"}'
```

## States

![states](docs/states.png)

| State | Look | Meaning |
| --- | --- | --- |
| `idle` | no halo | nothing is running |
| `working` | amber halo, `~` badge | at least one pane is busy |
| `blocked` | red halo, `!` badge, no blinking | a pane wants permission or an answer |
| `done` | green halo, `✓` badge | a command finished, cleared or not |
| `error` | magenta halo, `×` badge | a command exited non-zero |

The body is never tinted: the halo and the badge carry the state, so the cat stays one coherent
character. On light wallpapers the silhouette survives thanks to a soft drop shadow and a 1.2 pt
translucent outline.

## How it works

```
rex events --all --json
        │
   RexWatcher          parse block events from com.superlogical.terminal
        │
 PetStateMachine       merge panes: blocked > error > done > working, with TTLs
        │
    PetView ──> CatSprite     vector cat, 30 fps, breathing/blinking per state
        │
   ReplyPanel ──> rex block call write ──> the blocked pane
```

The event stream, not a file, is the source of truth:

| Event | Value | State |
| --- | --- | --- |
| `progress_report` | `indeterminate`, `running`, anything else | `working` |
| `progress_report` | `success` / `done` / `complete` | `done` |
| `progress_report` | `error` / `fail…` | `error` |
| `progress_report` | contains `block` / `need` / `wait` / `prompt` | `blocked` |
| `program_status_changed` | `records[].state` (the OSC 7501 vocabulary) | as reported |
| `child_exited` | `exit_code` 0 / non-zero | `done` / `error` |
| `bell` | — | `blocked` |

The last event must not win outright: shells emit `idle` right after `child_exited`, which would
erase the check mark before anyone sees it, and a busy pane in another window would fight a fresh
`done`. So `PetStateMachine` keeps one entry per block, shows the highest priority among them, holds
`done`/`error` for 8 s, and drops `working` after 15 s without a refresh.

Honest consequence: any pane reporting `working` keeps the cat amber. While an agent runs in one of
your panes, the cat is amber — that is a report, not a bug.

## Files it reads and writes

| Path | Purpose |
| --- | --- |
| `~/.cache/rex-pet/state` | manual override: `idle` / `working` / `blocked` / `done` / `error`, wins over the event stream for 60 s after it is written |
| `~/.cache/rex-pet/context.json` | same, plus `{"block":"block:…","title":"…"}` so a demo click has somewhere to reply |
| `~/Library/Application Support/rex-pet/Assets/<state>/*.png` | optional image sequence, 12 fps; if present it replaces the vector cat |

`REX_PET_REX_BIN` overrides the `rex` lookup, `REX_PET_DEBUG=1` logs to stderr.
`tools/render-states.swift`, `tools/render-demo.swift` and `tools/render-icon.swift` regenerate
`docs/states.png`, `docs/demo.gif` and the app icon from the real drawing code, so the README can
never drift from the app. `tools/style-cat.swift` is the sketch pad where the look was designed.

## Known gaps

1. Multiple displays: the default position is pinned to the first screen (`NSScreen.screens.first`);
   after moving the cat, it stays where you left it. Stage Manager and full-screen Spaces untested.
2. `blocked` has no timeout — a pane that reports it once and never retracts keeps the red halo.
3. `write` only reaches **placed** blocks. A block created by `rex new` before any client renders it
   answers `block target "…" not found` (exit 3); a blocked pane is always placed, so this does not
   bite in practice.
4. No preferences window and no per-pane list — one cat, one aggregate state.
5. **登录时启动** uses `SMAppService`, which wants a real bundle: it works once `RexPet.app` lives in
   `/Applications`, and reports a failure bubble when run from `build/`.

## Related

- [rex-orbit](https://github.com/benhid/rex-orbit) — agent panes as pixel bots orbiting a dinosaur, inside a pane
- [rex-radar](https://github.com/hecspc/rex-radar) — menu bar, widget, iPhone and Watch status
- [rexboard](https://github.com/vanducng/rexboard) — attention board: which panes wait, and for how long
- [cheap-rex-display](https://github.com/yethranayeh/cheap-rex-display) — the same idea on an ESP32 desk display
- [awesome-rex](https://github.com/alpha-og/awesome-rex) — the list all of the above live in

## License

MIT, see [LICENSE](LICENSE).

Rex and Rexie are trademarks of Superlogical. This project is unofficial and not affiliated with or
endorsed by Superlogical; the cat is original artwork drawn in code, not Rex's mascot.
