# Scheduler

The scheduler runs a **shell script** or posts a **notification** on a recurring rule — once, on an
interval, or daily / weekly / monthly — and catches up on fires missed while the app or the Mac was
Tasks are created, edited and deleted in **Settings → Scheduler** or from the launcher's own
in-palette editor, run automatically when due, and can also be run on demand from the launcher or a
global shortcut.

The pane carries the feature switch — off out of the box — and its launcher-visibility companion,
both in `AppSettings` and (with one deliberate exception, [below](#settings-and-backup)) in settings
backups. Switching the feature off cancels the pending wake and makes `SchedulerCoordinator.runTask`
refuse to run anything; the stored tasks and their per-task anchors stay put, so re-enabling resumes
without re-firing what was skipped.

## Invariants

- **`Model/` stays free of AppKit and SwiftUI.** `ScheduledTask`, `ScheduleEngine`,
  `NaturalDateParser` and `ScheduleFormatter` are Foundation-only and take the clock/calendar as
  injected parameters — `scheduler-test` compiles them, so this is enforced by compilation.
- **A task owns its own `lastFired` anchor.** Every fire records the *occurrence's* date via
  `store.markFired(id:at:)`, not the wall clock, and the next fire is computed from that anchor.
  Editing a schedule never double-fires and never drifts, because the anchor is the only source of
  "what has this task already done".
- **A disabled task is inert at the engine level.** `ScheduleEngine.nextFireDate` returns `nil` for a
  disabled task, so it never contributes to the wake target and `fireDue` never runs it — the
  `disabledTaskNeverFires` case in `scheduler-test` pins this.
- **Catch-up is bounded.** `SchedulerCoordinator.catchUpCap` (25) caps how many missed occurrences a
  single resume replays for one task, so a Mac that slept for a month cannot unleash a flood.
- **One pending wake for the whole set.** The coordinator holds a single `Task` timer, armed to the
  earliest `nextFire` across all tasks; any change to the task set or the feature switch cancels and
  re-arms it. There is never a timer per task.
- **A notification is a Tinycast panel, never `NSAlert` or `NSUserNotification`.** The
  `Notifications/` module posts through `NotificationPresenter` onto a per-corner stacking
  `NotificationPanel`, honouring the app-wide "Tinycast presents its own dialogs" rule.
- **The AI tool schedules notifications only.** `SchedulerAITool` (`scheduler__create_reminder`) can
  post a *future notification* but can never register a shell script — untrusted model output must not
  gain unattended code execution.

## Model and persistence

`ScheduledTask` is `Codable`/`Identifiable`: an id, name, `isEnabled`, a `ScheduleRule`, a
`ScheduledAction`, a `CatchUpPolicy`, its `lastFired` anchor and `createdAt`.

- `ScheduleRule` — `once(date:)`, `interval(seconds:)`, `daily(hour:minute:)`,
  `weekly(weekdays:hour:minute:)` (Calendar weekday integers, Sunday = 1) and `monthly(day:hour:minute:)`.
- `ScheduledAction` — `runScript(ScriptSpec)` or `postNotification(NotificationSpec)`.
- `CatchUpPolicy` — `skip` (advance the anchor, fire nothing), `fireOnceOnResume` (fire once, advance
  to the last missed) or `fireEach` (replay every missed occurrence up to the cap).

`ScheduledTaskStore` (`@MainActor @Observable`) is the single owner. It persists the array as JSON in
`UserDefaults` under `scheduledTasks`; a decode failure drops to an empty list rather than losing the
whole app's defaults. Its `onChange` hook is what the coordinator subscribes to, so any edit
reschedules and re-projects launcher rows.

`ScheduleEngine` is the pure math: `nextFireDate(for:after:calendar:)` gives the first occurrence a
task owes past an anchor, and `missedOccurrences(for:since:until:calendar:cap:)` enumerates the
catch-up set. `NaturalDateParser` turns a typed phrase ("tomorrow 9am", "in 20 minutes") into a
`once` rule for the editor, and `ScheduleFormatter.summary(of:)` renders the human line shown on each
row and as the launcher subtitle.

## Firing and catch-up

`SchedulerCoordinator.arm()` runs on `AppCore.start()` and whenever the switch or task set changes.
When enabled it first `catchUp()`s, then `reschedule()`s the single wake to the earliest `nextFire`.
On wake, `fireDue()` fires every task whose next occurrence is within a 0.5 s tolerance of now —
recording each via `markFired` before running it — then re-arms. Off cancels the timer.

`catchUp()` walks each enabled task from its own `lastFired ?? createdAt`, asks the engine for the
missed occurrences, and applies the task's `CatchUpPolicy`. Because the anchor is per task, a task
added while others were overdue only ever replays *its* history.

`perform(_:name:)` dispatches the action: a notification goes straight to `NotificationPresenter`; a
script runs through `ShellCommandRunner.run(loadingShellEnvironment: true, …)` off the main actor,
and — if the task set `notifyOnFinish` — a completion toast reports the last output line or a failure.

## Launcher and shortcut

An enabled task projects an `AppEntry` of `kind: .scheduledTask` (url `tinycast://scheduled-task/<uuid>`),
gated by both the feature switch and `schedulerShowInLauncher`. Selecting the row, or firing its
optional global shortcut (`HotKeyAction.scheduledTask`), calls `runTask(id:)`, which runs the action
immediately without touching the schedule or the anchor. `VisibilityStore` carries a matching
`.scheduledTask` category so the section can be toggled like any other.

The row's **⌘K actions** carry *Edit* and *Delete* — both open through `SchedulerEditorCoordinator`,
not Settings: edit opens the in-palette `SchedulerEditorScreen` (palette mode `.schedulerEditor`), a
two-column form sized to fit the fixed launcher panel without scrolling; delete confirms through the
app's own `DialogController` (never an `NSAlert`). Creating one is the `createScheduledTask` command
(`Create Scheduled Task`), an owned command of the Scheduler pane gated by the same two flags, so it also
carries an alias and optional shortcut in **Settings → Scheduler → Commands**.

The in-palette editor and the Scheduler pane's `SchedulerTaskEditorSheet` render the *same*
`SchedulerTaskControls`, both bound to a shared `ScheduledTaskDraft`, so a restyle lands on both
surfaces; only the arrangement and the actions chrome differ. The palette form owns no buttons of its
own — Save/Add rides the launcher's shared footer `ActionBar` on ↵, and Delete sits under ⌘K while
editing — whereas the sheet keeps its own Cancel/Save. Neither reads `@Environment(\.dismiss)`;
dismissal is injected.

## AI tool

Whenever the feature is on, `AIChatCoordinator` offers `SchedulerAITool` to the model alongside the
MCP tools. It creates a notification-only task from a natural-language time, so the assistant can set
a reminder — but, by the [invariant above](#invariants), it can never schedule a script.

The tool reaches every route that runs host tools, not just the HTTP ones. An API connection hands
each call back through `AIToolLoopProvider`; the on-device Apple Intelligence model instead runs it
in-process, so `toolAware` arms `AppleIntelligenceProvider.executingHostTools`.
`AppleIntelligenceHostTool` bridges the `AITool` onto a `FoundationModels.Tool` — its
`AppleIntelligenceToolSchema` turns the JSON-Schema parameters into a `GenerationSchema`, and each
call reports a `.toolCall`/`.toolResult` pair into the same stream a loop route would.

## Settings and backup

`schedulerEnabled` and `schedulerShowInLauncher` live in `AppSettings`/`AppSettingsKey`.
`schedulerShowInLauncher` is backed up like every other show-in-launcher flag. `schedulerEnabled` is
in `SettingsBackupCoverage.deliberatelyExcluded`: it doubles as consent to run a script or action
unattended, so — like `snippetsEnabled`, `calendarEnabled` and `cameraPreview` — an imported backup
must never be able to arm the machine to fire on a timer by itself.

## Notifications module

`Features/Notifications/` is the surface the scheduler (and the AI tool) post to, but it owns nothing
scheduler-specific. `NotificationSpec` describes one notification (title, body, `style`, `corner`,
`dwell`, `actions`); `NotificationPresenter` stacks live cards per screen corner on a floating
`NotificationPanel`; `NotificationPlacement` resolves the corner geometry; `NotificationCardView`
draws one. Nothing here uses `NSAlert` or a system notification.

## Manual checks

`scheduler-test` covers the engine math exhaustively — every rule shape, DST boundaries, and the
natural-date parser — but the live coordinator → notification path and the Settings / launcher
surfaces are driven by hand per [UI_TESTS.md](../../custom_docs/UI_TESTS.md): seed a task due shortly,
confirm the Scheduler pane lists it, the launcher shows the row, and the notification fires on time.
