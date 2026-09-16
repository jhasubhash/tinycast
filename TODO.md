# TODO — Pluggable Assistants (P8–P9)

The `AssistantPlugin` / `AssistantSession` **public ABI + host integration** — the deferred track that
lets a native Swift plugin provide an Assistant with its **own SwiftUI chat surface and custom
behaviour**, instead of a configured (standard-UI) assistant.

**Status:** design locked; not started. Configured assistants (P1–P7) shipped and verified.
**Design of record:** [`Assistant_Architecture.md`](Assistant_Architecture.md) §19 (§19.1–§19.7).
**Depends on:** the shipped assistant machinery (P1–P7) and the existing native plugin system
([`docs/features/plugins.md`](docs/features/plugins.md)) — a prebuilt, trusted, in-process `.dylib`
linking `TinycastPluginKit.framework`.

## Guiding invariants (do not break)

- **The bridge is the framework, one copy.** A plugin talks to the AI *only* through `AssistantSession`
  and its value types; it never imports or links the host's AI types (`AIChatState`, provider layer).
  Same-type-across-`dlopen` guarantee as `TinycastPlugin`.
- **A plugin assistant is a normal `Assistant` host-side** — persisted shortcut, placement, width,
  scoped history, retention. So `provider == .configured` and `activeAssistant == nil` (the default
  bar) stay byte-for-byte untouched. Same regression firewall as P1–P7.
- **Native-code consent gates it:** needs **both** `aiEnabled` **and** `pluginsEnabled`. Nothing is
  ever armed by importing a backup (assistants + `pluginsEnabled` are already backup-excluded).
- **Removing a plugin never drops its assistants' config** — kept, greyed, restorable.

## Already in place (from P1–P7 — reuse, don't rebuild)

- `AssistantProvider.plugin(pluginID:, descriptorID:)` + `Assistant.isPlugin`
  (`Tinycast/Features/AI/Model/Assistant.swift`).
- Assistant machinery a plugin assistant reuses wholesale: `HotKeyAction.assistant(id:)`,
  per-display placement/width, `ChatHistoryStore` scope + ephemeral, `AppEntry.Kind.assistant`
  launcher command, `AIChatCoordinator.openAssistant(id:)` / `activeAssistant` / `effectiveProvider`.
- Existing plugin surface-hosting to mirror: `TinycastPlugin.surface(for:context:)`,
  `PluginPresentation`, `PluginManager` `.surface` levels
  (`Tinycast/Features/Plugins/Service/PluginManager.swift`), `PluginScreen`
  (`Tinycast/Features/Plugins/UI/`).

---

## Phase 8 — The contract + host bridge

### 8.1 `TinycastPluginKit` additions (`TinycastPluginKit/TinycastPluginKit.swift`)

- [ ] `public protocol AssistantPlugin: TinycastPlugin` with:
  - [ ] `static var assistants: [AssistantDescriptor] { get }` — read the moment the dylib loads
        (like `PluginMetadata`), so the host lists the assistant before paying for its code.
  - [ ] `func assistantSurface(id: String, session: any AssistantSession, context: PluginContext) -> AnyView`.
- [ ] `public struct AssistantDescriptor: Sendable, Equatable` — `id` (stable within plugin), `name`,
      `icon: PluginIcon`, `defaultSystemPrompt: String?` (seeds host config), `suggestedModel: String?`.
- [ ] `@MainActor @Observable public protocol AssistantSession: AnyObject`:
  - [ ] `var messages: [AssistantMessage] { get }`, `var isStreaming: Bool { get }`,
        `var model: AssistantModel { get }`.
  - [ ] `func send(_ text: String)`, `func send(_ text: String, instructions: String?, tools: [AssistantTool])`,
        `func stop()`, `func newChat()`, `func openChat(id: UUID)`.
- [ ] Value types: `AssistantMessage` (role, text, state, id — `Sendable, Identifiable, Equatable`),
      `AssistantModel` (id, name, supportsTools, supportsImages), `AssistantTool`
      (name, description, jsonSchema, `invoke: @Sendable (String) async -> String`).
- [ ] Bump the framework/ABI version if the plugin kit versions its contract; keep it purely additive
      so existing `TinycastPlugin`-only plugins are unaffected.

### 8.2 Host bridge — `AssistantSessionBridge`

- [ ] New `@MainActor @Observable` host type implementing `AssistantSession` over the scoped
      `AIChatState` + `AIChatCoordinator` (its model, history, retention).
- [ ] Map host → framework value types (`ChatMessage` → `AssistantMessage`, resolved route →
      `AssistantModel`) at the boundary — never leak host AI types across `dlopen`.
- [ ] `send(_:instructions:tools:)`: layer the plugin's `AssistantTool`s onto the existing
      `AIToolLoopProvider` and override the composed instructions **for that turn only**.
- [ ] `stop` / `newChat` / `openChat(id:)` forward to the coordinator's existing methods.

### 8.3 Sample plugin (in `tinycast_addons`, **outside this repo** — see CUSTOM.md)

- [ ] A minimal `AssistantPlugin` conforming addon: one descriptor, a bespoke SwiftUI surface that
      drives `session.send`, renders `session.messages`, and shows one custom `AssistantTool`.
- [ ] Serves as the manual-verification vehicle for Phase 9.

### 8.4 Phase 8 verification

- [ ] `AssistantSessionBridge` unit coverage (extend `assistant-test` or a focused harness): message
      mapping, streaming state, tool layering, instruction override scoped to one turn.
- [ ] Framework compiles standalone; no host AI type crosses the boundary (grep the kit for host imports).

---

## Phase 9 — Host integration (discovery, materialise, render)

### 9.1 Discovery (`Tinycast/Features/Plugins/Service/PluginManager.swift`)

- [ ] On dylib load, also `plugin as? AssistantPlugin` and read `static assistants`.
- [ ] Surface the descriptors to the assistant layer (a callback/registry the AI side observes).

### 9.2 Materialise plugin-backed `Assistant`s (`AssistantStore` + AI wiring)

- [ ] For each descriptor, materialise/persist an `Assistant` with
      `provider = .plugin(pluginID:, descriptorID:)`, seeded from the descriptor
      (name, icon, `defaultSystemPrompt`, `suggestedModel`) — a first-class Assistant with its own
      shortcut, placement, width, history scope, retention.
- [ ] **Removing the plugin greys its assistants (kept, restorable)** — never drops their config.
      Add an "available/greyed" notion keyed by whether the plugin is currently loaded.

### 9.3 Render the plugin surface (palette)

- [ ] `RootPaletteView` / palette body: when the active assistant `isPlugin`, render the plugin's
      `assistantSurface(id:session:context:)` instead of `AIScreen` — hosted like the existing
      `.surface` path (`hidesSearchField`, plugin owns the panel; may wrap `PluginScaffold` or draw bare).
- [ ] Build the `AssistantSessionBridge` from the scoped `AIChatState`/coordinator and inject it.
- [ ] Placement, growth direction and width come from the `Assistant` config exactly as configured.

### 9.4 Settings

- [ ] `AssistantsSettingsSection` / `AssistantEditorSheet`: show plugin assistants badged
      **"provided by <plugin>"**; plugin-owned fields (prompt/skills/MCP the plugin owns) **read-only**,
      host fields (shortcut, placement, model where allowed, retention, ephemeral) editable.

### 9.5 Security & consent

- [ ] Gate on **both** `aiEnabled` and `pluginsEnabled`; a plugin assistant runs nothing (no summon,
      no materialise) unless both are on.

### 9.6 Phase 9 verification (driven UI)

- [ ] Load the sample addon → its assistant appears in the Assistants list, badged, with a bindable
      shortcut.
- [ ] Summon it → the **plugin's own SwiftUI surface** renders in the bar; `send` streams through the
      bridge; the custom `AssistantTool` is callable.
- [ ] Remove the plugin → its assistant greys, config retained; re-add → restored.
- [ ] Firewall: default bar (`activeAssistant == nil`) and configured assistants unchanged.
- [ ] `./Scripts/run-tests.sh`, Debug build warning-free, `./Scripts/lint.sh` clean.

---

## Docs / register (at commit time)

- [ ] `docs/features/ai.md` — extend the **Assistants** section with the plugin-assistant kind + bridge.
- [ ] `docs/features/plugins.md` — the `AssistantPlugin` opt-in.
- [ ] `CUSTOM.md` — register row (fork change); `tinycast_addons` sample noted there.

## Open items / future (from §18)

- Progressive-disclosure skills (inject name+description; model pulls the body via a tool) —
  API-routes-only, needs tool support.

---

# TODO — Codex CLI shell tools (per-assistant)

Claude's **Allow shell tools** opt-in works: the `claude -p` route runs shell commands
(`--dangerously-skip-permissions`) with the assistant's `AssistantSecretStore` environment, so a
script-based Skill (e.g. Jira's `jira_query.py`) executes. **Codex does not** — its shell is disabled
at the app-server *launch*, so a Codex assistant with a script Skill can't run it and improvises
(e.g. browses the Jira web UI instead of using `$JIRA_TOKEN`).

**Root cause:** `CodexAppServerClient.start()` launches one shared, long-lived `codex app-server` with
`-c features.shell_tool=false` (plus `unified_exec`, `browser_use`, … all `=false`). A launch flag —
no thread can re-enable the tool. The client is shared with the default Codex bar and every normal
Codex assistant, so it must stay sandboxed.

## Plan

- [ ] Spawn a **dedicated, isolated `CodexAppServerClient`** for shell-tools assistants — launched
      **with** `shell_tool` (and whatever `unified_exec` needs) enabled, a **`workspace-write`** (or
      full-access) sandbox, and the assistant's **environment** merged into the process env.
- [ ] Route a shell-tools Codex turn (`AICLIToolConfig.allowShell == true`) to that instance;
      keep `activeAssistant == nil` and non-shell assistants on the existing sandboxed shared client.
- [ ] Thread `thread/start` sandbox → `workspace-write`, `turn/start` sandboxPolicy → writable +
      `networkAccess: true`, and `declineServerRequest` → **approve** command-execution requests only
      for that instance.
- [ ] Lifecycle: ephemeral per-turn or per-assistant; tear down cleanly; never leave an
      un-sandboxed Codex process resident.
- [ ] Verify with a real Codex login that a script Skill runs via shell + env, and the default bar
      stays sandboxed. Update the editor's shell-tools footer (currently "Claude CLI only").

**Risk:** a second, deliberately un-sandboxed `codex` process runs arbitrary shell with the user's
login while such an assistant is active. Same accepted-risk posture as Claude's shell opt-in.

---

# TODO — Palette closes to the wrong Space (empty-Space summon)

Summoning the palette on a Space that has **no focused window** (a fresh/empty desktop Space), then
closing it, snaps the desktop back to the Space where a window was last selected.

**Repro:** switch to an empty Space → summon the palette → dismiss it → macOS returns to the previous
Space.

**Diagnosed cause (partial):** the palette is a `.nonactivatingPanel`, so summoning never changes the
frontmost app. On an empty Space `NSWorkspace.shared.frontmostApplication` is still the app whose
window lives on the *previous* Space, and `PaletteWindowController.hide(restoreFocus:)` calls
`previousApp?.activate()`, which raises that app's window on its own Space — the jump.

**Tried, did NOT fix:** guarding the `activate()` to fire "only if `previousApp` is no longer
frontmost". The Space still changed on hide — so either `previousApp` isn't frontmost at hide time
(guard passes, `activate()` still fires) or something other than `activate()` drives the switch
(`orderOut` of a `.canJoinAllSpaces` panel, focus hand-back). Reverted; needs live multi-Space
instrumentation to pin down which app is frontmost at hide and whether `orderOut` alone switches.

**Note:** other launchers (Raycast/Alfred-class) show the same behaviour — likely a macOS
window-server quirk, not obviously a Tinycast-only bug. Low priority.

**Verification when fixed (driven, multi-Space):** empty Space → summon + dismiss stays put; Space
with a focused window → dismiss still returns focus to that window; secondary-monitor +
`openOnCursorScreen` placement unaffected.
