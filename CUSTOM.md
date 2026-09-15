# Custom fork

This checkout is **`jhasubhash/tinycast`**, a fork of **`abue-ammar/tinycast`**. Everything upstream
says still applies — [AGENTS.md](AGENTS.md) and [docs/](docs/README.md) are unchanged and authoritative.
This file covers only what is true *here* and nowhere upstream: the branch model, the local build and
signing setup, the periodic sync, and the register of changes this fork carries.

**If you are an agent working in this repo, read this before your first commit.** The one rule that
breaks everything if you get it wrong: **never commit to `main`.**

## Layout

| | |
| --- | --- |
| Checkout | `~/Developer/tinycast` |
| `origin` | `https://github.com/jhasubhash/tinycast` |
| `upstream` | `https://github.com/abue-ammar/tinycast.git` (push URL is `DISABLED` on purpose) |
| Sync script | `~/.local/bin/tinycast-sync.sh` |
| launchd agent | `~/Library/LaunchAgents/com.sujha.tinycast-sync.plist`, label `com.sujha.tinycast-sync` |
| Sync log | `~/Library/Logs/tinycast/sync.log` |

The checkout is **not** under `~/Documents`. macOS TCC denies launchd-spawned jobs access to
`~/Documents`, `~/Desktop` and `~/Downloads`, and the sync agent failed there with
`fatal: Unable to read current working directory: Operation not permitted`. Moving the repo back into
one of those folders re-breaks the agent silently — the log is the only place it says so.

## Branch model

| Branch | Role |
| --- | --- |
| `main` | Pristine mirror of `upstream/main`. **Never commit here.** It exists so the sync is always a fast-forward and so `git diff main` is exactly this fork's delta. |
| `custom` | Every local change. This is the working branch and what gets built. |

A commit on `main` turns every future sync into a divergence the script refuses to resolve — it warns
rather than forcing, because a forced sync would silently drop the commit. If it happens: move the
commit off (`git branch -f custom <sha>` or `git cherry-pick` onto `custom`), then
`git reset --hard upstream/main` on `main`.

## Syncing with upstream

### Automatic

The launchd agent runs `tinycast-sync.sh` **at load and every 6 hours** (`StartInterval` 21600).
Each run does three things, in order:

1. `gh repo sync jhasubhash/tinycast --source abue-ammar/tinycast --branch main` — fast-forwards the
   fork's `main` on GitHub.
2. Fetches both remotes and fast-forwards local `main`, via a refspec (`git fetch . upstream/main:main`)
   so the working tree and your checked-out branch are never touched.
3. Reports how far `custom` has drifted behind `main`.

It **never rebases `custom` automatically.** A merge conflict resolved by a background job is a merge
conflict resolved badly; the drift report is the trigger for you to do it deliberately.

Auth detail worth knowing: the active `gh` github.com account on this machine is `sujha_adobe`, not the
fork owner. The script fetches the right token explicitly with
`gh auth token -h github.com -u jhasubhash`, so switching `gh` accounts does not break it.

### On demand

```sh
~/.local/bin/tinycast-sync.sh          # same thing, in the foreground
tail -20 ~/Library/Logs/tinycast/sync.log
```

A healthy run looks like:

```
fork: main already level with upstream
local main -> bfd86f5
custom is up to date with main (0 ahead)
```

### Rebasing custom work onto new upstream

When the log says `custom is N behind`:

```sh
git switch custom
git rebase main
# resolve, then rebuild — a clean rebase is not a working build
xcodebuild -project Tinycast.xcodeproj -scheme Tinycast -configuration Debug \
    -derivedDataPath build/DerivedData build
./Scripts/run-tests.sh
```

Rebase rather than merge: it keeps `git log main..custom` a readable list of exactly this fork's
patches, which is what makes them upstreamable and what the register below mirrors.

### Managing the agent

```sh
launchctl kickstart -k gui/$(id -u)/com.sujha.tinycast-sync   # run it now
launchctl print gui/$(id -u)/com.sujha.tinycast-sync          # state, last exit code
launchctl bootout gui/$(id -u)/com.sujha.tinycast-sync        # stop it
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.sujha.tinycast-sync.plist
```

## Local build and signing

Full instructions are [docs/development.md](docs/development.md) and [docs/signing.md](docs/signing.md).
Two things about *this* machine are not in either:

**The `openssl pkcs12 -export` command in signing.md §1 fails on OpenSSL 3**, with
`security: SecKeychainItemImport: MAC verification failed during PKCS12 import (wrong password?)` —
OpenSSL 3 defaults to a MAC that `security import` cannot read. The identity here was created with the
legacy algorithms added:

```sh
openssl pkcs12 -export -legacy -macalg sha1 \
  -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES \
  -inkey /tmp/tc-key.pem -in /tmp/tc-cert.pem \
  -name "Tinycast Self-Signed" -out /tmp/tc.p12 -passout pass:tinycast
```

`security find-identity -p codesigning` reports the identity as `CSSMERR_TP_NOT_TRUSTED`. That is
expected and harmless for a self-signed cert — `codesign` uses it, and `codesign --verify --deep
--strict` on the built app passes.

**Build and run:**

```sh
xcodebuild -project Tinycast.xcodeproj -scheme Tinycast -configuration Debug \
    -derivedDataPath build/DerivedData build
open "build/DerivedData/Build/Products/Debug/Tinycast Dev.app"
```

Or `open Tinycast.xcodeproj` and ⌘R. Debug is its own channel — `Tinycast Dev.app`,
`com.tinycast.app.dev` — with its own prefs, caches and TCC grants, so it cannot see or clobber an
installed Tinycast. It starts with no hotkeys bound; record one in Settings → General.

**After a sync + rebuild, quit and relaunch a running `Tinycast Dev` — a stale instance is not
harmless.** The extension JS runtime (`Resources/RaycastRuntime.generated.js`) and its Swift host
(`Features/Extensions/Service/`) ship as one matched pair and change together — upstream `#697`, for
one, reworked async `exec`/`execFile` from a single `proc.run` host call into `proc.start` + `proc.wait`
across *both* sides. A process launched before the rebuild keeps its old runtime talking to the old
host, so nothing breaks; but rebuild the app underneath a still-running instance and every
`promisify(execFile)` extension — kill-process's `/bin/ps`, reload-extensions' `npm run build` — fails
with `undefined is not an object (evaluating 'n.stdout')` until you relaunch. `open` alone will not
replace a running copy:

```sh
osascript -e 'quit app "Tinycast Dev"'
open "build/DerivedData/Build/Products/Debug/Tinycast Dev.app"
```

Keeping the `Tinycast Self-Signed` identity is what makes macOS remember the Accessibility grant across
rebuilds. Do not let a build fall back to ad-hoc signing — the grant is then re-requested every time.

Verify a build actually got signed with it:

```sh
codesign -dvv "build/DerivedData/Build/Products/Debug/Tinycast Dev.app" 2>&1 | grep Authority
# Authority=Tinycast Self-Signed
```

## Extensions live outside this repo

Custom Tinycast extensions are **not** built here. They live one per folder under
`~/Developer/tinycast_addons/extensions/`, each self-contained — manifest, sources, build script and
installer in the same directory, with nothing above it.

That workspace is its own git repo, `github.com/jhasubhash/tinycast_addons`, holding 13 extensions —
two written for Tinycast (`fork-sync`, `copy-path`) and eleven ported from
`~/Documents/automations/Raycast/Extensions/`. Every one builds with a single esbuild line in its
`package.json`; [`fork-sync`'s README](../tinycast_addons/extensions/fork-sync/README.md) is the
shared build loop and the `ext-test` recipe.

The one thing a port has to get right: `@raycast/api`, `react`, `react-dom` and the JSX runtimes are
injected by the runtime and stay external, but **`@raycast/utils` is not provided and must be
bundled**. Externalising it yields a command that boots and then fails on its first hook.

Keeping them out is deliberate: an extension is a Raycast-format package that Tinycast loads from
`~/Library/Application Support/<bundle id>/extensions/`, not something the app compiles. Putting one
in this tree would add a rebase conflict site for something the app never reads from here.

Reach for a change in *this* repo only when the host itself is wrong — a `@raycast/api` component
Tinycast renders badly, a missing Node shim, a runtime bug. Anything that is just "a thing I want
Tinycast to do" is an extension, costs zero rebase surface, and survives every upstream release
untouched.

The fast way to test one, from this repo's root:

```sh
./Scripts/run-tests.sh ext-test
"$TMPDIR/tinycast-harness/ext-test" ~/Developer/tinycast_addons/extensions/<name> <command>
```

### Native plugins are compiled, not bundled JavaScript

Native Swift plugins (see [docs/features/plugins.md](docs/features/plugins.md)) also live under
`~/Developer/tinycast_addons/extensions/` — `hello-plugin` is the reference — but each is Swift
source built to a `.dylib` with `swiftc`, not an esbuild bundle. They link the app's embedded
`TinycastPluginKit.framework` and install to `~/Library/Application Support/<bundle id>/plugins/<name>/`.
Unlike a JS extension, native plugin support *required* host changes — a loader, a launcher `Kind`,
and palette hosting — which is the register row below.

## Rules for a custom change

1. **Commit on `custom`, never `main`.**
2. **Keep the diff minimal and local.** Every line in `git diff main..custom` is a line you rebase by
   hand on every upstream release. A change spread across ten files costs ten conflict sites forever;
   the same change behind one new file and one call site costs one.
3. **Follow upstream's rules anyway** — [AGENTS.md](AGENTS.md) non-negotiables, the comment policy, the
   `Features/*/Model/` purity rule, XcodeGen ownership of the project file. A fork that drifts in style
   is a fork that cannot be rebased or upstreamed.
4. **`project.yml` is still the source of truth.** After editing it run `xcodegen generate` and commit
   `Tinycast.xcodeproj` too. Editing the `.xcodeproj` directly is lost on the next generate, and it is a
   299 KB conflict magnet on every rebase.
5. **Add a row to the register below in the same commit.** A change nobody can find is a change that
   gets rebased away.
6. **Before calling it done**, run what upstream requires:
   `./Scripts/run-tests.sh`, a warning-free Debug build, `./Scripts/lint.sh`
   (`brew install swiftlint` — not installed on this machine yet).

## Register of custom changes

One row per behavioural change this fork carries on top of upstream. This file and its `AGENTS.md`
link are the fork's own scaffolding and are not listed. `git log main..custom` is the full truth.

| Change | Files | Why | Upstreamable |
| --- | --- | --- | --- |
| Inline alias & shortcut editing on the ⌘K action-panel rows | `Features/Launcher/UI/{AppActionsMenu,LauncherCoordinator,InlineEntryEditor}.swift`, `Features/Launcher/Service/AppIndex.swift`, `Features/HotKeys/UI/ShortcutRecorder.swift`, `Palette/{PaletteState,PaletteScreen,RootPaletteView,PalettePanel,PaletteWindowController}.swift`, `DesignSystem/PopoverMenu.swift` | Raycast-parity: ⌘K → Change Alias / Change Shortcut edit in a box on the row itself (menu stays open; alias reads faded until edited and commits on ↵; shortcut shows "Listening…", assigns on capture, flags a taken chord inline). Extension commands gained a `hotKeyAction` so they're bindable too. `ShortcutRecorder` gained `recordingAccent`/`showsConflictInline`. | Yes |
| Native Swift/SwiftUI plugin system | `TinycastPluginKit/`, `Features/Plugins/**`, `App/AppCore.swift`, `Palette/{PaletteMode,PaletteEscapeAction,RootPaletteView}.swift`, `Features/Launcher/{Service/AppIndex,Service/VisibilityStore,UI/LauncherList,UI/LauncherCoordinator}.swift`, `Features/HotKeys/{Model/HotKeyAction,Service/HotKeyManager}.swift`, `Features/Settings/{SettingsTab,SettingsDetailView,AppSettings,AppSettingsKey,SettingsSearchCatalog}.swift`, `Features/Backup/Model/SettingsBackupCoverage.swift`, `project.yml`, `Tinycast.entitlements` | Compiled Swift plugins that `dlopen` into the palette and render SwiftUI, like BetterTouchTool's Swift plugins; complements the JS extension system. A plugin links the embedded `TinycastPluginKit.framework` for one shared type identity across the load boundary. | Maybe — needs the `disable-library-validation` entitlement, which upstream may decline. |
| Pin/unpin a plugin's nested view to the launcher (Add ⇄ Remove from Main Menu) + copy its deep link | `TinycastPluginKit/` (`PluginRoute`, `PluginContext.route`, scaffold `route:`, `PluginCommand.mainMenuSlot()` for placement, `pluginToggleMainMenu`/`pluginMainMenuPinned`/`pluginCopyRouteLink` env hooks), `Features/Plugins/{Service/PluginManager,UI/PluginCoordinator}.swift` (route through launch/context, `PluginRouteURL`, `toggleRoutePin`/`isRoutePinned`/`copyRouteLink`, uninstall prunes pins), `Features/Quicklinks/UI/QuicklinkCoordinator.swift` (intercept `tinycast://plugin/…`), `Palette/RootPaletteView.swift` (inject the hooks) | A saved deep link, stored as an ordinary Quicklink so it inherits aliasing, shortcuts and backup, opens a plugin straight to a nested view. The ⌘K palette offers Add/Remove-from-Main-Menu and "Copy Deep Link" on any surface that supplies a `PluginRoute` — placed where the plugin drops a `mainMenuSlot()`, else appended — keyed on the route link (not the name) so a renamed pin still toggles; uninstalling the plugin removes its pins. Generic seam; plugins support arbitrary views, extensions can adopt command+args later. | Yes |
| Edit & inline-rename a quicklink from the launcher's ⌘K menu | `Features/Launcher/UI/{AppActionsMenu,InlineEntryEditor}.swift`, `Features/Quicklinks/UI/QuicklinkCoordinator.swift`, `Palette/{PaletteState,PaletteWindowController,RootPaletteView}.swift` | The launcher Actions menu for a quicklink row offers "Edit Quicklink" (opens the Settings editor) and "Rename Quicklink" (inline, like Change Alias — the menu stays open, ↵ commits), placed right after "Open Quicklink", so a quicklink (incl. a pinned plugin deep link) is editable without opening Settings by hand. Rename reuses the alias inline-edit path via a shared `applyInlineEdit`. | Yes |
| Optional AI engine for the Translate Quick Action | `Features/QuickActions/Model/{QuickActionSettings,QuickActionPrompt}.swift`, `Features/QuickActions/Service/QuickActionRunner.swift`, `Features/QuickActions/Settings/{QuickActionSettingsStore,QuickActionsSettingsView}.swift`, `Features/QuickActions/UI/QuickActionCoordinator.swift`, `Features/Settings/AppSettingsKey.swift`, `Features/Backup/Model/SettingsBackupCoverage.swift` | Apple's translator can't read transliterated text — `NLLanguageRecognizer` even misdetects romanized Hindi ("kya ho raha hai" → Vietnamese/Indonesian), so it never reaches English. New `translateWithAI` setting (Settings → Quick Actions → Translate, off by default) routes Translate through the quick-action AI model instead, via `QuickActionRunner.translate` + a `QuickActionPrompt.translation(to:)` prompt that handles romanized/transliterated input. Verified end-to-end against the real Claude CLI. Key `quickActionTranslateWithAI` is backup-excluded (it redirects a person's text off-device). | Yes |
| Auto-direction language pair for the Translate Quick Action | `Features/QuickActions/Model/QuickActionSettings.swift`, `Features/QuickActions/Settings/{QuickActionSettingsStore,QuickActionsSettingsView}.swift`, `Features/QuickActions/UI/QuickActionCoordinator.swift`, `Features/Settings/AppSettingsKey.swift`, `Features/Backup/Model/SettingsBackupCoverage.swift` | A "Detect direction" toggle with **Primary** and **Secondary** language pickers (Settings → Quick Actions → Translate). Translate resolves the target per selection in `QuickActionCoordinator.targetLanguage(for:action:)`: text detected as the primary language goes to the secondary, anything else goes to the primary — so one shortcut converts English↔Hindi without a dialog. The detector misreads romanized Hindi as another language, which still routes it to the primary side (English), and pairs with Translate with AI to actually read it. Keys `quickActionAutoLanguageSwap`/`quickActionPrimaryLanguage`/`quickActionSecondaryLanguage` are backup-excluded. | Yes |
| Pop a native plugin surface out into a standalone window | `TinycastPluginKit/TinycastPluginKit.swift` (`PluginPresentation`, `PluginContext.presentation`, `pluginPopOut` env hook + "Pop Out" scaffold command), `Features/Plugins/UI/PluginWindowController.swift` (new — multi-instance borderless `PluginWindowPanel` + controller + per-window ⌘K palette), `Features/Plugins/UI/PluginCoordinator.swift` (`popOut(_:)`), `App/AppCore.swift` (wire `pluginWindowController`), `Palette/RootPaletteView.swift` (inject `pluginPopOut`; always render `topDragStrip` so a plugin surface stays draggable), `project.yml`/`Tinycast.xcodeproj` | A running plugin surface's ⌘K **Pop Out** opens it as its own borderless, resizable, non-activating window that renders only the plugin's view over the palette's backdrop — several at once, keyed by `PluginRoute` (e.g. ADBE + MSFT charts). Each window loads its own plugin instance (independent of the palette session), opens at the launcher's panel size, and carries a bottom-right ⌘K palette for window controls (Show on All Spaces / Keep in Front / Close ⌘W). A plugin opts into a bare window body via `context.presentation == .window`. Known bugs, deferred: opening can switch Spaces or land on another display. | With plugins |
| Floating AI Chat bar (distinct summon) | `Features/AI/UI/{AIScreen,AIChatState,AIChatCoordinator}.swift`, `Features/AI/Settings/AISettingsView.swift`, `Features/HotKeys/{Model/HotKeyAction,Service/HotKeyManager}.swift`, `Features/Launcher/Service/VisibilityStore.swift`, `Features/Settings/{AppSettings,AppSettingsKey}.swift`, `Features/Backup/Model/SettingsBackupCoverage.swift`, `Palette/{PaletteState,PaletteCoordinator,PaletteWindowController,RootPaletteView,PalettePlacement,PaletteScreen,PalettePanel}.swift`, `App/AppCore.swift`, `DesignSystem/Theme.swift` | A dedicated `toggleAIBar` hotkey (Settings → AI → Floating bar) summons AI Chat as a compact "Ask anything…" composer bar, sharing the launcher's chat and history. It has its own per-display placement (`aiBarPosition`, excluded from backups) and expands into the transcript on the first message, animated. Placed low it grows **upward** with the composer docked at the bottom, transcript above, and a keycap `Actions ⌘K` beside the model name (no Send pill); the model/reasoning dropdowns then open upward too (`MenuPanelCorner.aboveHeaderTrailing`). Placed high/centre it grows down with the normal footer. `windowDidMove` and `endDrag` re-anchor/re-resolve the grow direction from the fixed edge so an upward resize can't drift. New Chat marks the session `startedFresh` so a close-and-reopen keeps the empty chat instead of resurrecting the last saved one. The bar is its own root, so an empty backspace stays in it rather than falling back to the launcher. The composer is multi-line: it wraps, shrinks its font (16pt, 14pt once wrapped), grows the bar to a six-line cap then scrolls, and takes ⇧↵ for a line break — measured off the shared field, which every other mode keeps as one line. Actions menu rows carry ⌘N / ⇧⌘C / ⌘Y / ⌘, shortcuts, wired for `.ai` mode. | Yes |
| Configured Assistants (named AI chat bars) | `Features/AI/Model/{Assistant,Skill}.swift` (new), `Features/AI/Service/{AssistantStore,SkillStore,ChatHistoryStore}.swift`, `Features/AI/Settings/{AssistantsSettingsSection,AssistantEditorSheet,SkillsSettingsSection,AISettingsView}.swift`, `Features/AI/UI/{AIChatCoordinator,AssistantTint+Color}.swift`, `Features/AI/Model/AIInstructions.swift`, `Features/MCP/UI/MCPCoordinator.swift`, `Features/HotKeys/{Model/HotKeyAction,Service/HotKeyManager}.swift`, `Features/Launcher/{Service/AppIndex,Service/VisibilityStore,UI/LauncherCoordinator}.swift`, `Features/Settings/{AppSettings,AppSettingsKey,SettingsAnchor,SettingsCoordinator}.swift`, `Features/Backup/Model/SettingsBackupCoverage.swift`, `Palette/{PaletteState,RootPaletteView}.swift`, `App/AppCore.swift`, `Tests/assistant-test.swift` (new), `Scripts/run-tests.sh` | Multiple user-created **Assistants** — named AI chat bars, each with its own shortcut, model, system prompt, Claude Agent **Skills**, MCP-server subset, web search, open policy, retention, per-display placement, width, glyph/tint and seed prompt. `PaletteState.activeAssistantID` re-points the single AI stack (`AIChatCoordinator.effectiveProvider`/`activeAssistant`, `AIInstructions.compose(skills:)`, `MCPCoordinator.tools(allowed:)`, open policy); `activeAssistant == nil` (default bar) is byte-for-byte unchanged. History is `assistant_id`-scoped (`ChatHistoryStore.scope`, NULL-preserving migration, ephemeral-skip). Each is a per-item hotkey (`HotKeyAction.assistant(id:)`) and an `AppEntry.Kind.assistant` "Ask <Name>" launcher command (feature-gated via `settingsOwner`, `aiAssistantsShowInLauncher` toggle). Managed in Settings → AI (Assistants list + editor sheet, Skills library). Assistants/Skills stores are JSON in `UserDefaults`, backup-excluded. Pluggable (plugin-provided) assistants are deferred — see `TODO.md`/`Assistant_Architecture.md` §19. | Yes |
| Per-assistant CLI tool calling (Claude & Codex MCP) | `Features/AI/Model/AICLIToolConfig.swift` (new), `Features/AI/Model/Assistant.swift`, `Features/AI/Service/{AIProviderFactory,InstalledAIManager,InstalledCLIProvider,CodexTurnRunner,ChatGPTSubscriptionManager}.swift`, `Features/AI/UI/AIChatCoordinator.swift`, `Features/AI/Settings/AssistantEditorSheet.swift`, `Features/MCP/UI/MCPCoordinator.swift`, `App/AppCore.swift`, `Tests/assistant-test.swift` | A per-assistant **Allow CLI tools** opt-in (off by default) lets an installed **Claude** (`claude -p`) or **Codex** (`app-server`) route run the assistant's enabled MCP servers as its *own* tools, instead of the sandboxed text-only default. `MCPCoordinator.cliToolConfig` builds a neutral `AICLIToolConfig` (Keychain secrets, never a backup) that each CLI formats: Claude gets `--mcp-config` + an `mcp__<slug>` `--allowedTools` allowlist (scoped to those servers — no shell/file) + raised `--max-turns` and drops its "don't use tools" prompt; Codex gets `config.mcp_servers` in `thread/start` + per-turn `networkAccess`. `Assistant` gains a decode-tolerant `init(from:)` so adding fields never drops saved assistants. `activeAssistant == nil` (default bar) and every non-CLI route are unchanged. | With plugins |
| Per-assistant CLI shell tools + environment variables | `Features/AI/Model/{AICLIToolConfig,Assistant}.swift`, `Features/AI/Service/{AssistantSecretStore.swift (new),InstalledCLIProvider}.swift`, `Features/AI/UI/AIChatCoordinator.swift`, `Features/AI/Settings/AssistantEditorSheet.swift`, `Features/MCP/UI/MCPCoordinator.swift`, `Platform/KeychainSecretStore.swift`, `Tests/assistant-test.swift` | A broader per-assistant **Allow shell tools** opt-in (off by default) lets an installed **Claude** CLI route run *shell* commands (`--dangerously-skip-permissions`), so a script-based **Skill** (e.g. Jira's `jira_query.py`) can execute — not just MCP tools. Paired with a per-assistant **Environment** editor: `NAME=value` lines stored one Keychain item per assistant (`AssistantSecretStore`, scope `assistant-environment`), never in UserDefaults or a backup, injected into the CLI process so a Skill's script can authenticate (`JIRA_TOKEN` etc.). `AICLIToolConfig` gains `allowShell`/`environment`; `MCPCoordinator.cliServers` returns the neutral server list. Shell tools are Claude-only for now (Codex disables its shell at the app-server launch — see `TODO.md`). | With plugins |
| GitHub Copilot CLI as an installed AI provider | `Features/AI/Model/{InstalledAI,AIConnection,InstalledAIStream,AICLIToolConfig}.swift`, `Features/AI/Service/{InstalledAIManager,InstalledCLIProvider,AIProviderFactory}.swift`, `Features/AI/UI/AIChatCoordinator.swift`, `Features/AI/Settings/{AISettingsStore,AISettingsView}.swift`, `Features/QuickActions/Settings/QuickActionsSettingsView.swift` | Adds `InstalledAIKind.copilot` (`copilot -p`, stdin prompt) as a fourth installed route alongside Codex/Claude/OpenCode, wired through every workflow: model selection + Codable, provider factory, the Providers list + toggle, the model picker groups, chat capabilities/icons/effort, and Quick Actions. Streaming decodes Copilot's `--output-format json` JSONL (`assistant.message_delta.deltaContent`, `result`); the probe reads readiness/models from `~/.copilot/config.json` (JSONC — parsed from the first `{`), catalog is `auto` + the account's `recentModelIds`. The CLI-tools opt-in formats Copilot's `--additional-mcp-config` and grants `--allow-all-tools` (MCP) or `--allow-all` (shell, so a Skill's script reaches its host); per-assistant env is injected for auth. Text-only by default (no `--allow-all-tools` → no tool auto-runs). | With plugins |
| Keep the floating AI Chat bar open on focus loss | `Features/Settings/{AppSettings,AppSettingsKey}.swift`, `Palette/PaletteWindowController.swift`, `Features/AI/Settings/AISettingsView.swift`, `Features/Backup/Model/SettingsBackupCoverage.swift` | A **Keep the floating bar open** toggle (Settings → AI → Chat, off by default) makes `AppSettings.aiBarStaysOpen` skip the resign-key auto-hide in `PaletteWindowController.windowDidResignKey` when the floating AI bar (`palette.aiBar`) is up, so it survives clicking into another app instead of closing on blur. Every other surface still hides normally, and the bar still closes on Escape / New Chat / re-summon. Backup-excluded as a per-Mac UI behaviour. | Yes |
| Stream the model's reasoning into chat (togglable) | `Features/AI/Model/{AIRequest,AIStreamDecoder,InstalledAIStream,ChatMessage,Assistant}.swift`, `Features/AI/Service/CodexTurnRunner.swift`, `Features/AI/UI/{AIChatState,AIScreen,ChatTranscriptView,ChatHistoryView}.swift`, `Features/AI/Settings/{AISettingsStore,AISettingsView,AssistantEditorSheet}.swift`, `Features/Settings/AppSettingsKey.swift`, `Features/Backup/Model/SettingsBackupCoverage.swift`, `Tests/ai-provider-test.swift` | `AIStreamEvent.thinking` now carries the reasoning text (was a bare signal that discarded it, so a reasoning model looked hung behind a lone spinner). Every decoder extracts it — API/OpenRouter (`delta.reasoning`/`reasoning_details[].text`), Anthropic + Claude CLI (`thinking_delta.thinking`) — and `AIChatState` accumulates it into `ChatMessage.reasoning` (live, not persisted). A collapsible "Thinking…" block streams it open above the answer, then folds when the answer begins. Gated by a global `AISettingsStore.showReasoning` (Settings → AI → Chat, on by default) with a per-assistant override (`Assistant.showReasoning`, editor's Model section), resolved `activeAssistant?.showReasoning ?? global`; backup-excluded as a per-Mac display choice. The empty streaming bubble now always labels itself "Thinking…". Note: reasoning **text** only exists on API-key routes — the CLI tools redact it (Claude `-p` sends `thinking:""`+signature) or omit it (Copilot streams only `reasoning_tokens` counts). | Yes |
