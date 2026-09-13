# Native plugins

Tinycast loads **native Swift plugins** — compiled dynamic libraries that render into the command
palette with SwiftUI. This is separate from [extensions](extensions.md), which run Raycast's
JavaScript in JavaScriptCore. A plugin is first-party Swift the user builds and trusts; it runs
**in-process, unsandboxed, with the app's full privileges**.

> This is a fork-local feature. See [CUSTOM.md](../../CUSTOM.md) for how it is carried and where
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
- **Loading needs consent and an entitlement.** `pluginsEnabled` defaults off, confirms before it
  turns on, and never rides a settings backup. The app ships
  `com.apple.security.cs.disable-library-validation` so a user-built dylib can load under the
  hardened runtime.
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

Installed plugins live at `~/Library/Application Support/<bundle id>/plugins/<name>/`, each a folder
with a `manifest.json` and the dylib it names. The bundle id is per channel, so `Tinycast Dev.app`
(`com.tinycast.app.dev`) never shares plugins with a release build.

## The plugin contract

`import TinycastPluginKit`. The full surface:

```swift
@MainActor public protocol TinycastPlugin: AnyObject {
    init()
    static var metadata: PluginMetadata { get }
    func results(for context: PluginContext) -> [PluginResult]
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
    - `.surface(id:)` → the host calls `surface` and shows your SwiftUI view full-screen.
    - `.openURL(URL)` → the host opens it and closes the launcher.
    - `.none` → inert.

`results(for:)` is re-asked on every keystroke — filter on `context.query` yourself. Pushed child
lists are filtered by the host. A surface owns the keyboard; Escape pops back out.

## Writing a plugin

The worked example is [`hello-plugin`](../../../tinycast_addons/extensions/hello-plugin/) — it shows
a run action, a drill-in child list, a SwiftUI surface and an external link. The shape:

```swift
import AppKit
import SwiftUI
import TinycastPluginKit

final class MyPlugin: NSObject, TinycastPlugin {
    static let metadata = PluginMetadata(name: "My Plugin", subtitle: "…", icon: "star")

    // NSObject's init() does not satisfy the protocol requirement on its own — declare it.
    override init() { super.init() }

    func results(for context: PluginContext) -> [PluginResult] {
        [PluginResult(id: "hi", title: "Say Hi", action: .run(id: "hi"))]
            .filter { context.query.isEmpty || $0.title.localizedCaseInsensitiveContains(context.query) }
    }

    func perform(resultID: String, context: PluginContext) async -> PluginActionResult {
        .init(closesLauncher: true, message: "Hi!")
    }
}

// Every plugin exports exactly this symbol; it is the host's only entry point.
@_cdecl("tinycastPluginCreate")
public func tinycastPluginCreate() -> UnsafeMutableRawPointer {
    TinycastPluginRuntime.export { MyPlugin() }
}
```

### Build, install, run

Plugins are built with one `swiftc` line, wrapped in a `build.sh`
([see the sample's](../../../tinycast_addons/extensions/hello-plugin/build.sh)):

```sh
swiftc -emit-library -O -module-name MyPlugin \
  -F "<framework-dir>" -framework TinycastPluginKit \
  -Xlinker -rpath -Xlinker "@executable_path/../Frameworks" \
  -o build/libMyPlugin.dylib Sources/MyPlugin/*.swift
codesign --force --sign - build/libMyPlugin.dylib
```

Two subtleties the sample handles for you:

- **Compile against a framework that still has its `Modules/`.** Xcode strips the Swift module from
  the copy embedded in the `.app`, so compile against the **build-products** framework
  (`…/DerivedData/Build/Products/Debug/TinycastPluginKit.framework`), not the one inside the app.
- **`@executable_path/../Frameworks` is the runtime rpath.** In a `dlopen`ed dylib, `@executable_path`
  is the *host* (Tinycast) executable, so this resolves the plugin's `@rpath` framework dependency to
  the already-loaded framework inside the app.

Then drop `manifest.json` + the dylib into
`~/Library/Application Support/<bundle id>/plugins/<name>/` (the sample's `./build.sh install` does
this), enable plugins in **Settings → Plugins**, and search for the plugin by name.

```json
{ "name": "My Plugin", "identifier": "com.example.my", "icon": "star", "dylib": "libMyPlugin.dylib" }
```

## Installing while Tinycast runs

`PluginManager` watches the plugins folder with a `DispatchSourceFileSystemObject` (the same idiom
as `SnippetsStore`), so a plugin dropped in — e.g. by `build.sh install` — appears in the launcher
within a moment, no relaunch needed. The rescan is debounced, so a burst of file copies from one
install collapses into a single refresh.

The one case a restart is still required: **updating a plugin that is already loaded.** Once a
plugin has been launched this session its dylib is mapped, and `dlopen` reference-counts — rebuilding
the same path won't replace the running image. Quit and reopen Tinycast to pick up a rebuilt dylib.

## Security

A plugin is native code loaded into Tinycast's process: it inherits every permission Tinycast holds
(Accessibility, Automation) and is not sandboxed — the same trust model BetterTouchTool states for
its Swift plugins. `pluginsEnabled` therefore confirms before turning on and is excluded from
settings backups, so importing a backup can never silently arm plugin loading. Only install plugins
whose source you have read.
