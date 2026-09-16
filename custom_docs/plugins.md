# Native plugins

Tinycast loads **native Swift plugins** — compiled dynamic libraries that render into the command
palette with SwiftUI. This is separate from [extensions](../docs/features/extensions.md), which run
Raycast's JavaScript in JavaScriptCore. A plugin is first-party Swift the user builds and trusts.

**Trust model.** A plugin runs **in-process, unsandboxed, with the app's full privileges**
(Accessibility, Automation, the lot) — the same trust model BetterTouchTool states for its Swift
plugins. Only install plugins whose source you have read. Because of that: `pluginsEnabled`
defaults off, confirms before it turns on, and never rides a settings backup (importing one can
never silently arm plugin loading); the app ships the
`com.apple.security.cs.disable-library-validation` entitlement so a user-built, ad-hoc-signed dylib
can load under the hardened runtime.

> This is a fork-local feature. See [CUSTOM.md](CUSTOM.md) for how it is carried and where
> plugin sources live.

## Invariants

- **The contract is the framework, and there is exactly one copy.** `TinycastPluginKit.framework`
  is built by this project and embedded in the app. A plugin links *that* framework — never a
  vendored copy — so a plugin's `TinycastPlugin` and the host's are the **same** type across the
  `dlopen` boundary. Two copies would give two unrelated protocols and every cast would fail.
- **A plugin is prebuilt, never compiled by the app.** The app `dlopen`s a finished `.dylib`; it
  never shells out to `swiftc`. This mirrors extensions ("run `ray build` first").
- **`PluginManager` is the sole owner of the running session**, wired on `AppCore` in `start()`.
  It never touches a window; `PluginCoordinator` owns every palette move.
- **A plugin surfaces as exactly one launcher row** (`AppEntry.Kind.plugin`). Activating it enters
  `PaletteMode.plugin`, where the plugin owns the whole screen. Its own rows, children and surfaces
  live inside that mode — they never leak into the root launcher index.
- **The API layer may use SwiftUI.** `TinycastPluginKit` is not under `Features/*/Model/`, so the
  purity rule does not apply — `PluginResult`/`PluginContext` are still Foundation-only value types,
  but the contract vends `AnyView`.

## How it fits together

```
┌ Plugin dylib (built by the author) ──────────────────────────────┐
│  final class MyPlugin: NSObject, TinycastPlugin { … }             │
│  @_cdecl("tinycastPluginCreate") -> TinycastPluginRuntime.export  │
│  links → @rpath/TinycastPluginKit.framework                       │
└───────────────────────────────┬──────────────────────────────────┘
                                 │ dlopen + dlsym("tinycastPluginCreate")
┌ Host (Tinycast) ──────────────▼──────────────────────────────────┐
│ PluginLoader   dlopen, cast the opaque pointer to TinycastPlugin  │
│ PluginCatalog  scans …/plugins/<name>/manifest.json → PluginInstall│
│ PluginManager  @Observable session: rows, children, surface, run  │
│ PluginScreen   a PaletteScreen; hosts the plugin's list or AnyView │
│ PluginCoordinator  launch, navigate, exit, consent, uninstall     │
│ AppIndex.setPluginCommands → one AppEntry(.plugin) per install     │
└───────────────────────────────────────────────────────────────────┘
```

Files: `TinycastPluginKit/` (the framework), `Tinycast/Features/Plugins/` (the host feature).

Installed plugins live at `~/Library/Application Support/<bundle id>/plugins/<name>/`, each a
folder with a `manifest.json` and the dylib it names. The bundle id is per channel — `Tinycast
Dev.app` is `com.tinycast.app.dev`, a release build is `com.tinycast.app` — so a dev build never
shares plugins with a release build.

## The plugin contract

`import TinycastPluginKit`. The full surface:

```swift
@MainActor public protocol TinycastPlugin: AnyObject {
    init()
    static var metadata: PluginMetadata { get }
    func rootSurface(context: PluginContext) -> AnyView?                                   // default: nil
    func results(for context: PluginContext) -> [PluginResult]                            // default: []
    func children(of resultID: String, context: PluginContext) async -> [PluginResult]   // default: []
    func perform(resultID: String, context: PluginContext) async -> PluginActionResult    // default: .close
    func surface(for resultID: String, context: PluginContext) -> AnyView                 // default: EmptyView
}
```

- `PluginMetadata(name:subtitle:icon:)` — the launcher row's title, subtitle and SF Symbol.
- `PluginContext` — `query` (the live palette text), `frontmostAppBundleID`, `finderSelection`.
- `PluginResult(id:title:subtitle:trailingText:icon:keywords:action:)` — one row.
  - `PluginIcon` — `.symbol(String)` or `.file(URL)`.
  - `PluginAction` — what activating the row does:
    - `.run(id:)` → the host calls `perform`, honours `PluginActionResult(closesLauncher:message:)`.
    - `.children(id:)` → the host calls `children` and pushes the returned rows.
    - `.surface(id:)` → the host shows your SwiftUI view as the **whole panel**: the palette hides
      its own header, footer and drag strip, so the surface draws its own chrome if it wants any.
    - `.openURL(URL)` → the host opens it and closes the launcher.
    - `.none` → inert.

`results(for:)` is re-asked on every keystroke — filter on `context.query` yourself. Pushed child
lists are filtered by the host. A surface owns the entire panel and its own keyboard: wrap it in a
`PluginScaffold` (below), which claims Escape, ⌘K and the list keys through a local monitor ahead of
the host, so navigation never depends on which control holds first responder.

**A surface-only plugin** returns a view from `rootSurface(context:)` and opens straight into it —
no root row list, no `results(for:)`. The whole plugin is that one SwiftUI screen (see the
stock-quotes plugin). Return nil to keep the row model instead; a plugin does one or the other.

### A surface's scaffold

A `.surface` owns the whole panel, so the framework hands it the chrome the host no longer draws.
Wrap the surface's body in
`PluginScaffold(navigator:primaryActionLabel:commands:commandTitle:listKey:) { root }`:

- `PluginNavigator` — the surface's own view stack. `push(title:_:)` drills in; **Escape** pops it,
  and at the root Escape leaves the plugin (the scaffold calls the host-injected
  `EnvironmentValues.pluginExit`). No back chevron to wire, and no Escape monitor to install.
- `commands:` / `commandTitle:` — the `[PluginCommand]` and heading for the **⌘K** palette pinned
  bottom-right. `PluginCommand(title:subtitle:icon:shortcut:action:)`; re-read each time it opens.
- `listKey:` — `↑/↓/←/→/Return` (`PluginListKey`) for a list on the current view, read from the
  scaffold's own monitor so it works whatever holds focus. Return true when you consumed the key;
  ←/→ can drive a second axis, or fall through to the search caret when you return false.
- `escape:` — **Escape**, offered to the surface before the stack pops and before the plugin is
  left, so a surface unwinds a step at a time: a live search clears back to its list, and only then
  does a further press go back or out. Return true when you consumed it.
- A **bare backspace** is the surface's own: everywhere else in the palette it takes Escape's back
  step once the query is empty, but a surface owns its search field and the host cannot see whether
  that field still holds text, so the key is left to it. Escape is the way back out. A plugin still
  on the row model keeps the palette's rule, stepping back one of its own list levels per press.

The scaffold's footer is the shared `ActionBar` from `TinycastPluginKit` — the same bar the launcher
and JS extensions render (the app builds it in `RootPaletteView.bottomBar` with a Theme-derived
`ActionBarStyle`; the scaffold uses the default). `.standard` fills it from the surface's Back state,
`primaryActionLabel` and commands; a surface passes `footer: .hidden` for a full-bleed view or
`.custom { AnyView(…) }` to draw its own. It floats over a bottom fade so content dissolves under it
— give scroll views `.contentMargins(.bottom, …)` so the last row clears it.

The full authoring guide — focus/layout gotchas and a worked example — lives beside the plugins:
`tinycast_addons/extensions/SWIFT_PLUGINS.md`. The worked row-model example is
[`hello-plugin`](../../tinycast_addons/extensions/hello-plugin/) — a run action, a drill-in child
list, a SwiftUI surface and an external link, all in one plugin. The worked surface-only example is
[`stock-quotes-plugin`](../../tinycast_addons/extensions/stock-quotes-plugin/).

## Build a plugin

Compile against the **build-products** `TinycastPluginKit.framework`, not the copy embedded in the
app — Xcode strips its Swift `Modules/` on embed. Build Tinycast once to produce a compilable copy:

```sh
cd ~/Developer/tinycast
xcodebuild -project Tinycast.xcodeproj -scheme Tinycast -configuration Debug \
    -derivedDataPath build/DerivedData build
```

| | Path |
|---|---|
| Framework to compile against | `build/DerivedData/Build/Products/Debug/TinycastPluginKit.framework` |
| The app to load into | `build/DerivedData/Build/Products/Debug/Tinycast Dev.app` (`com.tinycast.app.dev`) |

Verify the framework carries its module (the thing that trips people up) — if this path is
missing, you're looking at a stripped copy; rebuild Tinycast:

```sh
ls "$HOME/Developer/tinycast/build/DerivedData/Build/Products/Debug/TinycastPluginKit.framework/Versions/A/Modules/TinycastPluginKit.swiftmodule"
```

**Folder layout** (anywhere; the shipped samples live in `tinycast_addons/extensions/`):

```
my-plugin/
├── Sources/MyPlugin/MyPlugin.swift
├── manifest.json
└── build.sh
```

**A minimal plugin** — a surface-only shape (`Sources/MyPlugin/MyPlugin.swift`):

```swift
import AppKit
import SwiftUI
import TinycastPluginKit

final class MyPlugin: NSObject, TinycastPlugin {
    static let metadata = PluginMetadata(name: "My Plugin", subtitle: "A native SwiftUI plugin", icon: "star")

    // NSObject's init() does not satisfy the protocol requirement on its own — declare it.
    override init() { super.init() }

    // Return a view to open straight into a full-panel SwiftUI surface.
    func rootSurface(context: PluginContext) -> AnyView? {
        AnyView(RootView())
    }
}

private struct RootView: View {
    @State private var navigator = PluginNavigator()

    var body: some View {
        // PluginScaffold gives you the shared footer, Escape-to-back, a ⌘K palette
        // and focus-independent list navigation. A surface owns the whole panel.
        PluginScaffold(navigator: navigator, primaryActionLabel: "") {
            Text("Hello from a native plugin")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// The host's only entry point — export exactly this symbol, verbatim.
@_cdecl("tinycastPluginCreate")
public func tinycastPluginCreate() -> UnsafeMutableRawPointer {
    TinycastPluginRuntime.export { MyPlugin() }
}
```

For the row-model shape instead, implement `results(for:)` and `perform(resultID:context:)` per
the contract above — see `hello-plugin`.

**The manifest** (`manifest.json`) — the launcher row's identity and the dylib it loads:

```json
{
  "name": "My Plugin",
  "identifier": "com.example.my",
  "subtitle": "A native SwiftUI plugin",
  "icon": "star",
  "dylib": "libMyPlugin.dylib"
}
```

`icon` is an SF Symbol name; `dylib` must match the file `build.sh` produces.

**The build script.** One `swiftc` line, wrapped in a `build.sh`
([see the sample's](../../tinycast_addons/extensions/hello-plugin/build.sh)). Two subtleties it
handles:

- **`-F` points at the build-products framework** (the one with `Modules/`), never the app's copy.
- **`-rpath @executable_path/../Frameworks`** — in a `dlopen`ed dylib, `@executable_path` is the
  *host* (Tinycast) executable, so this resolves the plugin's `@rpath` framework dependency to the
  framework already loaded inside the app. No second copy is loaded.

```sh
#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

NAME="MyPlugin"
DYLIB="libMyPlugin.dylib"
APP="${TINYCAST_APP:-$HOME/Developer/tinycast/build/DerivedData/Build/Products/Debug/Tinycast Dev.app}"
FW="${TINYCAST_FRAMEWORKS:-$HOME/Developer/tinycast/build/DerivedData/Build/Products/Debug}"

mkdir -p build
swiftc -emit-library -O \
  -module-name "$NAME" \
  -F "$FW" -framework TinycastPluginKit \
  -Xlinker -rpath -Xlinker "@executable_path/../Frameworks" \
  -o "build/$DYLIB" \
  Sources/MyPlugin/*.swift

# Ad-hoc sign so the hardened runtime will load it (the host disables library validation).
codesign --force --sign - "build/$DYLIB"
echo "built build/$DYLIB"

if [[ "${1:-}" == "install" ]]; then
  BID="$(defaults read "$APP/Contents/Info" CFBundleIdentifier)"
  DEST="$HOME/Library/Application Support/$BID/plugins/my-plugin"
  mkdir -p "$DEST"
  cp "build/$DYLIB" manifest.json "$DEST/"
  echo "installed to $DEST"
fi
```

**Build, install, enable, run:**

```sh
chmod +x build.sh
./build.sh            # -> build/libMyPlugin.dylib, ad-hoc signed
./build.sh install    # copies dylib + manifest.json into the per-channel plugins folder
```

Open Tinycast → **Settings → Plugins** and turn plugins on (it confirms the first time — plugins
are unsandboxed native code), then summon the palette and search for the plugin by name.
Activating its row enters the plugin's own mode, where it owns the whole screen.

## Installing while Tinycast runs

`PluginManager` watches the plugins folder with a `DispatchSourceFileSystemObject` (the same idiom
as `SnippetsStore`), so a plugin dropped in — e.g. by `build.sh install` — appears in the launcher
within a moment, no relaunch needed. The rescan is debounced, so a burst of file copies from one
install collapses into a single refresh.

The one case a restart is still required: **updating a plugin that is already loaded.** Once a
plugin has been launched this session its dylib is mapped, and `dlopen` reference-counts —
rebuilding the same path won't replace the running image. Quit and reopen Tinycast to pick up a
rebuilt dylib.

## Pop-out windows

A plugin surface can be **popped out into its own standalone window** — the ⌘K palette's **Pop Out**
command, beside Add to Main Menu. The window renders only the plugin's own view — no palette header,
footer or scaffold — over the same backdrop the launcher draws. It is borderless, resizable, moved by
dragging its background and closed with ⌘W; a bottom-right ⌘K palette carries its window controls
(show on all spaces, keep in front, close).

Each pop-out loads its **own** plugin instance, independent of the palette's running session and of
every other window, so several float at once — keyed by `PluginRoute`, so an ADBE chart and an MSFT
chart are distinct windows.

Opt a surface into a bare window body by reading `PluginContext.presentation`:

```swift
func rootSurface(context: PluginContext) -> AnyView? {
    if context.presentation == .window {
        return AnyView(MyChart(route: context.route))   // bare — no PluginScaffold
    }
    return AnyView(MySurface(…))                          // in-palette: wrap in PluginScaffold
}
```

`.window` needs a `PluginRoute` (the scaffold's `route:` closure), which both identifies the window
and restores its content; a surface with no route offers no Pop Out.

## Troubleshooting

| Symptom | Cause & fix |
|---|---|
| `swiftc` error: no such module `TinycastPluginKit` | `-F` points at the stripped app copy. Point it at the build-products `TinycastPluginKit.framework` (the one with `Modules/`), or rebuild Tinycast. |
| Plugin row never appears | Plugins disabled (Settings → Plugins), or `manifest.json`/dylib not in `…/Application Support/<bundle id>/plugins/<name>/`, or `dylib` in the manifest doesn't match the built filename. |
| Loads but casts fail / crashes at launch | A vendored/duplicate `TinycastPluginKit` was linked. There must be exactly one framework across the `dlopen` boundary — always the build-products copy. |
| Rebuild has no effect | The old dylib is still mapped. Quit and reopen Tinycast (see above). |
| Won't load under the hardened runtime | The dylib isn't signed. `codesign --force --sign - build/libMyPlugin.dylib` (the build script does this). |
