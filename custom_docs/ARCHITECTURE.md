# Architecture (fork front door)

How Tinycast is built, for **this fork**: enough to navigate the code and add what you need without
fighting the upstream rebase.

**A front door, not a second source of truth** — [`docs/architecture.md`](../docs/architecture.md)
and [`docs/features/`](../docs/features/) hold the authoritative layering/ownership/window
descriptions; this file only summarizes and links out, so it can't silently drift after a rebase.
Unique here: the extension-vs-plugin decision rules and current-state notes (drift, seams).

Read order for a fork maintainer:

1. This file — the shape, the extension-point map ([§13](#13-extension-point-map)), the fork strategy
   ([§14](#14-fork-maintenance)).
2. [CUSTOM.md](CUSTOM.md) — branch model, upstream sync, change register.
3. [docs/architecture.md](../docs/architecture.md) + [docs/standards.md](../docs/standards.md) —
   layering and coding rules in depth.
4. [docs/features/](../docs/features/) — the doc for whatever you touch.

**Authority order.** [AGENTS.md](../AGENTS.md) is non-negotiable, **wins every disagreement**;
`docs/` is canonical only where it agrees — e.g. `docs/architecture.md` still describes the
`AppCore`-as-view-locator pattern AGENTS.md forbids ([§3](#3-composition-root--appcore)); that's drift
to fix, not the target.

---

## 1. The shape in one screen

A menu-bar **accessory** app (`LSUIElement`, no Dock icon) — SwiftUI + AppKit, Swift 6 language mode,
macOS 26+, **zero third-party dependencies**. Nearly all UX lives in one launcher palette; a few
AppKit windows handle the rest.

```
TinycastApp (@main)          two MenuBarExtra scenes, nothing else declarative
  └─ AppDelegate             applicationDidFinishLaunching → AppCore.shared.start()
       └─ AppCore (singleton) owns the stores, coordinators, and window controllers
            ├─ PaletteWindowController → PalettePanel (NSPanel) → RootPaletteView (SwiftUI)
            │     the command palette: one shell, one screen per PaletteMode
            ├─ Settings / Onboarding / Notes / Support / Camera  (AppKit windows)
            └─ Dialog / HUD controllers                          (borderless AppKit panels)
```

- **One owner.** `AppCore.shared` (`App/AppCore.swift`) — the only long-lived singleton: every store,
  coordinator, monitor and window controller, wired once in `start()`. No DI container.
- **One control surface.** A "feature" is mostly *a screen inside the palette* plus the state and
  effects behind it.

---

## 2. The four layers

Every mature subsystem converged on these four; `Tests/` harnesses hold them apart
(see [§12](#12-testing--enforcement)). Full detail: [docs/architecture.md](../docs/architecture.md).

```
PURE   (Model/)     Foundation only. No AppKit/SwiftUI, no clock/network/filesystem;
                    every environment fact is injected.            → decides things.
EFFECT (Service/)   All platform I/O (AX, CGEventTap, NSWorkspace, URLSession, SQLite, …).
                    → does things.
STATE               ~40 @MainActor @Observable stores / sessions / indices.
VIEW   (UI/ + Coordinator)   Declarative SwiftUI + the feature's action surface.
```

Mechanically enforced: **`Model/` may not import AppKit or SwiftUI** — harnesses compile shipped
`Model/` sources, so a leak is a build failure
(`grep -rln 'import AppKit\|import SwiftUI\|import Cocoa' Tinycast/Features/*/Model/` must be empty).
Confirmation gates live in the coordinator, never the runner — `Service/` stays testable.

Outside any feature, depending on none: `Features/PaletteRowIndex.swift` (palette-owned flat index)
and the shared `DesignSystem/` + `Platform/`.

---

## 3. Composition root — `AppCore`

`App/AppCore.swift` (~670 lines): eager `let` stores, ~28 `@ObservationIgnored private(set) lazy var`
coordinators (`@ObservationIgnored` stops a lazy read from registering an Observation dependency),
and `start()` — the whole boot in one screen (`applyEnabled()` per feature, `observeFeatureSwitches`
re-projections, hotkey closure wiring, deferred index/emoji/FX loads). New long-lived state is wired
here, in `start()`.

**Normative ownership rule (from [AGENTS.md](../AGENTS.md)):**

> `AppCore` is the sole owner … **Views reach a feature's coordinator through `@Environment`, not
> `AppCore`.** A view must never reach past a coordinator into a store to mutate it (reading to
> *render* is fine).

⚠️ **Current drift, not the rule.** Much shipped code still injects `@Environment(AppCore.self)` and
calls `core.someCoordinator.foo()` as a locator (`RootPaletteView` alone: ~24 environment injections);
[docs/architecture.md](../docs/architecture.md) still describes that as intended, contradicting
AGENTS.md. New views take the specific coordinator(s) via `@Environment` — the locator pattern isn't
the target.

> One process boundary: clipboard OCR runs out-of-process (`ClipboardTextWorker` →
> `ClipboardTextHelper`) so Vision/PDFKit allocations belong to a process that exits.

---

## 4. Entry points & windows

`TinycastApp` (`@main`) declares **only two `MenuBarExtra` scenes**; everything else is imperative
AppKit under an `AppCore`-owned controller — the palette (`PaletteWindowController` → `PalettePanel`),
Settings/Onboarding/Support (`AppWindowController`), Notes (`NotesPanel`), dialogs (`DialogController`
— the app's **only** confirmation/prompt presenter; **`NSAlert` is never used**), HUDs, camera.
Appearance is a setting (`.system` → `nil`, so AppKit follows macOS). Owner-per-window table:
[docs/architecture.md](../docs/architecture.md#entry-points-and-windows).

---

## 5. The palette shell (the spine of the UX)

Where a fork spends most effort. Full detail: [docs/features/palette.md](../docs/features/palette.md).
Files under `Palette/`:

- **`PaletteMode`** — a flat enum (**16 cases**: `launcher`, `clipboard`, `ai`, `aiHistory`,
  `calculatorHistory`, `emoji`, `fileSearch`, `menuSearch`, `switchWindows`, `schedule`, `uninstall`,
  `quicklinks`, `snippets`, `customCommandArguments`, `extensionCommand`, `plugin`), each with
  `systemImage`/`placeholder`.
- **`PaletteScreen`** — the per-mode protocol; `rows` is the single source of visible order the flat
  index addresses. A minimal screen implements ~5 of ~15 requirements (rest default); richer ones add
  `actions(at:)` (⌘K menu), `move(_:axis:from:)` (grid nav), `headerAccessory(…)`.
- **`RootPaletteView`** (~1500 lines, the largest file) — resolves `PaletteMode → concrete screen` in
  one big `switch`, composing the body via two view-modifier chains (`stateObservers`, `keyHandlers`).
- **`PalettePanel`** — the real **key-routing chokepoint** in `sendEvent(_:)`: hover/⌘-held tracking →
  emacs-arrow respelling → inline ⌘K editor → menu-filter typing → **menu-open input freeze** →
  Escape/backspace/boundary-arrow/command-shortcut interception → only then SwiftUI's `onKeyPress`.
- **`MenuPanel`** — a second `NSPanel` (`canBecomeKey = false`) for every ⌘K/footer/dropdown, keeping
  the glass menu unclipped.
- **`PaletteState`** — `@Observable` session state: `mode`/`query`/`selection`, a
  `backStack: [PaletteFrame]` nav stack, and the **token pattern** (one-shot AppKit events as `UUID`
  bumps SwiftUI can `.onChange` on).
- **`PaletteEscapeAction`** — a pure decision table for Escape's priority ladder; a clean extension
  point for a new escape-intercepting mode.
- The **footer** is the shared **`ActionBar`** from `TinycastPluginKit` —
  see [§9](#9-third-party-code-two-systems).

---

## 6. Feature anatomy

One folder per feature under `Features/<Name>/`. Large features split `Model/`/`Service/`/`UI/`/
`Settings/`; small ones stay flat. Each exposes a **`Coordinator`** (its action surface), registers
state on `AppCore`, and gates itself with an `applyEnabled()` / `apply<Feature>Presence()` method
(~16 share this shape) re-projected on settings change by `AppCore.track`. Type-suffix vocabulary:
[docs/standards.md#naming](../docs/standards.md#naming).

---

## 7. The launcher & the `AppEntry.Kind` spine

Everything launchable is one `AppEntry` tagged by **`AppEntry.Kind`** (**14 cases**: `application`,
`systemSettings`, `command`, `quickAction`, `customCommand`, `assistant`, `snippet`, `systemAction`,
`windowCommand`, `windowLayout`, `quicklink`, `extensionCommand`, `meeting`, `plugin`). Detail:
[docs/features/launcher.md](../docs/features/launcher.md).

- **`AppIndex`** (`Service/AppIndex.swift`) unions a disk-scanned app slice with ~10 synthetic slices
  from other coordinators, memoizes matching/ranking. `AppEntry.Kind` + `KindDescriptor` live here —
  a new case must name all descriptor fields, or it's a build error.
- Orthogonal preference stores keyed by `entry.preferenceKey`: `VisibilityStore`, `AliasStore`,
  `LauncherRankingStore` (frecency), `FavoritesStore`.
- **`LauncherCoordinator`** is the single activation funnel; **`AppActionsMenu`** builds the ⌘K row
  menu from kind-derived flags.

`AppEntry.Kind` **is the only thing that says what an entry is** — never re-derive a category by
sniffing an ID. Which *pane* lists a command is separate, stated only in `SettingsTab.ownedCommands`.

---

## 8. Shared layers — `DesignSystem/` and `Platform/`

Depended on by every feature, depending on none. `DesignSystem/`: `Theme.swift` is the **single
design-token source** (dark values pinned pixel-exact by `appearance-test`), `InterfaceMetrics` the
UI-scale view over it, plus shared chrome (`PopoverMenu`, `KeyCapChip`, `BarButton`) and the tuned,
off-limits `Scrolling/`. `Platform/`: system shims (`Permissions`, `AppPaths`, `NotificationToken`,
`HealthTicker`, `Signposts`, `Images/`, `Compression/`).

---

## 9. Third-party code: two systems

Two independent systems run **untrusted** third-party code into the palette, sharing a hosting
pattern (Manager + Coordinator + a `PaletteScreen` + a `PaletteMode` case) but differing in *how* code
is isolated — **neither is a security sandbox**. Detail:
[docs/features/extensions.md](../docs/features/extensions.md), [plugins.md](plugins.md).

| | JS extensions (upstream) | Native plugins (**fork-original**) |
|---|---|---|
| Code | Raycast-format JS package | compiled Swift `.dylib` |
| Execution | **in-process** `JSContext` on a serial `DispatchQueue` | `dlopen` into the app process |
| Isolation | a **capability bridge**, not a sandbox — JS reaches Swift only through the `__tinycastHost` seam and only JSON data crosses back | none — calls Swift directly |
| Reach | broad: `ExtensionNodeShims` exposes **unrestricted filesystem** (`expandingTildeInPath`, any path) and **child processes** (`Process()` / `/bin/sh -c`) | **full app privileges** |
| Gate | install-time trust (it's the user's own package) | one-time consent dialog |
| Trust posture | **untrusted** — treat like running an npm package with your account's permissions | **untrusted** — arbitrary native code with everything the app can do |

Ship/enable only code you trust in both: an extension's bridge is not a sandbox, and a plugin carries
full app privileges.

- **`Features/Extensions/`** — `ExtensionManager` (installed set, session state, launcher publishing)
  + `ExtensionRuntime` (the `JSContext` + `__tinycastHost`) + `ExtensionNodeShims` (fs/proc/crypto
  surface). No Swift object crosses back to JS — only JSON.
- **`TinycastPluginKit/`** — the public framework contract, embedded for exact-module version
  matching; the one module both app *and* plugin dylibs link, so shared UI lives here: the launcher
  footer is built from its **`ActionBar`** (Theme-derived tokens as `ActionBarStyle`). Extension
  chrome (`ExtensionActionsPanel`) stays separate inside `Features/Extensions/` per the AGENTS.md
  isolation invariant.

---

## 10. Settings, state & backup

`AppSettings` fronts ~90 UserDefaults keys (each a computed `var` with a `didSet`); `AppSettingsKey`
enumerates them; `SettingsTab` is the pane enum, with a *separate* `SettingsSection` for grouping.
`SettingsBackupCoverage` forces every key classified
`mirrored`/`externallySourced`/`deliberatelyExcluded` (test-enforced); consent-bearing flags are
hard-excluded so an imported backup can't grant a capability. Detail:
[docs/features/backup.md](../docs/features/backup.md).

---

## 11. Concurrency & observation

Swift 6 language mode; **exactly one actor** (`@MainActor`) — heavy/IO work goes off-main as
`nonisolated static` functions via `Task.detached`. Observation, not `ObservableObject`; views read
through `@Environment` (never a type annotation for an `@Observable` value); `@ObservationIgnored` on
memo caches; `AppCore.track` is the willSet-safe settings-reaction pattern. Idioms:
`NotificationToken` (observer lifetime), `isolated deinit` (`ClipboardStore` SQLite), Carbon pointers
decoded before crossing into actor code, `HealthTicker` (one shared timer). Full rules:
[docs/standards.md](../docs/standards.md).

---

## 12. Testing & enforcement

No XCTest target. `Scripts/run-tests.sh` declares ~85 standalone harnesses, each compiling the
**shipped** sources it guards (`swiftc … <sources> Tests/<name>.swift`) — a `Model/` purity leak is a
compile failure. Definition of done (also [AGENTS.md](../AGENTS.md)): harnesses pass, warning-free
Debug build, `./Scripts/lint.sh` clean, purity grep empty, any doc your change broke fixed in the same
commit. Detail: [docs/testing.md](../docs/testing.md); UI changes: `UI_TESTS.md`.

---

## 13. Extension-point map

The central enums fan out across several files; adding a case means editing each. Sites are named by
symbol, not line number (drifts) — the practical index, and the reason
[§14](#14-fork-maintenance) weighs seams.

| To add… | Compiler-checked sites | Silent/runtime sites (a miss fails quietly) |
|---|---|---|
| a **launcher kind** (`AppEntry.Kind`, 13) | `AppIndex` `descriptor`/`hotKeyAction`/`kindSymbol`; `LauncherCoordinator.launch`/`runCommand` | `LauncherList` section-order array (runtime `assert`); `AppActionsMenu`/`RootPaletteView` `.kind ==` checks; `VisibilityStore.allowsHotKey` |
| a **palette mode** (`PaletteMode`, 16) | `RootPaletteView.screen`; `PaletteMode.systemImage`/`placeholder` | `PaletteEscapeAction`; `PaletteFilterAction`; `PaletteTabAction` |
| a **hotkey action** (`HotKeyAction`) | `HotKeyAction.defaultsKey`; `HotKeyManager.setBinding`/`displayName`/`perform`; `AppCore.hotKeyDisplayName` | `VisibilityStore.allowsHotKey` |
| a **settings tab** (`SettingsTab`) | `SettingsTab.title`/`systemImage`; `SettingsSection.tabs`; `SettingsDetailView` | `SettingsSearchCatalog`; `SettingsAnchor` |
| a **setting** | `AppSettings` property + `init`; `AppSettingsKey`; `SettingsBackupCoverage` (test-enforced) | pane view; `SettingsSearchCatalog` row |
| a **coordinator** | `AppCore` property + `start()` wiring | — |

---

## 14. Fork maintenance

Mechanics — the single-branch model, upstream sync, the change register — are in
[CUSTOM.md](CUSTOM.md). This section is the *strategy*.

### Cost model

Every line in `git diff upstream/main..main` is rebased by hand on every upstream merge — ten files
changed means ten conflict sites, **forever**. Push every custom need down this ladder:

1. **A JS extension** (`~/Developer/tinycast_addons/`) — zero host change, zero rebase surface.
   Default home for "a thing I want Tinycast to do"; see [§9](#9-third-party-code-two-systems) for
   the trust trade-off.
2. **A native plugin** (also in `tinycast_addons`) — full Swift power via `TinycastPluginKit`, still
   zero *upstream-file* surface.
3. **One new fork-owned file + one call site** — when the host must change, isolate it.
4. **Direct upstream-file edits** — last resort, only when the host is genuinely wrong; add a register
   row the same commit.

### Shrink the *existing* delta first

Cheapest maintainability work is removing delta, not adding abstraction:

- **Upstream the upstreamable.** The register marks the inline alias/shortcut-editing change
  "upstreamable: yes" — landing it deletes that row from the burden, strictly better than any seam.
  Do this before anything structural.
- Keep the native-plugin change (the fork's big delta) as localized as it already is; don't grow it.

### Seams — speculative, and only after proven pain

A survey suggested data-driven registries (e.g. `[PaletteMode: Descriptor]`) to collapse the
[§13](#13-extension-point-map) fan-outs. **Not the recommended first move** — it fights the project's
own rule, *no abstraction until it removes more complexity than it adds*
([docs/standards.md](../docs/standards.md#simplicity-and-maintainability)):

- A `PaletteMode` registry still requires editing the closed enum to add `.plugin` — it only trades a
  compiler-*exhaustive* `switch` for a runtime table + factory indirection.
- A fork-only registry upstream lacks **is** a large permanent conflict against every upstream edit to
  `RootPaletteView` — worse than today's scattered edits.

Extract a seam only **(a)** after repeated *real* rebase conflicts at that site prove it pays, and
**(b)** as an **upstream PR first** — it helps the fork only if upstream adopts it.

### Efficiency

The codebase is disciplined (memoization, <100 MB resident baseline after palette close —
[docs/standards.md#performance-and-memory](../docs/standards.md#performance-and-memory)); its own
rule: **measure before optimising, measure before caching**. Candidates *to profile*, not to change
on sight:

- `LauncherList.rows` regroups a `[Kind: [AppEntry]]` dictionary per render. `LauncherList` is a
  transient SwiftUI value view, so caching would add invalidation machinery for every change to
  `results`/favorites/card/fallbacks/section-mode — one-pass grouping may well be cheaper and safer.
- Leave alone unless a profile says otherwise: cache purge on `hide()`, main-actor SQLite within a
  1000-row window, the serialized JS queue.
