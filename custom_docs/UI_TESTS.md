# Driven UI verification

No UI test target exists — prove a change works: build, install, drive the app from the keyboard,
capture the panel, judge the pixels, instrument the view tree when they disagree.

Run for any new feature, palette screen, plugin, Raycast extension, or a surface's key/chrome/list
change. [testing.md](../docs/testing.md) owns the harnesses and manual sweep; this file covers what
a human would skip.

§7's register is the point: every bug that survived review, with symptom, cause, and the check that
would have caught it.

## 1. Prerequisites, once

- **Debug channel** only (`Tinycast Dev.app`, `com.tinycast.app.dev`) — the driver types into
  whatever holds focus.
- `osascript`'s process needs **Accessibility**, or key codes are silently swallowed.
- Palette hotkey starts unbound:

  ```sh
  defaults read com.tinycast.app.dev | grep hotkey.togglePalette
  # {"combo":{"_0":{"carbonKeyCode":49,"carbonModifiers":256}}}  → ⌘Space
  ```

  `carbonKeyCode` = virtual key (49 = Space); `carbonModifiers` = Carbon mask (256 = ⌘, 512 = ⇧,
  2048 = ⌥, 4096 = ⌃).

## 2. Build, install, restart

| What changed | Command | Restart |
| --- | --- | --- |
| The app | the Debug `xcodebuild` line in [CUSTOM.md](CUSTOM.md) | yes |
| A native plugin | `extensions/<name>/build.sh install` | yes — dylibs load at launch |
| A Raycast extension | `npm run ship` (build + `install.sh`) | rescan in Settings, or restart |

Two traps: a `TinycastPluginKit` signature change (even a defaulted init param) breaks every
installed plugin — rebuild *all* of them. Restart via `pkill`; closing the palette leaves the old
dylib loaded.

```sh
pkill -f "Tinycast Dev.app/Contents/MacOS"; sleep 2
open -a "$PWD/build/DerivedData/Build/Products/Debug/Tinycast Dev.app"; sleep 6
```

## 3. Drive the real keyboard

One script, **run as a background job** — a foreground driver dies mid-run, leaving junk state.

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

Timing: ≥ 2 s after the palette (early keys land in the previous app, or scramble); ~3 s past a
network-populated list before keys register, or ↓ resets selection; one screenshot per state,
in-script.

## 4. Capture the panel, not the screen

Ask the window its own rect and capture that — `screencapture -R` and the accessibility API's
`position`/`size` both use points:

```sh
osascript -e 'tell application "System Events" to tell process "Tinycast Dev" \
  to get {position, size} of windows'
# 1844, 416, 750, 475
screencapture -x -R1844,416,750,475 /tmp/panel.png
```

Then **look at the image** — a vision-model "is this row highlighted?" isn't evidence; one session
called a hovered row selected and an accented row unhighlighted in the same run. Full-screen
`screencapture -x` downscaled is where subtle washes vanish.

## 5. When the pixels disagree with the model

Instrument, don't guess: append to a file from inside the view (`print` is invisible in a released
dylib under a GUI app):

```swift
private func debugLog(_ line: String) {                       // TEMPORARY
    guard let debug = FileHandle(forWritingAtPath: "/tmp/tcdebug.log") else { return }
    debug.seekToEndOfFile()
    debug.write(Data((line + "\n").utf8))
    try? debug.close()
}
```

`: > /tmp/tcdebug.log` first (handle needs an existing file). Log in order until one contradicts
the rest:

1. **Key path** — did the event reach the handler, with what modifiers.
2. **Model** — state the handler wrote (`selection`, `query`, counts).
3. **Render pass** — from `body` via `let _ = debugLog(…)`: derived values rendered with, including
   the collection itself, not just its count.
4. **Per-item state** — `row 3 NFLX.TO selected=false`, one line per row.
5. **Tree marker** — `@State private var treeID = UUID().uuidString.prefix(4)`: detached copy vs.
   unrepainted rows.
6. **Network** — status/byte count per attempt; a silent `try?` turns a 429 into an empty screen.

Strip every line before finishing:

```sh
grep -rn "FileHandle\|debugLog\|treeID\|/tmp/" Sources/ Tinycast/ TinycastPluginKit/
```

## 6. What to check, per surface

**Every surface**

- Footer chips match reality, **hidden when their key is inert**.
- Escape unwinds one step at a time: query → stack → leave. No skipped levels.
- ⌫ edits text while the field is non-empty; backs out only once empty.
- Selection unmistakable from hover: accent wash + leading bar vs. faint grey — two percent apart
  reads as "the keys do nothing".
- Arrow keys move selection **and** scroll it into view, at both list ends.
- Nothing else on screen moves when selection does — a nested scroller is the usual culprit.

**A list whose data changes** (search-as-you-type, filtered watchlist)

- Edit the query mid-string (type, ⌫); rows themselves must change, not just the count —
  highest-yield check here.
- Selection lands on a row actually drawn post-change.
- Empty and error states render, both offer a way out.

**Anything rendered from the network**

- Run once with cache cleared (`defaults delete com.tinycast.app.dev <key>`) — looking right only
  via caching is unverified.
- Every row populated, not most — one placeholder in five is a dropped request.
- Check what the code *asks for*, not just what it draws: an unordered/truncated request list fails
  silently, indistinguishable from a network error.

**A native plugin surface** — also check [plugins.md](plugins.md)'s keyboard contract: ⌘K
opens/runs a row, back chevron matches Escape, content clears the footer
(`.contentMargins(.bottom, …)`).

**A Raycast extension** — failing path too: non-zero exit, empty result, login-shell dependency
(`TERM=dumb` below).

## 7. Register of bugs that shipped past a review

Append to this.

### Half the watchlist had no price — 2026-09

**Symptom.** Dash, bare ticker instead of price/name on some cards, inconsistent across launches.
**Cause.** `Array(Set(favourites + recent)).prefix(12)` used an **unordered** set — favourites past
the cap dropped — and fired twelve per-symbol requests at once; a bare `try?` swallowed Yahoo's
`429`s into `nil`.
**Fix.** Favourites ordered first, one crumb-gated batch call per symbol
(`v7/finance/quote?symbols=…`), retries on 429/5xx, paced fallback, last-known quotes cached.
**Check.** §6 network check — clear cache, count rows.

### A vertical scroller chased an id inside a horizontal strip — 2026-09

**Symptom.** ← / → between favourite cards scrolled the page up slightly each press.
**Cause.** Watchlist's outer `ScrollViewReader` called `proxy.scrollTo(selIndex)` on every
selection change; ids `0..<favRefs.count` belong to the nested horizontal strip, so it centred a
card that hadn't moved vertically.
**Fix.** Each reader owns its range: vertical bails unless `selIndex >= favRefs.count`, horizontal
unless `selIndex < favRefs.count`.
**Check.** Step the horizontal axis, compare captures — elements must share a pixel row.

### SwiftUI identity conflict freezes a list — 2026-09

**Symptom.** ↑/↓ "stopped working" in a search list, only after editing the query.
**Cause.** `ForEach(Array(results.enumerated()), id: \.element.id)` keyed rows by symbol; each row
also carried `.id(index)` — two identities. Re-search changed the array, not the indices: SwiftUI
reused rendered rows, so selection walked a row never drawn while the list showed a stale symbol.
**Fix.** Key positionally: `ForEach(Array(results.enumerated()), id: \.offset)`.
**Check.** §6 "a list whose data changes" — type, backspace, arrow.

### Selection indistinguishable from hover — 2026-09

**Symptom.** Reported as "arrow keys don't navigate"; the keys were fine.
**Cause.** Selected drew `Color.primary.opacity(0.10)`, hover `0.06` — near-identical, neither read
as "here".
**Fix.** Accent wash + 3 pt leading bar for selection; hover stays faint grey.
**Check.** Mouse over the list *and* press ↓ — highlights must be tellable apart.

### A footer chip for a key that does nothing — 2026-09

**Symptom.** "Open ⏎" shown on a detail view where Return was inert.
**Cause.** `primaryActionLabel` was computed from the root list's state, not the view on top.
**Fix.** Derive the label from the current view (`navigator.canPop ? "" : "Open"`); `""` hides it.
**Check.** Walk every view, read the footer on each.

### The host stole a bare backspace from a plugin — 2026-09

**Symptom.** Deleting a character in a plugin's search field threw the user back to the launcher.
**Cause.** `PaletteWindowController.onBareBackspace` treats ⌫ as Escape's back step once *its*
query is empty — a surface's query isn't the host's.
**Fix.** A plugin surface owns the key; the host leaves it alone ([plugins.md](plugins.md)).
**Check.** Type in a surface's own field, then ⌫.

### Escape skipped a whole view — 2026-09

**Symptom.** Escape from search results left the plugin instead of returning to its list.
**Cause.** The scaffold went straight from `pop()` to `pluginExit()`, with no way for a surface to
consume Escape first.
**Fix.** `PluginScaffold(escape:)`, offered before pop and exit.
**Check.** Escape from the deepest state, count the steps back out.

### A stale dylib answering the keys — 2026-09

**Symptom.** A fix "did not take" after a rebuild.
**Cause.** Plugin dylib loads at launch — reinstalling under a running app changes nothing.
**Fix.** `pkill` and relaunch as part of the driver script, every run.
**Check.** Your driver restarts the app before typing anything.

### `TERM=dumb` noise swallowed a real error — 2026-09

**Symptom.** An extension showed `[ERROR] - (starship::print): Under a 'dumb' terminal` instead of
its own failure.
**Cause.** Shelling through an *interactive* login shell (`zsh -ilc`) sources `~/.zshrc`, whose
prompt framework writes stderr under `TERM=dumb`; the real message on stdout was discarded.
**Fix.** `zsh -lc` with `TERM=xterm-256color`, show stdout *and* stderr, strip prompt chatter.
**Check.** Run the command through the same shell it uses, read both streams.

## 8. Before you call a UI change done

- Driver script ran end to end against a freshly restarted Debug build.
- One captured panel image per changed state, viewed rather than asked about.
- §6 checks pass, including type-then-backspace.
- Network-backed surfaces seen once with cache cleared.
- Every temporary log line gone, per the §5 grep.
- New failure modes go into §7 — same commit.
