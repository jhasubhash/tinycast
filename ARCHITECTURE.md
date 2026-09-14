# Architecture (fork front door)

A map of how Tinycast is built, written for **this fork** — enough to navigate the code and add what
you need without fighting the upstream rebase.

**This file is a front door, not a second source of truth.** The authoritative, upstream-maintained
descriptions of the layering, ownership and windows live in [`docs/architecture.md`](docs/architecture.md)
and the per-feature docs in [`docs/features/`](docs/features/); this file summarizes them and links
out for anything volatile, so it can't silently drift after a rebase. What is *unique* here is the
fork strategy, the extension-vs-plugin decision rules, the "what do I touch to add X" map, and the
current-state notes (drift, seams) — not a re-derivation of `docs/`.

Read order for a fork maintainer:

1. This file — the shape, the extension-point map ([§13](#13-extension-point-map)), the fork strategy
   ([§14](#14-fork-maintenance)).
2. [CUSTOM.md](CUSTOM.md) — branch model, upstream sync, the register of what the fork carries.
   **Never commit to `main`.**
3. [docs/architecture.md](docs/architecture.md) + [docs/standards.md](docs/standards.md) — the
   layering and coding rules in depth.
4. The [docs/features/](docs/features/) doc for whatever you touch (each opens with its invariants).

**Authority order.** [AGENTS.md](AGENTS.md) is non-negotiable and **wins every disagreement**. The
`docs/` files are canonical only where they are consistent with AGENTS.md — where they aren't (e.g.
`docs/architecture.md` still describing the `AppCore`-as-view-locator pattern AGENTS.md forbids,
[§3](#3-composition-root--appcore)), AGENTS.md governs and the `docs/` file is drift to fix. This
front-door file sits below both: a summary and a map, never a source of truth — if it disagrees with
AGENTS.md or `docs/`, this file is stale.

---

## 1. The shape in one screen

A menu-bar **accessory** app (`LSUIElement`, no Dock icon) — SwiftUI + AppKit, Swift 6 language mode,
macOS 26+, **zero third-party dependencies**. Almost all UX is one launcher palette; a few AppKit
windows handle the rest.

```
TinycastApp (@main)          two MenuBarExtra scenes, nothing else declarative
  └─ AppDelegate             applicationDidFinishLaunching → AppCore.shared.start()
       └─ AppCore (singleton) owns the stores, coordinators, and window controllers
            ├─ PaletteWindowController → PalettePanel (NSPanel) → RootPaletteView (SwiftUI)
            │     the command palette: one shell, one screen per PaletteMode
            ├─ Settings / Onboarding / Notes / Support / Camera  (AppKit windows)
            └─ Dialog / HUD controllers                          (borderless AppKit panels)
```

Two facts explain most of the codebase:

- **One owner.** `AppCore.shared` (`App/AppCore.swift`) is the only long-lived singleton — every
  store, coordinator, monitor and window controller, wired once in `start()`. No DI container, no
  second singleton.
- **One control surface.** A "feature" is mostly *a screen inside the palette* plus the state and
  effects behind it.

---

## 2. The four layers

Every mature subsystem converged on the same four layers; the `Tests/` harnesses hold them apart
(see [§12](#12-testing--enforcement)). Full detail: [docs/architecture.md](docs/architecture.md).

```
PURE   (Model/)     Foundation only. No AppKit/SwiftUI, no clock/network/filesystem;
                    every environment fact is injected.            → decides things.
EFFECT (Service/)   All platform I/O (AX, CGEventTap, NSWorkspace, URLSession, SQLite, …).
                    → does things.
STATE               ~40 @MainActor @Observable stores / sessions / indices.
VIEW   (UI/ + Coordinator)   Declarative SwiftUI + the feature's action surface.
```

The one mechanically-enforced rule: **`Model/` may not import AppKit or SwiftUI** — the harnesses
compile the shipped `Model/` sources, so a leak is a build failure
(`grep -rln 'import AppKit\|import SwiftUI\|import Cocoa' Tinycast/Features/*/Model/` must be empty).
Confirmation gates live in the coordinator, never the runner, so `Service/` stays testable.

Outside any feature folder, depending on none: `Features/PaletteRowIndex.swift` (palette-owned flat
index) and the shared `DesignSystem/` + `Platform/`.

---

## 3. Composition root — `AppCore`

`App/AppCore.swift` (~670 lines) is the spine: eager `let` stores, ~28
`@ObservationIgnored private(set) lazy var` coordinators (the `@ObservationIgnored` stops a lazy read
from registering an Observation dependency), and `start()` — the whole boot in one screen
(`applyEnabled()` per feature, the `observeFeatureSwitches` re-projections, the hotkey closure
wiring, deferred index/emoji/FX loads). New long-lived state goes here, wired in `start()`; it is a
singleton, not a container.

**Normative ownership rule (from [AGENTS.md](AGENTS.md), authoritative):**

> `AppCore` is the sole owner … **Views reach a feature's coordinator through `@Environment`, not
> `AppCore`.** A view must never reach past a coordinator into a store to mutate it (reading a store
> to *render* it is fine).

⚠️ **Current drift — a migration target, not the rule.** Much shipped code still injects
`@Environment(AppCore.self)` into views and calls `core.someCoordinator.foo()` as a locator
(`RootPaletteView` alone has ~24 environment injections including `AppCore`), and
[docs/architecture.md](docs/architecture.md) still *describes* that locator pattern as intended. This
contradicts the AGENTS.md non-negotiable above. Treat AGENTS.md as normative: new views should take
the specific coordinator(s) via `@Environment`, and the two docs should be reconciled. Do not cite the
locator pattern as the target design.

> One process boundary is deliberate: clipboard OCR runs out-of-process (`ClipboardTextWorker` → the
> bundled `ClipboardTextHelper`) so Vision/PDFKit allocations belong to a process that exits.

---

## 4. Entry points & windows

`TinycastApp` (`@main`) declares **only two `MenuBarExtra` scenes**; every other surface is imperative
AppKit under an `AppCore`-owned controller — the palette (`PaletteWindowController` → `PalettePanel`),
Settings/Onboarding/Support (`AppWindowController`), Notes (`NotesPanel`), dialogs
(`DialogController` — the app's **only** confirmation/prompt presenter; **`NSAlert` is never used**),
HUDs, and camera. Appearance is a setting (`.system` → `nil` so AppKit follows macOS). The exact
owner-per-window table and the reasoning live in
[docs/architecture.md](docs/architecture.md#entry-points-and-windows).

---

## 5. The palette shell (the spine of the UX)

Where a fork spends most effort. Full detail: [docs/features/palette.md](docs/features/palette.md).
Files under `Palette/`:

- **`PaletteMode`** — a flat enum (**16 cases**: `launcher`, `clipboard`, `ai`, `aiHistory`,
  `calculatorHistory`, `emoji`, `fileSearch`, `menuSearch`, `switchWindows`, `schedule`, `uninstall`,
  `quicklinks`, `snippets`, `customCommandArguments`, `extensionCommand`, `plugin`), each also
  supplying `systemImage`/`placeholder`.
- **`PaletteScreen`** — the per-mode protocol. `rows` is the single source of visible order the flat
  index addresses; a minimal screen implements ~5 of ~15 requirements (the rest default). Richer
  screens add `actions(at:)` (⌘K menu), `move(_:axis:from:)` (grid nav), `headerAccessory(…)`.
- **`RootPaletteView`** (~1500 lines, the largest file) — resolves `PaletteMode → concrete screen` in
  one big `switch`, then composes the body through two view-modifier chains (`stateObservers`,
  `keyHandlers`) split only because the type-checker can't infer one.
- **`PalettePanel`** — the real **key-routing chokepoint** in `sendEvent(_:)`: hover/⌘-held tracking →
  emacs-arrow respelling → inline ⌘K editor → menu-filter typing → **menu-open input freeze** →
  Escape/backspace/boundary-arrow/command-shortcut interception → only then SwiftUI's `onKeyPress`.
- **`MenuPanel`** — a second `NSPanel` (`canBecomeKey = false`) for every ⌘K/footer/dropdown, so the
  glass menu renders unclipped.
- **`PaletteState`** — `@Observable` session state: `mode`/`query`/`selection`, a
  `backStack: [PaletteFrame]` nav stack, and the **token pattern** (one-shot AppKit events encoded as
  `UUID` bumps SwiftUI can `.onChange` on).
- **`PaletteEscapeAction`** — a pure decision table for Escape's priority ladder; a clean extension
  point for a new escape-intercepting mode.
- The **footer** is the shared **`ActionBar`** from `TinycastPluginKit` — see [§9](#9-third-party-code-two-systems).

---

## 6. Feature anatomy

One folder per feature under `Features/<Name>/`. Large features split `Model/`/`Service/`/`UI/`/
`Settings/`; small ones stay flat. Each exposes a **`Coordinator`** (its action surface), registers
state on `AppCore`, and gates itself with an `applyEnabled()` / `apply<Feature>Presence()` method
(~16 share this shape) re-projected on settings change by `AppCore.track`. Type-suffix vocabulary:
[docs/standards.md#naming](docs/standards.md#naming).

---

## 7. The launcher & the `AppEntry.Kind` spine

Everything launchable is one `AppEntry` tagged by **`AppEntry.Kind`** (**13 cases**: `application`,
`systemSettings`, `command`, `quickAction`, `customCommand`, `snippet`, `systemAction`,
`windowCommand`, `windowLayout`, `quicklink`, `extensionCommand`, `meeting`, `plugin`). Detail:
[docs/features/launcher.md](docs/features/launcher.md).

- **`AppIndex`** (`Service/AppIndex.swift`) unions a disk-scanned app slice with ~10 synthetic slices
  pushed in by other coordinators, memoizes matching/ranking, and hands out ordered results.
  `AppEntry.Kind` + its `KindDescriptor` live here (a new case must name all descriptor fields — a
  build error until it does).
- Orthogonal preference stores keyed by `entry.preferenceKey`: `VisibilityStore`, `AliasStore`,
  `LauncherRankingStore` (frecency), `FavoritesStore`.
- **`LauncherCoordinator`** is the single activation funnel; **`AppActionsMenu`** builds the ⌘K row
  menu from kind-derived flags.

`AppEntry.Kind` **is the only thing that says what an entry is** — never re-derive a category by
sniffing an ID. Which *pane* lists a command is a separate fact, stated only in
`SettingsTab.ownedCommands`.

---

## 8. Shared layers — `DesignSystem/` and `Platform/`

Depended on by every feature, depending on none. `DesignSystem/`: `Theme.swift` is the **single
design-token source** (dark values pinned pixel-exact by `appearance-test`), `InterfaceMetrics` the
UI-scale view over it, plus shared chrome (`PopoverMenu`, `KeyCapChip`, `BarButton`) and the tuned,
off-limits `Scrolling/`. `Platform/`: system shims (`Permissions`, `AppPaths`, `NotificationToken`,
`HealthTicker`, `Signposts`, `Images/`, `Compression/`).

---

## 9. Third-party code: two systems

Two independent systems run **untrusted** third-party code and surface into the palette. They share
the hosting pattern (Manager + Coordinator + a `PaletteScreen` + a `PaletteMode` case) but differ in
*how* code is isolated — and **neither is a security sandbox**. Detail:
[docs/features/extensions.md](docs/features/extensions.md),
[docs/features/plugins.md](docs/features/plugins.md).

| | JS extensions (upstream) | Native plugins (**fork-original**) |
|---|---|---|
| Code | Raycast-format JS package | compiled Swift `.dylib` |
| Execution | **in-process** `JSContext` on a serial `DispatchQueue` | `dlopen` into the app process |
| Isolation | a **capability bridge**, not a sandbox — JS reaches Swift only through the `__tinycastHost` seam and only JSON data crosses back | none — calls Swift directly |
| Reach | broad: `ExtensionNodeShims` exposes **unrestricted filesystem** (`expandingTildeInPath`, any path) and **child processes** (`Process()` / `/bin/sh -c`) | **full app privileges** |
| Gate | install-time trust (it's the user's own package) | one-time consent dialog |
| Trust posture | **untrusted** — treat like running an npm package with your account's permissions | **untrusted** — arbitrary native code with everything the app can do |

The practical upshot: an extension is *not* safer because it's "sandboxed JS" — JSCore is in-process
and the host bridge hands it the filesystem and a shell. It is bounded only by what the bridge
chooses to expose. A native plugin is simply unbounded. Ship/enable only code you trust in both.

- **`Features/Extensions/`** — `ExtensionManager` (installed set, session state, launcher publishing)
  + `ExtensionRuntime` (the `JSContext` + `__tinycastHost`) + `ExtensionNodeShims` (the fs/proc/crypto
  surface). No Swift object crosses back to JS — only JSON.
- **`TinycastPluginKit/`** — the public framework contract, embedded so a plugin resolves the exact
  module it compiled against. It is the one module both the app *and* plugin dylibs link, so it is
  where genuinely-shared UI must live: the launcher footer is built from its **`ActionBar`** (with
  Theme-derived tokens injected as an `ActionBarStyle`). Extension chrome
  (`ExtensionActionsPanel`) is deliberately kept separate inside `Features/Extensions/` per the
  AGENTS.md isolation invariant.

---

## 10. Settings, state & backup

`AppSettings` fronts ~90 UserDefaults keys (each a computed `var` with a `didSet`); `AppSettingsKey`
enumerates them; `SettingsTab` is the pane enum with a *separate* `SettingsSection` for grouping (two
namespaces on purpose). `SettingsBackupCoverage` forces every key to be classified
`mirrored`/`externallySourced`/`deliberatelyExcluded` (test-enforced), and consent-bearing flags are
hard-excluded so an imported backup can't grant a capability. Detail:
[docs/features/backup.md](docs/features/backup.md).

---

## 11. Concurrency & observation

Swift 6 language mode; **exactly one actor** (`@MainActor`), deliberately — heavy/IO work goes off-main
as `nonisolated static` functions via `Task.detached`. Observation, not `ObservableObject`; views read
through `@Environment` (never a type annotation on `@Environment` for an `@Observable` value);
`@ObservationIgnored` on memo caches; `AppCore.track` is the willSet-safe settings-reaction pattern.
Idioms: `NotificationToken` (observer lifetime), `isolated deinit` (`ClipboardStore` SQLite), Carbon
pointers decoded before crossing into actor code, `HealthTicker` (one shared timer). Full rules:
[docs/standards.md](docs/standards.md).

---

## 12. Testing & enforcement

No XCTest target. `Scripts/run-tests.sh` declares ~85 standalone harnesses, each compiling the
**shipped** sources it guards (`swiftc … <sources> Tests/<name>.swift`) — so a `Model/` purity leak is
a compile failure. Definition of done (also in [AGENTS.md](AGENTS.md)): harnesses pass, warning-free
Debug build, `./Scripts/lint.sh` clean, the purity grep empty, and any doc your change made wrong is
fixed in the same commit. Detail: [docs/testing.md](docs/testing.md); UI changes: `UI_TESTS.md`.

---

## 13. Extension-point map

The central enums fan out across several files; adding a case means editing each. Sites are named by
symbol (not line number, which drifts). This is the practical index — and the reason [§14](#14-fork-maintenance)
weighs seams.

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

Mechanics (pristine `main` mirror, launchd fast-forward, hand-rebased `custom`, the change register)
are in [CUSTOM.md](CUSTOM.md). This is the *strategy*.

### Cost model

Every line in `git diff main..custom` is rebased by hand on every upstream release. A change across
ten files costs ten conflict sites **forever**. Push every custom need down this ladder:

1. **A JS extension** (`~/Developer/tinycast_addons/`) — zero host change, zero rebase surface. The
   default home for "a thing I want Tinycast to do." (Remember [§9](#9-third-party-code-two-systems):
   your own extensions run with your permissions; that's fine for code you wrote.)
2. **A native plugin** (also in `tinycast_addons`) — full Swift power via `TinycastPluginKit`, still
   zero *upstream-file* surface.
3. **One new fork-owned file + one call site** — when the host must change, isolate it.
4. **Direct upstream-file edits** — last resort, only when the host is genuinely wrong; add a register
   row the same commit.

### Shrink the *existing* delta first

The cheapest maintainability work is removing delta, not adding abstraction:

- **Upstream the upstreamable.** The register marks the inline alias/shortcut-editing change
  "upstreamable: yes." Landing it upstream deletes that whole row from the fork's rebase burden — a
  strictly better outcome than any seam. Do this before anything structural.
- Keep the native-plugin change (the fork's big delta) as localized as it already is; don't grow it.

### Seams — speculative, and only after proven pain

A survey suggested data-driven registries (e.g. `[PaletteMode: Descriptor]`) to collapse the fan-outs
in [§13](#13-extension-point-map). **Do not treat these as the recommended first move.** They fight
the project's own rule — *no abstraction until it removes more complexity than it adds*
([docs/standards.md](docs/standards.md#simplicity-and-maintainability)) — and they buy less than they
look like:

- A `PaletteMode` registry **still requires editing the closed `PaletteMode` enum** to add `.plugin`,
  so it does not remove the enum edit — it only trades a compiler-*exhaustive* `switch` for a runtime
  table + factory indirection.
- If the fork lands a registry that upstream doesn't have, that rewrite **is** a large permanent
  conflict against every upstream edit to `RootPaletteView` — worse than today's scattered edits.

So: extract a seam only **(a)** after repeated *real* rebase conflicts at that exact site prove it
pays, and **(b)** as an **upstream PR first** — a registry helps the fork only if upstream adopts it.
Until both hold, prefer ladder steps 1–3 and minimal, local host edits.

### Efficiency

The codebase is disciplined (memoization, <100 MB resident, baseline after palette close —
[docs/standards.md#performance-and-memory](docs/standards.md#performance-and-memory)), and its own
rule is **measure before optimising, and measure before caching**. Nothing here is a known win.
Candidates *to profile* — not to change on sight:

- `LauncherList.rows` regroups a `[Kind: [AppEntry]]` dictionary per render. `LauncherList` is a
  transient SwiftUI value view, so caching that would add invalidation machinery for every change to
  `results`/favorites/card/fallbacks/section-mode; the one-pass grouping may well be cheaper and
  safer. Profile before assuming the cache pays.
- Deliberate trade-offs to leave alone unless a profile says otherwise: cache purge on `hide()`,
  main-actor SQLite within a 1000-row window, the serialized JS queue.

---

## Where to go next

- Wiring/ownership → [docs/architecture.md](docs/architecture.md) · writing Swift →
  [docs/standards.md](docs/standards.md) · one feature → its
  [docs/features/](docs/features/) doc · done-ness → [docs/testing.md](docs/testing.md) + `UI_TESTS.md`
  · the fork → [CUSTOM.md](CUSTOM.md).
