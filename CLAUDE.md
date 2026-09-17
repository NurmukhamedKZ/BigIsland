# CLAUDE.md

Guidance for Claude Code when working in this repository. User-facing docs: `README.md`. Talk to the user in Russian; code comments are in Russian too.

## What this is

BigIsland — native macOS menu-bar-less app (Swift 6 / SwiftUI + AppKit, SwiftPM, no Xcode project). A black "island" under the MacBook notch that expands on hover and hosts pluggable features (tabs). Features: screenshots tray, pomodoro stopwatch with study history.

User priorities, in order: **speed, smoothness, easy to add/remove features.**

## Build & run

```sh
pkill -x BigIsland; ./build.sh && open build/BigIsland.app
```

- `build.sh` = `swift build -c release` + hand-made `.app` bundle (`Info.plist` with `LSUIElement`, `NS*FolderUsageDescription`) + ad-hoc `codesign` with a designated requirement on the bundle id (so the TCC folder permission survives rebuilds).
- Only Command Line Tools are installed (`xcodebuild` is unavailable) — don't suggest Xcode-only steps.
- No XCTest/Testing without Xcode. Logic checks live in `selfTest()` (in `PomodoroFeature.swift`), run with `swift run BigIsland --selftest`.
- Verify UI visually: `screencapture -x -R x,y,w,h out.png` of the notch area. Main screen is 1710×1107 pt, notch centered at x=855. Synthetic hover needs posting a `CGEvent` `.mouseMoved` (a small swiftc helper); the user may be moving the real mouse at the same time, so a failed hover capture is not necessarily a bug — retry. Synthetic clicks need ~50–80 ms between mouseDown and mouseUp, otherwise SwiftUI buttons highlight but don't fire.
- Pomodoro history is the user's real data (`~/Library/Application Support/BigIsland/pomodoro.json`). If a test adds study time, quit the app, remove it from the JSON, relaunch.

## Architecture

- `main.swift` — `NSApplication` with `.accessory` activation policy.
- `AppDelegate.swift` — **feature registry** (`features` array), one `IslandController` per `NSScreen` (rebuilt on `didChangeScreenParametersNotification`), one global `NSEvent` monitor for `.mouseMoved`/`.leftMouseDragged` fanned out to all islands.
- `Island/IslandController.swift`
  - `IslandModel` (`ObservableObject`): `isExpanded`, `selectedFeatureID`, notch size, `size`/`expandedSize` (height = selected feature's `contentHeight`), `maxExpandedSize` (panel size).
  - `IslandController`: borderless non-activating `NSPanel` at `.mainMenu + 3`, all Spaces + fullscreen. Notch size from `safeAreaInsets.top` and `auxiliaryTopLeft/RightArea`; screens without a notch get an invisible 200 pt zone.
  - Hover: collapsed → global monitor checks `hotRect` (notch). Expanded → `ignoresMouseEvents = false` and a 30 Hz timer polls `NSEvent.mouseLocation` against `expandedRect` (the global monitor doesn't see events over our own window). Doesn't collapse while a mouse button is pressed (drag in progress).
  - `FirstMouseHostingView` — clicks work without activating the app.
  - `KeyPanel` (`canBecomeKey = true`) — text fields accept typing without activating the app. On collapse, if the panel is key, `orderOut` + `orderFrontRegardless` hands the keyboard back to the previous app.
- `Island/IslandView.swift` — black `UnevenRoundedRectangle`-clipped shape; header row of feature tabs + quit button (center left empty for the camera); selected feature's `makeView()` below.
- `Island/Theme.swift` — design tokens, spec in `DESIGN.md` (read it before any UI work): one accent `#2997ff` (fill `#0066cc` for primary pills), tile `#272729`, weights 400/600 only, radius 8 for cells/thumbnails, capsules for buttons, `PressStyle` (scale 0.95), no shadows. Use these tokens in new UI.
- `Features/IslandFeature.swift` — protocol: `id`, `title`, `icon` (SF Symbol), `contentHeight` (default 150), `start()`, `stop()`, `makeView() -> AnyView`. `@MainActor`. Tab switch animates height with `IslandView.spring`.
- `Features/Screenshots/ScreenshotsFeature.swift`
  - Folder: `DispatchSource` `.write` on the folder from `com.apple.screencapture` `location` (currently `~/Documents/Screenshots`), diffing a set of visible image filenames. Read once at start.
  - Clipboard: polls `NSPasteboard.general.changeCount` every 0.5 s; takes any `png`/`tiff` unless the pasteboard has `.fileURL` (Finder copies); writes PNG to `$TMPDIR/BigIsland/` (wiped on start) off the main thread.
  - Thumbnails via `CGImageSourceCreateThumbnailAtIndex` (max 360 px) off main. Max 40 shots, in-memory only.
  - Drag out: `.onDrag { NSItemProvider(contentsOf: url) }`.
  - Folder `open()` runs off the main thread: first access to ~/Documents triggers a blocking TCC prompt.
- `Features/Pomodoro/PomodoroFeature.swift`
  - Phases `idle/study/rest`, **no auto-switching**: study runs until "Отдых", rest until "Учиться". Targets 50 / 10 / 30 min (long rest after 4 completed studies) only play a sound (`Glass`/`Hero`) via a one-shot `Timer`; the stopwatch keeps counting.
  - Persistence: `~/Library/Application Support/BigIsland/pomodoro.json` = `{days: {"yyyy-MM-dd": seconds}, session}`. Atomic writes on every phase change and every 60 s during study (`flush`, split across midnights by `split`). On decode failure: back up to `pomodoro.broken-*.json` and set `canSave = false` — **never overwrite history**.
  - On launch, a study gap > 120 s since `lastFlush` is not counted.
- `Features/Pomodoro/PomodoroView.swift` — `TimelineView` 1 Hz stopwatch (no per-second `@Published`), ISO-week month calendar (`Calendar(identifier: .iso8601)`), cells show studied time instead of the day number. Colors: study = `Theme.accent`, rest = `Theme.muted`.
- `Features/Speech/SpeechFeature.swift` — TTS: `x-ai/grok-voice-tts-1.0` (voice `eve`, mp3) via OpenRouter `/api/v1/audio/speech`. A paste into the `TextEditor` (text grows by >1 UTF-16 unit) starts speaking. Text is split by `NLTokenizer` sentences into chunks (first ≤ 200 chars for a fast start, then ≤ 1500), fetched sequentially at most 2 chunks ahead of playback, played one by one with `AVAudioPlayer`. Downloaded mp3s stay in memory for `spokenText`: while the field text equals it the primary button is «Повтор» (replay from cache, fetches only missing chunks); any edit turns it back into «Озвучить» and the next speak drops the cache. Stop cancels in-flight fetches but keeps the cache. Key: env `OPENROUTER_API_KEY`, otherwise `~/Library/Application Support/BigIsland/.env` (`envValue` parser, covered by selftest). Not Keychain: with the ad-hoc signature macOS asks for the login password after every rebuild — don't move it back. The model was chosen by the user after comparing samples in `tts-compare/compare.sh`.
- `PillButton` (in `Theme.swift`) — shared primary/secondary capsule button.

## Invariants — don't break these

- **Never animate the window frame.** The panel is created at max size; only the SwiftUI shape inside animates. Collapsed panel must have `ignoresMouseEvents = true` so it's click-through.
- Expanded content has a **fixed frame** (`expandedSize`) so it scales instead of reflowing while the shape resizes, and the shape **clips** it.
- Content transition is symmetric: `.scale(0.3, anchor: .top) + .opacity`, `easeIn 0.15` — faster than the shape spring (`response 0.38`) so content never lags behind. Values were tuned by the user by hand; don't change without being asked.
- The "flash on new screenshot" (peek) feature was deliberately removed at user request — don't re-add.
- No base classes, no plugin loading, no event bus. Add capabilities only when a real feature needs them.
- Study history must never be lost or silently reset.
- Swift 6 compiler in Swift 5 language mode (`Package.swift`). Callbacks from timers/monitors/dispatch sources hop into `MainActor.assumeIsolated { … }`; background work uses `Task.detached` + `nonisolated static` helpers.

## Adding a feature

New folder `Features/<Name>/`, a `@MainActor final class …: ObservableObject, IslandFeature`, and one line in `AppDelegate.features`. Keep `start()` cheap and event-driven; idle CPU should stay ~0.
