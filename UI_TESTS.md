# Driven UI verification

How to *prove* a UI change works, rather than assert it. There is still no UI test target: this is
a repeatable procedure — build, install, drive the real app from the keyboard, capture the panel,
judge the pixels, and instrument the view tree when the pixels and the model disagree.

Run it for any new feature, palette screen, native plugin or Raycast extension, and for any change
to an existing surface's keys, chrome or list rendering. [testing.md](docs/testing.md) still owns
the harnesses and the manual sweep; this file owns the part a human would otherwise do by hand and
skip.

The register at the bottom is the point of the document. **Every UI bug that survived a review goes
in it**, with its symptom, its root cause and the check that would have caught it.

## 1. Prerequisites, once

- Work against the **Debug channel** — `Tinycast Dev.app`, `com.tinycast.app.dev`. Never drive an
  installed release copy: the driver types into whatever holds focus.
- The process running `osascript` (your terminal, or the agent's shell) needs **Accessibility**.
  Without it `System Events` key codes are silently swallowed.
- Know the palette hotkey of the Debug channel — it starts unbound:

  ```sh
  defaults read com.tinycast.app.dev | grep hotkey.togglePalette
  # {"combo":{"_0":{"carbonKeyCode":49,"carbonModifiers":256}}}  → ⌘Space
  ```

  `carbonKeyCode` is the virtual key (49 = Space), `carbonModifiers` is the Carbon mask
  (256 = ⌘, 512 = ⇧, 2048 = ⌥, 4096 = ⌃).

## 2. Build, install, restart

| What changed | Command | Restart |
| --- | --- | --- |
| The app | the Debug `xcodebuild` line in [CUSTOM.md](CUSTOM.md) | yes |
| A native plugin | `extensions/<name>/build.sh install` | yes — dylibs load at launch |
| A Raycast extension | `npm run ship` (build + `install.sh`) | rescan in Settings, or restart |

Two traps that cost real time:

- **A `TinycastPluginKit` signature change breaks every installed plugin.** Adding even a defaulted
  parameter to `PluginScaffold.init` changes the mangled symbol, so an old dylib fails to resolve
  it. Rebuild *all* plugins in the same pass, not just the one you are testing.
- **Restart with `pkill`, not by closing the palette.** The panel is an accessory window; the
  process keeps running with the old dylib loaded.

  ```sh
  pkill -f "Tinycast Dev.app/Contents/MacOS"; sleep 2
  open -a "$PWD/build/DerivedData/Build/Products/Debug/Tinycast Dev.app"; sleep 6
  ```

## 3. Drive the real keyboard

Write the whole run as one script and **start it as a background job**. A foreground driver dies the
moment anything interrupts the session, halfway through a sequence, leaving the app in a junk state.

```sh
cat > /tmp/drive.sh <<'EOF'
#!/bin/bash
k() { osascript -e "tell application \"System Events\" to key code $1"; }
t() { osascript -e "tell application \"System Events\" to keystroke \"$1\""; }
pkill -f "Tinycast Dev.app/Contents/MacOS"; sleep 2
open -a "$HOME/Developer/tinycast/build/DerivedData/Build/Products/Debug/Tinycast Dev.app"
sleep 6
osascript -e 'tell application "System Events" to key code 49 using {command down}'; sleep 2
t "stock quotes"; sleep 1.5     # host launcher query
k 36; sleep 2.5                 # Return — open the surface
t "netfl"; sleep 3              # the surface's own field; wait for the network
k 51; sleep 3                   # ⌫ — the edit that re-runs the search
k 125; sleep 0.8                # ↓
EOF
bash /tmp/drive.sh
```

| Key | Code | Key | Code |
| --- | --- | --- | --- |
| Return | 36 | ↓ | 125 |
| Escape | 53 | ↑ | 126 |
| Delete (⌫) | 51 | ← | 123 |
| Space | 49 | → | 124 |

Timing rules, each learned from a flaky run:

- **Sleep ≥ 2 s after summoning the palette.** Keystrokes sent before the panel is key land in the
  previous app, or arrive scrambled into the field.
- **Sleep past the network.** A list that populates from a request needs ~3 s before its keys mean
  anything; pressing ↓ while results are still arriving hits a reset selection.
- **One screenshot per state**, taken inside the script, not afterwards from memory.

## 4. Capture the panel, not the screen

Ask the window for its own rect, then capture exactly that. `screencapture -R` takes **points**, and
`position`/`size` from the accessibility API are points too, so they compose:

```sh
osascript -e 'tell application "System Events" to tell process "Tinycast Dev" \
  to get {position, size} of windows'
# 1844, 416, 750, 475
screencapture -x -R1844,416,750,475 /tmp/panel.png
```

Then **look at the image**. A one-line "is the row highlighted?" question to a vision model is not
evidence: during one of these sessions it called a hovered row selected, and called a clearly
accented row unhighlighted, in the same run. Read the PNG and judge it yourself; a full-screen
`screencapture -x` downscaled to fit is where subtle washes go to die.

## 5. When the pixels disagree with the model

If the state says one thing and the screen shows another, stop guessing and instrument. Append to a
file from inside the view — `print` is not visible in a released dylib under a GUI app:

```swift
private func debugLog(_ line: String) {                       // TEMPORARY
    guard let debug = FileHandle(forWritingAtPath: "/tmp/tcdebug.log") else { return }
    debug.seekToEndOfFile()
    debug.write(Data((line + "\n").utf8))
    try? debug.close()
}
```

`: > /tmp/tcdebug.log` first — the handle only opens on an existing file. Log, in this order, until
one of them contradicts the others:

1. **The key path** — did the event reach the handler at all, and with what modifiers.
2. **The model** — the state the handler wrote (`selection`, `query`, counts).
3. **The render pass** — from inside `body`, via `let _ = debugLog(…)`: the derived values the view
   rendered with, *including the collection itself*, not only its count.
4. **Per-item derived state** — `row 3 NFLX.TO selected=false`, one line per row.
5. **A tree marker** — `@State private var treeID = UUID().uuidString.prefix(4)` in the prefix,
   which is how you tell "my handler writes to a detached copy" from "the rows never repainted".
6. **The network** — status code and byte count per attempt, for anything the view renders from a
   request. A silent `try?` turns a 429 into an empty screen.

That ladder is what turned "the arrow keys don't work" into "the arrow keys work, the rows are
stale". Strip every line of it before you finish, and prove it:

```sh
grep -rn "FileHandle\|debugLog\|treeID\|/tmp/" Sources/ Tinycast/ TinycastPluginKit/
```

## 6. What to check, per surface

**Every surface**

- Each footer chip does what it says, on the view it is shown on — and is **hidden when its key is
  inert**. A chip that advertises a dead Return is worse than no chip.
- Escape unwinds one step at a time: clear the surface's own query, then pop its stack, then leave.
  No press may skip a level.
- ⌫ with a non-empty field edits text. It only backs out once there is nothing left to delete.
- Selection is unmistakable next to hover. Wash the selected row with the accent and give it a
  leading bar; leave hover a faint grey. Two greys two percent apart read as "the keys do nothing".
- Arrow keys move the selection **and** scroll it into view, at both ends of the list.
- Nothing else on the screen moves when the selection does. A nested scroller is the usual culprit.

**A list whose data changes** (search-as-you-type, a filtered watchlist)

- Edit the query mid-string — type, then ⌫ — and confirm the rows themselves change, not just the
  count. This is the single highest-yield UI check in this document.
- Selection lands on a row that is actually drawn after the data changes.
- Empty state and error state both render, and both offer a way out.

**Anything rendered from the network**

- Run it once with the cache cleared (`defaults delete com.tinycast.app.dev <key>`) — a screen that
  only looks right because something cached it is not verified.
- Every row is populated, not most of them. A placeholder on one row out of five is a dropped
  request, not a rendering choice.
- Check what the code *asks for*, not only what it draws: an unordered or truncated request list
  fails silently, and looks exactly like a network error.

**A native plugin surface** — also check [docs/features/plugins.md](docs/features/plugins.md)'s
keyboard contract: ⌘K palette opens and runs a row, the back chevron matches Escape, and content
clears the footer (`.contentMargins(.bottom, …)`).

**A Raycast extension** — the failing path as well as the happy one: a non-zero exit, an empty
result, and a command that needs the login shell (see the `TERM=dumb` entry below).

## 7. Register of bugs that shipped past a review

Append to this; it is the reason the file exists.

### Half the watchlist had no price — 2026-09

**Symptom.** Some cards showed a dash and the bare ticker instead of a price and a company name,
inconsistently between launches.
**Cause.** Two, stacked. `Array(Set(favourites + recent)).prefix(12)` picked which symbols to fetch
from an **unordered** set, so favourites past the cap were never requested at all; and the twelve
per-symbol chart requests that were made went out at once, which Yahoo answers with `429`s that a
`try?` swallowed into `nil`.
**Fix.** Request favourites first in order, one crumb-gated batch call for every symbol
(`v7/finance/quote?symbols=…`), retries on 429/5xx, a paced fallback for stragglers, and the last
known quotes cached so a throttled refresh shows a stale number rather than a dash.
**Check.** Section 6, "anything rendered from the network" — clear the cache, then count the rows.

### A vertical scroller chased an id inside a horizontal strip — 2026-09

**Symptom.** ← / → between favourite cards scrolled the whole page up a little on every press.
**Cause.** The watchlist's outer `ScrollViewReader` ran `proxy.scrollTo(selIndex)` for *every*
selection change. Ids `0..<favRefs.count` belong to the horizontal strip nested inside it, so the
vertical scroller centred a card that had not moved vertically at all.
**Fix.** Each reader owns its own range: the vertical one bails unless `selIndex >= favRefs.count`,
the horizontal one unless `selIndex < favRefs.count`.
**Check.** Step along the horizontal axis and compare two captures — every other element must sit
on the same pixel row.

### SwiftUI identity conflict freezes a list — 2026-09

**Symptom.** ↑/↓ "stopped working" in a search list, but only after editing the query.
**Cause.** `ForEach(Array(results.enumerated()), id: \.element.id)` keyed rows by symbol while each
row also carried `.id(index)`. Two identities for one view: on re-search the array changed but the
indices did not, so SwiftUI reused the rendered rows. The model advanced correctly — selection was
walking a row that was never drawn, and the visible list still showed a symbol no longer in the
data.
**Fix.** Key the list positionally, matching the id the scroller seeks and the index the selection
counts: `ForEach(Array(results.enumerated()), id: \.offset)`.
**Check.** Section 6, "a list whose data changes" — type, backspace, then arrow.

### Selection indistinguishable from hover — 2026-09

**Symptom.** Reported as "the arrow keys don't navigate"; the keys were fine.
**Cause.** Selected drew `Color.primary.opacity(0.10)`, hover `0.06`. With the pointer resting on
the list, two near-identical washes appeared and neither read as "here".
**Fix.** Accent wash plus a 3 pt leading bar for selection; hover stays the faint grey.
**Check.** Move the mouse over the list *and* press ↓ — both highlights must be tellable apart.

### A footer chip for a key that does nothing — 2026-09

**Symptom.** "Open ⏎" shown on a detail view where Return was inert.
**Cause.** `primaryActionLabel` was computed from the root list's state, not the view on top.
**Fix.** Derive the label from the current view (`navigator.canPop ? "" : "Open"`); `""` hides it.
**Check.** Walk every view of the surface and read the footer on each.

### The host stole a bare backspace from a plugin — 2026-09

**Symptom.** Deleting a character inside a plugin's search field threw the user back to the
launcher.
**Cause.** `PaletteWindowController.onBareBackspace` treats ⌫ as Escape's back step once *its*
query is empty — and a surface's query is not the host's.
**Fix.** A plugin surface owns the key; the host leaves it alone (`docs/features/plugins.md`).
**Check.** Type in a surface's own field, then ⌫.

### Escape skipped a whole view — 2026-09

**Symptom.** Escape from a surface's search results left the plugin instead of returning to its
list.
**Cause.** The scaffold went straight from `pop()` to `pluginExit()`; a surface had no way to
consume Escape first.
**Fix.** `PluginScaffold(escape:)`, offered before the pop and before the exit.
**Check.** Escape from the deepest state and count the steps back out.

### A stale dylib answering the keys — 2026-09

**Symptom.** A fix "did not take" after a rebuild.
**Cause.** The plugin dylib is loaded at launch; reinstalling it under a running app changes
nothing.
**Fix.** `pkill` and relaunch as part of the driver script, every run.
**Check.** Your driver restarts the app before it types anything.

### `TERM=dumb` noise swallowed a real error — 2026-09

**Symptom.** An extension showed `[ERROR] - (starship::print): Under a 'dumb' terminal` instead of
the command's own failure.
**Cause.** Shelling out through an *interactive* login shell (`zsh -ilc`) sources `~/.zshrc`, and
the prompt framework writes to stderr under the `TERM=dumb` the host provides. The CLI's real
message was on stdout, which the error path discarded.
**Fix.** `zsh -lc` with `TERM=xterm-256color`, show stdout *and* stderr, and strip prompt chatter.
**Check.** Run the extension's command through the same shell it uses and read both streams.

## 8. Before you call a UI change done

- The driver script ran end to end against a freshly restarted Debug build.
- One captured panel image per state you changed, looked at rather than asked about.
- The list checks in section 6 pass, including the type-then-backspace one.
- Anything network-backed was seen once with its cache cleared.
- Every temporary log line is gone, proven by the grep in section 5.
- Any new failure mode is written into section 7 — in the same commit.
