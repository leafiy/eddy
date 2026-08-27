<!-- leafiy-family:begin — managed block. Source: leafiy-ui/templates/APP_AGENTS.md + docs/component-map.md. Regenerate with `sh ../leafiy-ui/scripts/sync-app-agent-docs.sh`; edits here are overwritten and fail the contract. -->
# Leafiy App Family — agent rules

This repository is one member of the Leafiy macOS App Family. The Base Library
`../leafiy-ui` (a sibling checkout) owns every non-domain part of this app and
is the source of truth for architecture, look, storage, and release. You are
here to add domain behavior, not to design app infrastructure.

## Read first, every task

1. `../leafiy-ui/CONTEXT.md` — family glossary; use its terms, not synonyms.
2. `../leafiy-ui/docs/adr/` — binding decisions. Do not relitigate them in code.
3. The Component Map below — need → Base Library API → forbidden alternative.
4. `../leafiy-ui/template-app/` — the reference implementation of every row.
   `../daisy` is the Canonical App: when apps disagree, daisy's usage wins.
5. This repo's `CONTEXT.md` and `docs/adr/` — domain vocabulary and domain-only
   decisions. Anything about chrome, windows, settings, storage, shortcuts,
   updates, or look is decided in leafiy-ui, never here.

## Hard rules

- One dependency: `.package(path: "../leafiy-ui")`. Never copy Base Library
  code into this repo, never add a second shared package.
- Family Chrome (lifecycle, menu bar, windows, settings scaffold, About,
  updates, shortcuts, icon mode) is used through the closed entry points in the
  Component Map. Never assemble it locally, never fork its copy.
- One storage story: one `AppSettings` in plaintext `settings.json` via
  `LeafiySettingsStore`. No `UserDefaults`, no `@AppStorage`, no Keychain, no
  migration code.
- System-Native First: system controls, system text styles, semantic colors,
  `LeafiyDesign` tokens. No literal sizes, colors, radii, materials, or custom
  chrome.
- If the Base Library lacks what you need: stop and follow the Gap Protocol.
  Building it locally is the one thing this family forbids most.
- Prefer small native utilities over service- or account-heavy architecture.
- Preserve the repo's existing file layout and Swift style.

## Before you finish

- Run `sh ../leafiy-ui/scripts/check-app-family-contract.sh .` and fix every
  `error:`. On an authoring-only machine this is the one command you may run;
  it executes nothing but `grep`/`awk`/`sed` over the sources.
- Every marker you add carries a reason. Markers are for domain canvases and
  declared gaps, never for convenience.
- Do not run builds, tests, or release scripts unless the user asks; report
  what you could not verify.

## Component Map

# Component Map

Need → Base Library API → what you must not write instead. Every row is
binding (ADRs in `docs/adr/`). `template-app/` demonstrates each row once;
`daisy` is the tie-breaker when apps disagree. If the thing you need has no
row, follow the Gap Protocol at the end — never improvise in the app.

## App structure

| I need | Use | Never |
|---|---|---|
| The Base Library | `.package(path: "../leafiy-ui")`, products `LeafiyUI` + `LeafiyUICore` (ADR-0001) | any other shared package, copied Base Library files, a second shared repo |
| App entry and lifecycle | `@main struct: App` + `@NSApplicationDelegateAdaptor(LeafiyAppDelegate.self)`; subclass `LeafiyAppDelegate` only to override `leafiyApplicationDidFinishLaunching`/termination hooks (ADR-0006) | `NSApplicationDelegate` from scratch, `applicationDidFinishLaunching`, `NSApp.setActivationPolicy`, `LeafiyAppBootstrap.start()` |
| Domain logic | `<App>Core` target (platform-neutral, Linux-testable) | UI-less logic inside the executable target |
| App identity (name, version, bundle ID, update feed, menu icon) | `Info.plist` once; read via `LeafiyAppIdentity.current` (ADR-0006) | repeating those values in views or strings |
| Menu-bar icon and menu | `LeafiyMenuBarExtra { LeafiyFamilyMenu(language:) { domain items } } label: { LeafiyMenuBarLabel(status:) }`; value utilities use `LeafiyMenuBarValueLabel`; panel apps declare `style: .window` (ADR-0010) | `MenuBarExtra`, `NSStatusBar`, `NSStatusItem`, `LeafiyMenuTail(` assembled locally, own Quit/Settings items |
| Menu-bar state (busy/success/failure) | `LeafiyMenuBarStatus` passed to the label | custom icon drawing, badges |
| Main or auxiliary window | `Window(...) { content.leafiyWindow(id:role:) }`; raise with `LeafiyWindowPresenter.presentWhenAvailable { LeafiyWindowRegistry.window(id:) }` (ADR-0004/0007) | `NSWindow(`, `NSApp.windows.first`, title matching, `orderFrontRegardless` on hosts |
| Non-activating floating panel | `LeafiyFloatingPanel(configuration:content:)` | `NSPanel(`, internal host windows |
| Dock vs menu-bar presence | `LeafiyApplicationIconMode` bound through the General Pane (ADR-0008) | own toggles, `NSApp.setActivationPolicy`, `LSBackgroundOnly` |
| Settings window | `Settings { LeafiyFamilySettings(language:) { LeafiyFamilyGeneralPane(...) ; domain SettingsPane(...) } }`; open with `LeafiySettingsWindow.open()` | `SettingsLink`, `SettingsScaffold {` or `AboutPane(` assembled locally, custom settings window |
| General pane rows (language, launch at login, icon mode, shortcut, tail rows) | `LeafiyFamilyGeneralPane` or `LeafiyGeneralPane(language:launchAtLogin:applicationIconMode:shortcuts:tail:)` | own language picker, own launch-at-login row, own Dock/menu-bar toggles |
| Domain settings tab | `SettingsPane(title, systemImage:) { Section { Toggle / Picker / TextField / Stepper / LabeledContent } }`, instant-apply | Save/Cancel buttons, custom forms, `Form` outside `SettingsPane` |
| Persisting settings and secrets | one `AppSettings: LeafiyAppSettings` + `LeafiySettingsStore.standard(directoryName:)`; secrets are ordinary fields; privacy copy says "plain text" (ADR-0002) | `UserDefaults`, `@AppStorage`, Keychain / `SecItem*`, a second file, migration code for legacy stores |
| Transient per-run state (throttles, caches) | in-memory properties | `UserDefaults` |
| Launch at login | `LeafiyLaunchAtLogin.setEnabled(_:)` | `SMAppService` directly |
| Global or app-wide shortcut | `KeyboardShortcutSpec` + `LeafiyHotKeyCenter(signature:)` + `LeafiyShortcutMenuButton` inside `.commands` + `ShortcutField` in settings (ADR-0005) | Carbon `RegisterEventHotKey`, own parser/editor, shortcut strings duplicated between menu and hotkey |
| About, version, update checks and copy | provided by `LeafiyFamilySettings` and `LeafiyFamilyMenu` | calling `SoftwareUpdateController` directly, update strings in the app, an About view |
| Localization | `L(_:)` built on `LeafiyLocalization.string(_:bundle:)` with `LeafiyLocalization.moduleBundle(package:target:)` | `NSLocalizedString` boilerplate, `Bundle.module` lookup copies |
| Quick Share (upload to the user's bucket) | `QuickShareSettings` + `QuickShareUploader` + `QuickShareSettingsPane` | own S3 signing or upload |
| File drops on a view | `.leafiyFileDrop(isTargeted:perform:)` + `.leafiyDropHighlight(_:)` (ADR-0009) | `onDrop(of: [.fileURL])`, own highlight overlay |
| File drops on the menu-bar icon | `LeafiyMenuBarDropTarget` | own status-item drag handling |
| Dragging files out (lazy) | `LeafiyFilePromise` + `.leafiyFilePromiseDragOut` / `.leafiyFilePromisesDragOut` | `NSFilePromiseProvider` plumbing, `onDrag` with own providers |
| Diagnostics (`--leafiy-doctor`) | `LeafiyDiagnostics.doctorReport` / `writeLaunchReport` | own report format |
| Confirmation, notice, or error alert | `LeafiyAlert.confirm(_:message:confirmTitle:cancelTitle:style:destructive:) -> Bool`, `LeafiyAlert.notice(_:message:style:buttonTitle:)`, `LeafiyAlert.error(_:message:)`; test the copy via `confirmPresentation` / `noticePresentation` | `NSAlert()`, own activation or button order, `.alert` sheets for app-wide prompts |
| Open or save file panel | `LeafiyFilePanel.chooseFile(types:…)`, `chooseFiles(types:allowsFolders:…)`, `chooseFolder(directory:canCreateDirectories:…)`, `save(suggestedName:types:…)`; test via `fileConfiguration` / `filesConfiguration` / `folderConfiguration` / `SaveConfiguration` | `NSOpenPanel()`, `NSSavePanel()`, `.fileImporter`, `.fileExporter` |

## Look (System-Native First, ADR-0003)

| I need | Use | Never |
|---|---|---|
| Empty content area | `EmptyStateView(systemImage:title:subtitle:)` | own placeholder |
| Bottom status strip | `FooterBar { }` | own divider + bar |
| Inline control strip | `ControlBar { }` | own toolbar-like HStack with background |
| Primary content container | `LeafiyCard { }` | `RoundedRectangle` backgrounds, hand-drawn cards |
| Transient feedback | `.leafiyToast(message)` | custom overlay, `NSAlert` for success |
| Spacing | `LeafiyDesign.Spacing.xxs…xxl` (`0` is allowed for attached stacks) | literal numbers in `padding` / `spacing` |
| Corner radius | `LeafiyDesign.Radius.control / card / panel` | literal `cornerRadius` |
| Fixed sizes the system does not provide | `LeafiyDesign.Size.*` (settings pane, min window, icons) | new size constants scattered in views |
| Text size | system text styles `.body .callout .subheadline .footnote .caption`, weight via `.weight(_:)`, mono via `.monospaced()`; symbols via `LeafiySymbolText.font(_:)` | `.font(.system(size:))`, `NSFont.systemFont(ofSize:)` (user-chosen document fonts are an Explicit Exception) |
| Color | semantic system colors (`.primary .secondary .tertiary`, `Color.accentColor`, `Color(nsColor: .separatorColor)` …); `.red` only for failure | RGB/hex/gray literals, `Color.white/black/gray`, `NSColor(srgbRed:…)` |
| Backgrounds and materials | a Base Library component; else system materials (`.bar`, `.regularMaterial`) | `NSVisualEffectView`, hand-drawn backgrounds, `#available(macOS 26)` appearance forks, custom window chrome (daisy minimal mode is the registered Explicit Exception) |
| Control appearance | system styles (`.bordered .borderless .plain`, `.formStyle(.grouped)`) | own `ButtonStyle` / `ToggleStyle` / `ViewModifier` for chrome |
| Window minimum size | `LeafiyDesign.Size.mainWindowMinWidth/Height` | ad-hoc minimums |

## Not in the Base Library yet (declare with `leafiy-gap:`)

| I need | Status | Until it lands |
|---|---|---|
| — | no open gaps (LeafiyAlert and LeafiyFilePanel closed the last two) | when a new one appears, add a row here with its issue path |

## Gap Protocol

When the map has no row for what you need:

1. Stop. Do not build it in the app.
2. Add it to the Base Library first: platform-neutral logic in `LeafiyUICore`, macOS UI/services in `LeafiyUI`; add a contract check or test; adopt it in `template-app` and, where relevant, `daisy`; add the row here.
3. Only if this task cannot touch leafiy-ui: file an issue under `leafiy-ui/.scratch/base-library-gaps/issues/`, add the row to the table above, and mark every app-local call site with `// leafiy-gap: <Component>`. The contract lists every gap so it cannot be forgotten.

A second convention beside an existing one is never acceptable — extend the existing one.

## Markers the contract understands

- `// leafiy-exception: <reason>` on the offending line or the line above — a deliberate, permanent, domain-justified deviation (user-picked colors, pixels rendered into an exported image, a registered Explicit Exception). The reason is mandatory.
- `// leafiy-exception-file: <reason>` within the first 20 lines — the whole file is a domain canvas (an image compositor, a color-picker row).
- `// leafiy-gap: <Component>` / `// leafiy-gap-file: <Component>` — same placement rules; temporary, tied to a gap issue.

`scripts/check-app-family-contract.sh` fails on any unmarked hit and prints an inventory of all exceptions and gaps so they stay visible. A marker without a reason is a failure.

<!-- leafiy-family:end -->

## App-local notes

Domain vocabulary lives in `CONTEXT.md`; domain-only decisions in `docs/adr/`.
