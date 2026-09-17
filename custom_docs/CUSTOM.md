# Custom fork

This checkout is **`jhasubhash/tinycast`**, a fork of **`abue-ammar/tinycast`**. Everything upstream
says still applies — [AGENTS.md](../AGENTS.md) and [docs/](../docs/README.md) are unchanged and
authoritative. This file covers only what is true *here*: the branch model, the local build and
signing setup, how to pull upstream in, and the register of changes this fork carries.

**Read this before your first commit.** The fork lives on a **single branch, `main`** — commit to it
directly. There is no `custom` branch and no sync automation; both were removed.

## Layout

| | |
| --- | --- |
| Checkout | `~/Developer/tinycast` |
| `origin` | `https://github.com/jhasubhash/tinycast` |
| `upstream` | `https://github.com/abue-ammar/tinycast.git` (push URL `DISABLED` on purpose) |

## Branch model

`main` holds everything — upstream history plus this fork's commits — and is what gets built and
pushed to `origin`. `upstream/main` is the pristine upstream ref, so `git log upstream/main..main` is
exactly this fork's delta, which the register below mirrors.

## Pulling in upstream

No automation — do it by hand:

```sh
git fetch upstream
git merge upstream/main
# resolve, then rebuild — a clean merge is not a working build
xcodebuild -project Tinycast.xcodeproj -scheme Tinycast -configuration Debug \
    -derivedDataPath build/DerivedData build
./Scripts/run-tests.sh
git push origin main
```

Merge, not rebase: it keeps every original commit SHA so the push stays an ordinary fast-forward.
`git rerere` is on, so a resolution recorded once replays next merge. Push as `jhasubhash` — the active
`gh` account may differ.

## Local build and signing

Base instructions: [docs/development.md](../docs/development.md), [docs/signing.md](../docs/signing.md).
Two things specific to *this* machine:

**`openssl pkcs12 -export` fails on OpenSSL 3** (`MAC verification failed during PKCS12 import`) —
OpenSSL 3's default MAC is unreadable by `security import`. The `Tinycast Self-Signed` identity was
created with legacy algorithms:

```sh
openssl pkcs12 -export -legacy -macalg sha1 \
  -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES \
  -inkey /tmp/tc-key.pem -in /tmp/tc-cert.pem \
  -name "Tinycast Self-Signed" -out /tmp/tc.p12 -passout pass:tinycast
```

`security find-identity -p codesigning` reports it `CSSMERR_TP_NOT_TRUSTED` — expected and harmless
for a self-signed cert; `codesign` and `codesign --verify --deep --strict` both accept it.

**Build and run:**

```sh
xcodebuild -project Tinycast.xcodeproj -scheme Tinycast -configuration Debug \
    -derivedDataPath build/DerivedData build
open "build/DerivedData/Build/Products/Debug/Tinycast Dev.app"
```

Or `open Tinycast.xcodeproj` and ⌘R. Debug is its own channel — `Tinycast Dev.app`,
`com.tinycast.app.dev`, with its own prefs, caches and TCC grants — so it can't see or clobber an
installed Tinycast. It starts with no hotkeys bound; record one in Settings → General.

**After a rebuild, quit and relaunch a running `Tinycast Dev` — a stale instance is not harmless.**
The extension JS runtime (`Resources/RaycastRuntime.generated.js`) and its Swift host
(`Features/Extensions/Service/`) ship as one matched pair and change together (upstream `#697` reworked
async `exec`/`execFile` across both sides). Rebuild under a running instance and every
`promisify(execFile)` extension fails with `undefined is not an object (evaluating 'n.stdout')` until
you relaunch — `open` alone won't replace a running copy:

```sh
osascript -e 'quit app "Tinycast Dev"'
open "build/DerivedData/Build/Products/Debug/Tinycast Dev.app"
```

**Debug and Release both sign with a real Developer ID, not `Tinycast Self-Signed`.** The identity is
never committed: `Signing.xcconfig` (the base config for both configs) sets the portable
`Tinycast Self-Signed` default and ends with `#include? "Signing.local.xcconfig"` — a gitignored file
holding your `Developer ID Application: … (<TEAM_ID>)` and team, which overrides the default at build
time. A clone without it (CI, anyone else) builds self-signed and is unaffected, so **official
releases still sign self-signed** — the override only reaches a Release built on a machine that has it.

Why Developer ID for a local build: macOS keeps the Accessibility (TCC) grant across rebuilds under either
identity — TCC matches by designated requirement — but the login-Keychain "Always Allow" grant (AI API
keys, MCP, `assistant-environment` secrets) re-authorizes a rebuilt binary **only when the code-sign
anchor is a trusted Apple one**. Self-signed is `CSSMERR_TP_NOT_TRUSTED`, so the Keychain reprompted on
every rebuild; the Developer ID DR is team-pinned (`subject.OU = <TEAM_ID>`) and survives both a
rebuild and a cert renewal. Switching identity resets both grants **once**, then they stick. Never let
a build fall back to ad-hoc signing — that reprompts every time. Verify:

```sh
codesign -dvv "build/DerivedData/Build/Products/Debug/Tinycast Dev.app" 2>&1 | grep Authority
# Authority=Developer ID Application: <Your Name> (<TEAM_ID>)
```

## Extensions and plugins live outside this repo

Custom extensions and native plugins are **not** built here. They live one per folder under
`~/Developer/tinycast_addons/extensions/` — its own repo, `github.com/jhasubhash/tinycast_addons` —
alongside the native plugins.

- **JS extensions** each build with one esbuild line in their `package.json`;
  [`copy-path`'s README](../../tinycast_addons/extensions/copy-path/README.md) is the reference build
  loop and the `ext-test` recipe. The one porting gotcha: `@raycast/api`, `react`, `react-dom` and the
  JSX runtimes are injected and stay external, but **`@raycast/utils` must be bundled** — externalise it
  and the command boots then fails on its first hook.
- **Native plugins** (see [plugins.md](plugins.md)) also live there — `hello-plugin` is the reference —
  but each is Swift built to a `.dylib` with `swiftc`, linking the app's embedded
  `TinycastPluginKit.framework` and installing to
  `~/Library/Application Support/<bundle id>/plugins/<name>/`.

Keeping them out is deliberate: an extension/plugin costs **zero** rebase surface and survives every
upstream release untouched. Test a JS extension from this repo's root:

```sh
./Scripts/run-tests.sh ext-test
"$TMPDIR/tinycast-harness/ext-test" ~/Developer/tinycast_addons/extensions/<name> <command>
```

Reach for a change in *this* repo only when the host itself is wrong — a `@raycast/api` component
Tinycast renders badly, a missing Node shim, a runtime bug. Native plugin support *did* require host
changes (loader, launcher `Kind`, palette hosting) — the register row below.

## Rules for a custom change

1. **Commit to `main`; keep machine-local files out.** Never commit `Signing.local.xcconfig` (your
   personal, gitignored Apple identity).
2. **Keep the diff minimal and local.** Every line in `git diff upstream/main..main` is resolved by
   hand on every merge; a change across ten files costs ten conflict sites forever, the same change
   behind one new file and one call site costs one.
3. **Follow upstream's rules anyway** — [AGENTS.md](../AGENTS.md) non-negotiables, the comment policy,
   the `Features/*/Model/` purity rule, XcodeGen ownership of the project file. A fork that drifts in
   style can't be rebased or upstreamed.
4. **`project.yml` is the source of truth.** After editing it run `xcodegen generate` and commit
   `Tinycast.xcodeproj` too — editing the `.xcodeproj` directly is lost on the next generate and is a
   299 KB conflict magnet.
5. **Add a register row in the same commit.** A change nobody can find gets rebased away.
6. **Before done:** `./Scripts/run-tests.sh`, a warning-free Debug build, `./Scripts/lint.sh`
   (`brew install swiftlint` — not installed here yet).

## Register of custom changes

One row per behavioural change this fork carries on top of upstream. Fork scaffolding (this file, its
`AGENTS.md` link) is not listed. `git log upstream/main..main` is the full truth.

| Change | Files | Why | Upstreamable |
| --- | --- | --- | --- |
| Inline alias & shortcut editing on the ⌘K action-panel rows | `Features/Launcher/UI/{AppActionsMenu,LauncherCoordinator,InlineEntryEditor}.swift`, `Features/Launcher/Service/AppIndex.swift`, `Features/HotKeys/UI/ShortcutRecorder.swift`, `Palette/{PaletteState,PaletteScreen,RootPaletteView,PalettePanel,PaletteWindowController}.swift`, `DesignSystem/PopoverMenu.swift` | Raycast-parity: ⌘K → Change Alias / Change Shortcut edit in a box on the row itself (menu stays open; alias reads faded until edited and commits on ↵; shortcut shows "Listening…", assigns on capture, flags a taken chord inline). Extension commands gained a `hotKeyAction` so they're bindable too. `ShortcutRecorder` gained `recordingAccent`/`showsConflictInline`. | Yes |
| Native Swift/SwiftUI plugin system | `TinycastPluginKit/`, `Features/Plugins/**`, `App/AppCore.swift`, `Palette/{PaletteMode,PaletteEscapeAction,RootPaletteView}.swift`, `Features/Launcher/{Service/AppIndex,Service/VisibilityStore,UI/LauncherList,UI/LauncherCoordinator}.swift`, `Features/HotKeys/{Model/HotKeyAction,Service/HotKeyManager}.swift`, `Features/Settings/{SettingsTab,SettingsDetailView,AppSettings,AppSettingsKey,SettingsSearchCatalog}.swift`, `Features/Backup/Model/SettingsBackupCoverage.swift`, `project.yml`, `Tinycast.entitlements` | Compiled Swift plugins that `dlopen` into the palette and render SwiftUI, like BetterTouchTool's Swift plugins; complements the JS extension system. A plugin links the embedded `TinycastPluginKit.framework` for one shared type identity across the load boundary. | Maybe — needs the `disable-library-validation` entitlement, which upstream may decline. |
| Pin/unpin a plugin's nested view to the launcher (Add ⇄ Remove from Main Menu) + copy its deep link | `TinycastPluginKit/` (`PluginRoute`, `PluginContext.route`, scaffold `route:`, `PluginCommand.mainMenuSlot()` for placement, `pluginToggleMainMenu`/`pluginMainMenuPinned`/`pluginCopyRouteLink` env hooks), `Features/Plugins/{Service/PluginManager,UI/PluginCoordinator}.swift` (route through launch/context, `PluginRouteURL`, `toggleRoutePin`/`isRoutePinned`/`copyRouteLink`, uninstall prunes pins), `Features/Quicklinks/UI/QuicklinkCoordinator.swift` (intercept `tinycast://plugin/…`), `Palette/RootPaletteView.swift` (inject the hooks) | A saved deep link, stored as an ordinary Quicklink so it inherits aliasing, shortcuts and backup, opens a plugin straight to a nested view. The ⌘K palette offers Add/Remove-from-Main-Menu and "Copy Deep Link" on any surface that supplies a `PluginRoute` — placed where the plugin drops a `mainMenuSlot()`, else appended — keyed on the route link (not the name) so a renamed pin still toggles; uninstalling the plugin removes its pins. Generic seam; plugins support arbitrary views, extensions can adopt command+args later. | Yes |
| Edit & inline-rename a quicklink from the launcher's ⌘K menu | `Features/Launcher/UI/{AppActionsMenu,InlineEntryEditor}.swift`, `Features/Quicklinks/UI/QuicklinkCoordinator.swift`, `Palette/{PaletteState,PaletteWindowController,RootPaletteView}.swift` | The launcher Actions menu for a quicklink row offers "Edit Quicklink" (opens the Settings editor) and "Rename Quicklink" (inline, like Change Alias — the menu stays open, ↵ commits), placed right after "Open Quicklink", so a quicklink (incl. a pinned plugin deep link) is editable without opening Settings by hand. Rename reuses the alias inline-edit path via a shared `applyInlineEdit`. | Yes |
| Optional AI engine for the Translate Quick Action | `Features/QuickActions/Model/{QuickActionSettings,QuickActionPrompt}.swift`, `Features/QuickActions/Service/QuickActionRunner.swift`, `Features/QuickActions/Settings/{QuickActionSettingsStore,QuickActionsSettingsView}.swift`, `Features/QuickActions/UI/QuickActionCoordinator.swift`, `Features/Settings/AppSettingsKey.swift`, `Features/Backup/Model/SettingsBackupCoverage.swift` | Apple's translator can't read transliterated text — `NLLanguageRecognizer` even misdetects romanized Hindi ("kya ho raha hai" → Vietnamese/Indonesian), so it never reaches English. New `translateWithAI` setting (Settings → Quick Actions → Translate, off by default) routes Translate through the quick-action AI model instead, via `QuickActionRunner.translate` + a `QuickActionPrompt.translation(to:)` prompt that handles romanized/transliterated input. Verified end-to-end against the real Claude CLI. Key `quickActionTranslateWithAI` is backup-excluded (it redirects a person's text off-device). | Yes |
| Auto-direction language pair for the Translate Quick Action | `Features/QuickActions/Model/QuickActionSettings.swift`, `Features/QuickActions/Settings/{QuickActionSettingsStore,QuickActionsSettingsView}.swift`, `Features/QuickActions/UI/QuickActionCoordinator.swift`, `Features/Settings/AppSettingsKey.swift`, `Features/Backup/Model/SettingsBackupCoverage.swift` | A "Detect direction" toggle with **Primary** and **Secondary** language pickers (Settings → Quick Actions → Translate). Translate resolves the target per selection in `QuickActionCoordinator.targetLanguage(for:action:)`: text detected as the primary language goes to the secondary, anything else goes to the primary — so one shortcut converts English↔Hindi without a dialog. The detector misreads romanized Hindi as another language, which still routes it to the primary side (English), and pairs with Translate with AI to actually read it. Keys `quickActionAutoLanguageSwap`/`quickActionPrimaryLanguage`/`quickActionSecondaryLanguage` are backup-excluded. | Yes |
| Pop a native plugin surface out into a standalone window | `TinycastPluginKit/TinycastPluginKit.swift` (`PluginPresentation`, `PluginContext.presentation`, `pluginPopOut` env hook + "Pop Out" scaffold command), `Features/Plugins/UI/PluginWindowController.swift` (new — multi-instance borderless `PluginWindowPanel` + controller + per-window ⌘K palette), `Features/Plugins/UI/PluginCoordinator.swift` (`popOut(_:)`), `App/AppCore.swift` (wire `pluginWindowController`), `Palette/RootPaletteView.swift` (inject `pluginPopOut`; always render `topDragStrip` so a plugin surface stays draggable), `project.yml`/`Tinycast.xcodeproj` | A running plugin surface's ⌘K **Pop Out** opens it as its own borderless, resizable, non-activating window that renders only the plugin's view over the palette's backdrop — several at once, keyed by `PluginRoute` (e.g. ADBE + MSFT charts). Each window loads its own plugin instance (independent of the palette session), opens at the launcher's panel size, and carries a bottom-right ⌘K palette for window controls (Show on All Spaces / Keep in Front / Close ⌘W). A plugin opts into a bare window body via `context.presentation == .window`. Known bugs, deferred: opening can switch Spaces or land on another display. | With plugins |
| Floating AI Chat bar (distinct summon) | `Features/AI/UI/{AIScreen,AIChatState,AIChatCoordinator}.swift`, `Features/AI/Settings/AISettingsView.swift`, `Features/HotKeys/{Model/HotKeyAction,Service/HotKeyManager}.swift`, `Features/Launcher/Service/VisibilityStore.swift`, `Features/Settings/{AppSettings,AppSettingsKey}.swift`, `Features/Backup/Model/SettingsBackupCoverage.swift`, `Palette/{PaletteState,PaletteCoordinator,PaletteWindowController,RootPaletteView,PalettePlacement,PaletteScreen,PalettePanel}.swift`, `App/AppCore.swift`, `DesignSystem/Theme.swift` | A dedicated `toggleAIBar` hotkey (Settings → AI → Floating bar) summons AI Chat as a compact "Ask anything…" composer bar, sharing the launcher's chat and history. It has its own per-display placement (`aiBarPosition`, excluded from backups) and expands into the transcript on the first message, animated. Placed low it grows **upward** with the composer docked at the bottom, transcript above, and a keycap `Actions ⌘K` beside the model name (no Send pill); the model/reasoning dropdowns then open upward too (`MenuPanelCorner.aboveHeaderTrailing`). Placed high/centre it grows down with the normal footer. `windowDidMove` and `endDrag` re-anchor/re-resolve the grow direction from the fixed edge so an upward resize can't drift. New Chat marks the session `startedFresh` so a close-and-reopen keeps the empty chat instead of resurrecting the last saved one. The bar is its own root, so an empty backspace stays in it rather than falling back to the launcher. The composer is the shared launcher field — one horizontally-scrolling line at a fixed size; multi-line editing lives in the pop-out chat window instead. Actions menu rows carry ⌘N / ⇧⌘C / ⌘Y / ⌘, shortcuts, wired for `.ai` mode. | Yes |
| Configured Assistants (named AI chat bars) | `Features/AI/Model/{Assistant,Skill}.swift` (new), `Features/AI/Service/{AssistantStore,SkillStore,ChatHistoryStore}.swift`, `Features/AI/Settings/{AssistantsSettingsSection,AssistantEditorSheet,SkillsSettingsSection,AISettingsView}.swift`, `Features/AI/UI/{AIChatCoordinator,AssistantTint+Color}.swift`, `Features/AI/Model/AIInstructions.swift`, `Features/MCP/UI/MCPCoordinator.swift`, `Features/HotKeys/{Model/HotKeyAction,Service/HotKeyManager}.swift`, `Features/Launcher/{Service/AppIndex,Service/VisibilityStore,UI/LauncherCoordinator}.swift`, `Features/Settings/{AppSettings,AppSettingsKey,SettingsAnchor,SettingsCoordinator}.swift`, `Features/Backup/Model/SettingsBackupCoverage.swift`, `Palette/{PaletteState,RootPaletteView}.swift`, `App/AppCore.swift`, `Tests/assistant-test.swift` (new), `Scripts/run-tests.sh` | Multiple user-created **Assistants** — named AI chat bars, each with its own shortcut, model, system prompt, Claude Agent **Skills**, MCP-server subset, web search, open policy, retention, per-display placement, width, glyph/tint and seed prompt. `PaletteState.activeAssistantID` re-points the single AI stack (`AIChatCoordinator.effectiveProvider`/`activeAssistant`, `AIInstructions.compose(skills:)`, `MCPCoordinator.tools(allowed:)`, open policy); `activeAssistant == nil` (default bar) is byte-for-byte unchanged. History is `assistant_id`-scoped (`ChatHistoryStore.scope`, NULL-preserving migration, ephemeral-skip). Each is a per-item hotkey (`HotKeyAction.assistant(id:)`) and an `AppEntry.Kind.assistant` "Ask <Name>" launcher command (feature-gated via `settingsOwner`, `aiAssistantsShowInLauncher` toggle). Managed in Settings → AI (Assistants list + editor sheet, Skills library). Assistants/Skills stores are JSON in `UserDefaults`, backup-excluded. Pluggable (plugin-provided) assistants are deferred — see `Assistant_Architecture.md` §19. | Yes |
| Per-assistant CLI tool calling (Claude & Codex MCP) | `Features/AI/Model/AICLIToolConfig.swift` (new), `Features/AI/Model/Assistant.swift`, `Features/AI/Service/{AIProviderFactory,InstalledAIManager,InstalledCLIProvider,CodexTurnRunner,ChatGPTSubscriptionManager}.swift`, `Features/AI/UI/AIChatCoordinator.swift`, `Features/AI/Settings/AssistantEditorSheet.swift`, `Features/MCP/UI/MCPCoordinator.swift`, `App/AppCore.swift`, `Tests/assistant-test.swift` | A per-assistant **Allow CLI tools** opt-in (off by default) lets an installed **Claude** (`claude -p`) or **Codex** (`app-server`) route run the assistant's enabled MCP servers as its *own* tools, instead of the sandboxed text-only default. `MCPCoordinator.cliToolConfig` builds a neutral `AICLIToolConfig` (Keychain secrets, never a backup) that each CLI formats: Claude gets `--mcp-config` + an `mcp__<slug>` `--allowedTools` allowlist (scoped to those servers — no shell/file) + raised `--max-turns` and drops its "don't use tools" prompt; Codex gets `config.mcp_servers` in `thread/start` + per-turn `networkAccess`. `Assistant` gains a decode-tolerant `init(from:)` so adding fields never drops saved assistants. `activeAssistant == nil` (default bar) and every non-CLI route are unchanged. | With plugins |
| Per-assistant CLI shell tools + environment variables | `Features/AI/Model/{AICLIToolConfig,Assistant}.swift`, `Features/AI/Service/{AssistantSecretStore.swift (new),InstalledCLIProvider}.swift`, `Features/AI/UI/AIChatCoordinator.swift`, `Features/AI/Settings/AssistantEditorSheet.swift`, `Features/MCP/UI/MCPCoordinator.swift`, `Platform/KeychainSecretStore.swift`, `Tests/assistant-test.swift` | A broader per-assistant **Allow shell tools** opt-in (off by default) lets an installed **Claude** CLI route run *shell* commands (`--dangerously-skip-permissions`), so a script-based **Skill** (e.g. Jira's `jira_query.py`) can execute — not just MCP tools. Paired with a per-assistant **Environment** editor: `NAME=value` lines stored one Keychain item per assistant (`AssistantSecretStore`, scope `assistant-environment`), never in UserDefaults or a backup, injected into the CLI process so a Skill's script can authenticate (`JIRA_TOKEN` etc.). `AICLIToolConfig` gains `allowShell`/`environment`; `MCPCoordinator.cliServers` returns the neutral server list. Shell tools are Claude-only for now (Codex disables its shell at the app-server launch). | With plugins |
| GitHub Copilot CLI as an installed AI provider | `Features/AI/Model/{InstalledAI,AIConnection,InstalledAIStream,AICLIToolConfig}.swift`, `Features/AI/Service/{InstalledAIManager,InstalledCLIProvider,AIProviderFactory}.swift`, `Features/AI/UI/AIChatCoordinator.swift`, `Features/AI/Settings/{AISettingsStore,AISettingsView}.swift`, `Features/QuickActions/Settings/QuickActionsSettingsView.swift` | Adds `InstalledAIKind.copilot` (`copilot -p`, stdin prompt) as a fourth installed route alongside Codex/Claude/OpenCode, wired through every workflow: model selection + Codable, provider factory, the Providers list + toggle, the model picker groups, chat capabilities/icons/effort, and Quick Actions. Streaming decodes Copilot's `--output-format json` JSONL (`assistant.message_delta.deltaContent`, `result`); the probe reads readiness/models from `~/.copilot/config.json` (JSONC — parsed from the first `{`), catalog is `auto` + the account's `recentModelIds`. The CLI-tools opt-in formats Copilot's `--additional-mcp-config` and grants `--allow-all-tools` (MCP) or `--allow-all` (shell, so a Skill's script reaches its host); per-assistant env is injected for auth. Text-only by default (no `--allow-all-tools` → no tool auto-runs). | With plugins |
| Keep the floating AI Chat bar open on focus loss | `Features/Settings/{AppSettings,AppSettingsKey}.swift`, `Palette/PaletteWindowController.swift`, `Features/AI/Settings/AISettingsView.swift`, `Features/Backup/Model/SettingsBackupCoverage.swift` | A **Keep the floating bar open** toggle (Settings → AI → Chat, off by default) makes `AppSettings.aiBarStaysOpen` skip the resign-key auto-hide in `PaletteWindowController.windowDidResignKey` when the floating AI bar (`palette.aiBar`) is up, so it survives clicking into another app instead of closing on blur. Every other surface still hides normally, and the bar still closes on Escape / New Chat / re-summon. Backup-excluded as a per-Mac UI behaviour. | Yes |
| Stream the model's reasoning into chat (togglable) | `Features/AI/Model/{AIRequest,AIStreamDecoder,InstalledAIStream,ChatMessage,Assistant}.swift`, `Features/AI/Service/CodexTurnRunner.swift`, `Features/AI/UI/{AIChatState,AIScreen,ChatTranscriptView,ChatHistoryView}.swift`, `Features/AI/Settings/{AISettingsStore,AISettingsView,AssistantEditorSheet}.swift`, `Features/Settings/AppSettingsKey.swift`, `Features/Backup/Model/SettingsBackupCoverage.swift`, `Tests/ai-provider-test.swift` | `AIStreamEvent.thinking` now carries the reasoning text (was a bare signal that discarded it, so a reasoning model looked hung behind a lone spinner). Every decoder extracts it — API/OpenRouter (`delta.reasoning`/`reasoning_details[].text`), Anthropic + Claude CLI (`thinking_delta.thinking`) — and `AIChatState` accumulates it into `ChatMessage.reasoning` (live, not persisted). A collapsible "Thinking…" block streams it open above the answer, then folds when the answer begins. Gated by a global `AISettingsStore.showReasoning` (Settings → AI → Chat, on by default) with a per-assistant override (`Assistant.showReasoning`, editor's Model section), resolved `activeAssistant?.showReasoning ?? global`; backup-excluded as a per-Mac display choice. The empty streaming bubble now always labels itself "Thinking…". Note: reasoning **text** only exists on API-key routes — the CLI tools redact it (Claude `-p` sends `thinking:""`+signature) or omit it (Copilot streams only `reasoning_tokens` counts). | Yes |
| Reasoning-effort picker for Copilot models | `Features/AI/Model/InstalledAI.swift` | `copilotCatalog` now builds every Copilot model with the shared `cliEfforts` ladder (`low/medium/high/xhigh/max`) — the exact set Copilot advertises (`reasoning_effort` in its JSONL) and the Claude CLI already used. So the header's effort picker appears for Copilot (defaulting to High) exactly as it does for Claude; `InstalledCLIProvider` already passed `--reasoning-effort` for the copilot route, so the choice now reaches `copilot -p`. | With plugins |
| Debug signs with a real Developer ID identity, via a gitignored local xcconfig | `Signing.xcconfig` (new — project Debug base config), `Signing.local.xcconfig` (new — gitignored), `project.yml`, `.gitignore`, `Tinycast.xcodeproj` | The login-Keychain "Always Allow" grant (AI keys, MCP, `assistant-environment`) only survives a rebuild when the app's code-sign anchor is Apple-trusted; `Tinycast Self-Signed` is `CSSMERR_TP_NOT_TRUSTED`, so the Keychain reprompted on every rebuild while TCC — matching by DR — did not. Debug now signs with `Developer ID Application: … (<TEAM_ID>)`, a team-pinned DR stable across rebuilds and cert renewal. The identity is **not** committed: `Signing.xcconfig` carries the portable `Tinycast Self-Signed` default and `#include?`s the gitignored `Signing.local.xcconfig` that holds the personal identity, so any clone (and CI) builds self-signed and unaffected. (Release now shares this via the row below.) | Mechanism yes; identity machine-local |
| Floating AI Chat composer clears the inline model/effort controls | `Palette/RootPaletteView.swift` | The AI composer fills the header row (`maxWidth: .infinity`) while the model + reasoning buttons sit inline to its right. At the `spacing.md` inter-control gutter a full line of scrolled text butted against "Claude Sonnet"; widened that one gutter to `spacing.xxl` so the field keeps clearance from the controls. Every other single-line header field is unaffected. | Yes |
| Release also signs with the local Developer ID identity | `project.yml` (`configFiles.Release: Signing.xcconfig`; dropped the `configs.Release` self-signed pin + empty team), `Signing.xcconfig` (comment), `Tinycast.xcodeproj` | Extends the row above to Release so a locally-built `Tinycast.app` (bundle id `com.tinycast.app`) run from this machine keeps its login-Keychain "Always Allow" grants across rebuilds. `configs.Release` no longer pins `Tinycast Self-Signed`; both configs now read `Signing.xcconfig`, whose `#include?`d local override wins when present. A clone without `Signing.local.xcconfig` (CI, anyone else) falls back to the self-signed default, so official/CI releases still sign self-signed and are unchanged. | No — upstream deliberately keeps Release self-signed for the updater's team-pinned DR |
| Task scheduler (run a script or post a notification on a rule) | `Features/Scheduler/**` (new — `Model/{ScheduledTask,ScheduleEngine,NaturalDateParser,ScheduleFormatter}`, `Service/ScheduledTaskStore`, `UI/SchedulerCoordinator`, `Settings/{SchedulerSettingsView,SchedulerTaskEditorSheet}`, `AI/SchedulerAITool`), `Features/Notifications/**` (new — `Model/{NotificationSpec,NotificationPlacement}`, `Service/NotificationPresenter`, `UI/{NotificationCardView,NotificationPanel}`), `App/AppCore.swift`, `Features/HotKeys/{Model/HotKeyAction,Service/HotKeyManager}.swift`, `Features/Launcher/{Service/AppIndex,Service/VisibilityStore,UI/LauncherCoordinator}.swift`, `Features/Settings/{AppSettings,AppSettingsKey,SettingsTab,SettingsDetailView,SettingsAnchor,SettingsSearchCatalog,SettingsCoordinator}.swift`, `Features/Backup/Model/{SettingsBackup,SettingsBackupCoverage}.swift`, `Features/AI/UI/AIChatCoordinator.swift`, `Palette/PaletteWindowController.swift`, `Platform/ScreenTarget.swift`, `Tests/scheduler-test.swift`, `Scripts/run-tests.sh`, `project.yml`, `Tinycast.xcodeproj`, `docs/features/scheduler.md` | Runs a shell script or posts a Tinycast notification on a once/interval/daily/weekly/monthly rule, off by default (Settings → Scheduler). `ScheduledTaskStore` persists tasks as JSON in `UserDefaults`; `SchedulerCoordinator` holds one pending wake for the whole set, fires due tasks against each task's own `lastFired` anchor (so editing never double-fires), and bounds resume catch-up at 25 missed fires per task. Model layer is AppKit/SwiftUI-free and pinned by `scheduler-test` (rule math + DST + natural-date parsing). Notifications post through a floating `NotificationPanel`, never `NSAlert`. Tasks run on demand from a launcher row (`AppEntry.Kind.scheduledTask`) or a global shortcut (`HotKeyAction.scheduledTask`). `SchedulerAITool` (`scheduler__create_reminder`) lets the assistant set a **notification-only** reminder — never a script. `schedulerEnabled` is backup-excluded (arming unattended execution is a per-Mac consent), `schedulerShowInLauncher` is backed up. | Yes |
| Scheduled tasks: create / edit / delete from the launcher | `Features/Scheduler/UI/{SchedulerEditorCoordinator,SchedulerEditorScreen,SchedulerTaskControls,ScheduledTaskDraft}.swift` (new), `Features/Scheduler/{UI/SchedulerCoordinator,Settings/SchedulerSettingsView,Settings/SchedulerTaskEditorSheet}.swift`, `Features/Launcher/{Model/CommandID,Model/CommandCatalog,UI/LauncherCoordinator,UI/AppActionsMenu}.swift`, `Features/Settings/{SettingsAnchor,SettingsSearchCatalog}.swift`, `Palette/{PaletteMode,PaletteCoordinator,RootPaletteView}.swift`, `App/AppCore.swift`, `docs/features/scheduler.md`, `Tinycast.xcodeproj` | Extends the scheduler row: a `.scheduledTask` launcher row's ⌘K menu now carries **Edit** and **Delete**, and a new `createScheduledTask` command (`Create Scheduled Task`, icon `calendar.badge.plus`) creates one — all through `SchedulerEditorCoordinator`, which opens the **in-palette** `SchedulerEditorScreen` (palette mode `.schedulerEditor`), a two-column form sized to the fixed launcher panel — never a window — and confirms delete through `DialogController` (never `NSAlert`). The form owns no buttons: Save/Add rides the launcher's shared footer `ActionBar` on ↵ and Delete sits under ⌘K while editing. It and the Scheduler pane's `SchedulerTaskEditorSheet` render the same `SchedulerTaskControls` bound to a shared `ScheduledTaskDraft`, so a restyle lands on both; the sheet keeps its own Cancel/Save and both take an injected `dismiss`. The command is an owned command of the Scheduler pane (Settings → Scheduler → Commands, alias + optional shortcut), gated by `schedulerEnabled && schedulerShowInLauncher` via `AppIndex.setCommandsVisible`. | Yes |
| Apple Intelligence runs the scheduler (and any host tool) in-process | `Features/AI/Service/AppleIntelligenceHostTool.swift` (new — `FoundationModels.Tool` bridge + `AppleIntelligenceToolSchema` JSON-Schema→`GenerationSchema` converter), `Features/AI/Service/AppleIntelligenceProvider.swift` (stores `hostTools`+executor, attaches them to the `LanguageModelSession`, `executingHostTools(_:invoke:)`), `Features/AI/UI/AIChatCoordinator.swift` (`toolAware` builds one shared `invoke` and routes the on-device path), `Tests/apple-intelligence-test.swift`, `Scripts/run-tests.sh`, `docs/features/scheduler.md`, `Tinycast.xcodeproj` | The on-device route is `AIModelCapabilities.none` (`tools:false`), so `toolAware` never armed it and Apple Intelligence just refused "I can't schedule a notification." `FoundationModels` supports tools via its own `Tool` protocol with an internal loop (never `.toolCallRequested`), so it can't ride `AIToolLoopProvider`; the provider now bridges each `AITool` onto a `FoundationModels.Tool` it executes in-process against the same `ScheduledTaskStore`. Notification-only invariant is unchanged (still `SchedulerAITool`). CLI agents (Claude/Copilot/OpenCode/Codex) stay text-only — they'd need an in-app MCP server. | No — fork-only scheduler feature |
| Natural-language "Schedule a Reminder" launcher fallback | `Features/Scheduler/Model/{ReminderPhraseParser,NaturalDateParser}.swift` (new parser + `Match`/relative-duration pass), `Features/Scheduler/Service/ReminderPhraseModel.swift` (new — on-device `@Generable` backstop), `Features/Scheduler/Model/ScheduledTask.swift` (`notification(title:body:rule:now:)` factory), `Features/Scheduler/AI/SchedulerAITool.swift` (uses the factory), `Features/Scheduler/UI/SchedulerEditorCoordinator.swift` (`scheduleFromPhrase`), `Features/Launcher/{Model/Fallback,UI/FallbackCoordinator}.swift` (`scheduleReminder` builtin), `Tests/scheduler-test.swift`, `docs/features/scheduler.md`, `Tinycast.xcodeproj` | The scheduler was reachable in free-text only through the AI chat, and only on a tool-capable API model. `ReminderPhraseParser` (Foundation-only, instant, universal) turns a typed launcher phrase — "remind me to book the ticket in next 20 min", "drink water every day at 8am" — into a notification task, lifting the time (relative durations too, which `NSDataDetector` misses), a recurrence and a clean title; `ReminderPhraseModel` is an Apple-Intelligence backstop for the messy tail, degrading to "couldn't find a time" when unavailable. Notification-only, like the AI tool. Also fixed the AI tool's "in N minutes" miss (shared parser) and a stale doc line. | Yes |
| Reusable semantic-intent module behind the launcher fallback ranking | `Features/Intent/Model/{QueryText,IntentClassifier,IntentDetectors}.swift` (new — `QueryIntent` + `IntentDetector`/`IntentClassifier`, reminder/shell/file/AI detectors), `Features/Launcher/Model/Fallback.swift` (`Builtin.intent`, `prioritised(_:forIntents:)`), `Features/Launcher/UI/FallbackCoordinator.swift` (ranks via `IntentClassifier.standard`), `Features/Scheduler/Model/ReminderPhraseParser.swift` (dropped `signalsIntent`), `Tests/{intent-test,fallback-test,scheduler-test}.swift`, `Scripts/run-tests.sh`, `docs/features/scheduler.md`, `Tinycast.xcodeproj` | The reminder-intent scan lived inside `ReminderPhraseParser` and only the scheduler row could promote; extracting a `Notification.Name`-style intent registry lets any fallback (search, shell, AI) float on what a query means, from one Foundation-only place. | Yes |
