# Toolbox

A native macOS app (SwiftUI, macOS 26+) that bundles 41 everyday tools for video, audio, images,
PDFs, on-device AI and file batches in one window. Everything runs locally: no account, no uploads.

## Build

Requirements: Xcode 26+, [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```sh
scripts/build.sh            # compile check (unsigned)
scripts/build.sh --sign     # signed Debug build
scripts/build.sh --release  # signed Release build
scripts/release.sh          # Developer ID–signed, notarized DMG (see script header)
xcodegen generate && open Toolbox.xcodeproj   # work in Xcode
```

The Xcode project is generated from `project.yml` and is not committed.

FFmpeg and yt-dlp are **not bundled**. Video/audio tools need FFmpeg; Download Video needs yt-dlp.
The app finds Homebrew installs automatically and offers one-click `brew install` otherwise
(Settings › Dependencies). Image, PDF, OCR and transcription tools need nothing extra.

## Tools (41)

| Category | Tools |
|---|---|
| Video (13) | Record Screen (studio: display/window/area, camera bubble, auto-zoom on clicks, trim, captions), Download, Compress, Convert, Trim, Resize, Crop & Rotate, Change Speed, Merge, Mute, Replace Audio, Burn In Subtitles, Video to GIF |
| Audio (5) | Record, Trim, Clean Up (noise removal + loudness), Extract, Convert |
| Images (6) | Convert, Compress, Resize, Rotate, Remove Background (Vision), Remove Metadata |
| PDF (11) | Merge, Split, Organize, Delete Pages, Extract Pages, Compress, Sign, Add Password, Remove Password, Images to PDF, PDF to Images |
| On-device AI (5) | Transcribe (SpeechAnalyzer → TXT/SRT/VTT), Dictation, Extract Text (Vision OCR), Summarize (Foundation Models), Translate (Translation framework) |
| Files (1) | Batch Rename (copies by default, or in place with undo) |

Notes:
- Summarize needs Apple Intelligence enabled on a supported Mac; the tool explains when it isn't available.
- Speech and translation models are one-time system downloads; the tools offer to download them.
- Download Video depends on a current yt-dlp (sites change often). The tool has an "Update yt-dlp" button.
- Homebrew's FFmpeg has no libass, so subtitles and captions are rendered with AVFoundation instead.

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
