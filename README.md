# Toolbox

A native macOS app (SwiftUI, macOS 26+) that bundles 41 everyday tools for video, audio, images,
PDFs, on-device AI and file batches in one window. Everything runs locally: no account, no uploads.

## Build

Requirements: Xcode 26+, [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```sh
scripts/build.sh            # compile check (unsigned)
scripts/build.sh --sign     # signed Debug build
scripts/build.sh --release  # signed Release build
xcodegen generate && open Toolbox.xcodeproj   # work in Xcode
```

The Xcode project is generated from `project.yml` and is not committed.

FFmpeg and yt-dlp are **not bundled**. Video/audio tools need FFmpeg; Download Video needs yt-dlp.
The app finds Homebrew installs automatically and offers one-click `brew install` otherwise
(Settings › Dependencies). Image, PDF, OCR and transcription tools need nothing extra.

## How it works

- **One window**: sidebar of tools + a home screen with search and suggestions.
  `⌃⌥Space` summons it from any app; `⌘K` searches; `⌘1`–`⌘4` open the featured groups.
- **Originals untouched**: each job writes into a private staging folder. Only when the whole batch
  succeeds is it moved to a new dated folder, by default `~/Downloads/Toolbox/<Tool> <date>`.
  Change this in Settings (custom folder or ask every time).
- **Reduce Motion** is respected automatically.

## Code layout

```
Toolbox/
  App/        App entry, menus, global hotkey, navigation model
  Core/       Tool registry, job runner + output publishing, FFmpeg/process runners,
              dependency installer, on-device transcription, subtitle formats
  UI/         Main window, home, settings, shared components (ToolPage, BatchToolView,
              FileListInput, JobBar, PlayerView, RangeSlider…)
  Tools/      One folder per category; <Category>Tools.swift registers that category's tools
```

### Adding a tool

1. Write a view in `Tools/<Category>/`. Most tools are a `BatchToolView` with an options view and
   a work closure (see `Tools/Video/CompressVideoView.swift`). Custom UIs compose `ToolPage`,
   `FileListInput` and `JobBar` with a `JobRunner` from `JobCenter.shared.runner(for: tool.id)`.
2. Write outputs only to URLs from `context.output(...)`; the runner publishes them.
3. Register it in that category's `<Category>Tools.swift`.
