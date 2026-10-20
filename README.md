# Toolbox

A native macOS app (SwiftUI, macOS 26+) with 83 tools for media, photos, PDFs, documents,
archives, on-device AI and small-business billing. Includes Tangerine-style drag wheels, the 275
advertised conversion routes (plus PDF → HTML), ihatepdf.cv's PDF suite and six file actions.
Processing runs locally: no account, no uploads.

## Build

Requirements: Xcode 26+, [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```sh
scripts/build.sh            # compile check (unsigned)
scripts/build.sh --sign     # signed Debug build
scripts/build.sh --release  # signed Release build
scripts/test.sh             # native integration tests with generated fixtures
scripts/release.sh          # Developer ID–signed, notarized DMG (see script header)
scripts/build-dmg.sh        # ad-hoc signed universal DMG, no Apple account needed
xcodegen generate && open Toolbox.xcodeproj   # work in Xcode
```

The Xcode project is generated from `project.yml` and is not committed.

GitHub Actions builds the DMG with `scripts/build-dmg.sh`. Push a tag like `v0.1.0` to publish
`Toolbox-0.1.0.dmg` as a GitHub release, or run **Build DMG** from the Actions tab to get the DMG
as a run artifact.

External engines are **not bundled**. Settings › Dependencies detects Homebrew installations,
allows custom executable paths and offers installation:

| Dependency | Used for |
|---|---|
| FFmpeg | Video/audio conversion and editing |
| yt-dlp | Download Video |
| LibreOffice | PPT/PPTX and XLS/XLSX/ODS conversions (CSV/TSV only to other spreadsheet formats); Word PDF layout when available |
| ExifTool | Read/edit/remove metadata across images, media and PDFs |
| WebP (`cwebp`) | WebP encoding when ImageIO cannot write it |
| libavif (`avifenc`) | AVIF encoding |
| Calibre (`ebook-convert`, cask) | MOBI/AZW3/AZW/FB2 ebook conversions |

Apple Pages must be installed for PAGES import/export; macOS asks for Automation permission.
Core image/PDF tools, OCR, subtitles, EPUB packaging and ZIP/TAR/GZIP extraction need no extra engine.

## Tools (83)

| Category | Tools |
|---|---|
| Video (16) | Record Screen (studio: display/window/area, camera bubble, auto-zoom on clicks, trim, captions), Download, Compress, Convert, Trim, Resize, Crop & Rotate, Change Speed, Merge, Mute, Replace Audio, Burn In Subtitles, Video to GIF, Split, Snapshots, Redact |
| Audio (10) | Record, Trim (including silence at ends), Clean Up (noise removal + loudness), Extract, Convert, Compress, Normalize, Channels, Visualize, Bleep |
| Images (14) | Convert, Compress, Resize, Rotate, Remove Background (Vision), Remove Metadata, Edit, Annotate, Add Background, Crop, Redact, Collage, Read QR Codes, Whiteboard (live drawing with browsers on your network) |
| PDF (27) | Merge, Split, Organize, Delete Pages, Extract Pages, Compress, Sign, Add Password, Remove Password, Images to PDF, PDF to Images (up to 600 DPI, optional ZIP), Edit (retype text, text boxes, images, signatures), Compare, Rotate, Crop & Resize, Watermark, Page Numbers, Headers & Footers, Invert Colors, Flatten, Fingerprint, Make Searchable (OCR), Scan (iPhone/iPad/Mac camera), Redact (burned in, text removed), Create PDF (rich text/HTML/Markdown), Repair, Privacy Scan |
| On-device AI (7) | Transcribe (SpeechAnalyzer → TXT/SRT/VTT/PDF), Dictation, Extract Text (Vision OCR), Summarize (Foundation Models), Translate (Translation framework), Chat with PDF (Foundation Models, cited pages), PDF to Audio (speech synthesis) |
| Files (7) | Convert Files, File Actions, Extract Archive, Create Archive, Edit Metadata, Batch Rename (copies by default, or in place with undo), Share on Wi-Fi (link + QR for any browser on your network) |
| Business (2) | GST Invoice (CGST/SGST/IGST, GSTIN checks, PDF), POS Billing (catalog, barcode input, 58/80 mm receipts, UPI QR) |

Convert Files supports images (including SVG input and AVIF/WebP output), video/GIF/MP3, all eight
audio formats, PDF → Word/Pages/PowerPoint/Excel/EPUB/HTML/text/Markdown/images, Office documents,
spreadsheets, slides, EPUB, Kindle books (MOBI/AZW3/AZW/FB2 through Calibre), SRT/VTT/TXT and
ZIP/TAR/GZIP (RAR input). HTML, Markdown and EPUB are laid out with WebKit, so CSS, tables and
pictures survive; CSV/TSV become paginated PDF tables without LibreOffice. PDF → HTML keeps each
page's look with a selectable text layer, or reflows the text. PDF images export every page
at 300 DPI. See [feature coverage and limits](docs/Tangerine-features.md).

Notes:
- Summarize needs Apple Intelligence enabled on a supported Mac; the tool explains when it isn't available.
- Speech and translation models are one-time system downloads; the tools offer to download them.
- Download Video depends on a current yt-dlp (sites change often). The tool has an "Update yt-dlp" button.
- Homebrew's FFmpeg has no libass, so subtitles and captions are rendered with AVFoundation instead.

## How it works

- **Drag wheels** (off by default; turn on in Settings › Drag Wheel): start dragging files in Finder
  and tap Shift for conversions, Command for tools,
  or Control for file actions. Release the key and continue dragging; drop on a segment to apply it.
  The conversion wheel offers only formats shared by every selected file. Keys are configurable in
  Settings › Drag Wheel. The menu bar's **File Wheel for Finder Selection** supports arrow keys,
  Return and Escape. Global keyboard events may require Input Monitoring; mouse dragging works
  without enabling global keyboard navigation.
- **File actions**: AirDrop opens the macOS recipient picker; Float holds a reusable shelf above other
  apps with left/right screen pinning; Copy writes file references to the clipboard; Move asks for a
  destination without overwriting names; Copy Path writes one path per line; Terminal opens selected
  folders or containing folders in Terminal or iTerm2. Mixed selections and folders are supported.
- **Compression targets**: images, video, audio and PDFs support target sizes and percentage reduction.
  Image size targets may reduce dimensions; PDF size targets render pages as images. Media size
  targets are estimates constrained by encoder bitrates and container overhead.
- **One window**: sidebar of tools + a home screen with search and suggestions.
  `⌘K` searches; `⌘1`–`⌘4` open the featured groups.
- **Quick launcher** (Raycast-style): `⌃⌥Space` in any app, or a click on the menu bar icon, opens a floating search panel with
  Favorites, Suggestions and every tool by category. `↑`/`↓` to pick, `↩` to open, `⌘K` for actions,
  `⌘⇧F` to favorite, `⌘⌥↑/↓` to reorder favorites, `⌘↩` for the main window, `esc` to close.
  Invoked from Finder, it suggests tools for the selected files and hands them over (`⌥↩` opens
  without them). 21 tools run on those files without opening the window (Compress, Convert, Resize,
  Change Speed, Merge, Mute; Clean Up, Extract and Convert Audio; Convert, Compress, Resize, Rotate,
  Remove Background/Metadata for images; Merge, Compress, Images to PDF, PDF to Images; Extract Text,
  Transcribe): `↩` runs with the last-used options, `⇥` shows the tool's options inside the launcher
  first (Resize, Rotate and Change Speed always do). The options work like a Raycast form, without the
  mouse: `↑`/`↓` or `⇥` move between them, `←`/`→` change a choice or slider (`⇧` for big steps),
  `space` ticks a checkbox, typing picks a matching choice, and number fields take typing directly.
  A small HUD shows progress and the results are
  selected in Finder. Combining tools use the files in name order. `⇧↩` opens the tool instead. The
  shortcut and the run-right-away behavior are configurable in Settings › General.
  Everything also works with the mouse, following Raycast 2's patterns: click a tool to run it,
  hover it for Options and … (actions) buttons, right-click it for the same actions as `⌘K`, and
  use the clickable action bar (primary action, Options, Actions) and the back button in the options view.
- **Originals untouched**: each job writes into a private staging folder. Only when the whole batch
  succeeds are the results moved into place, by default next to each original
  (`clip.mov` → `clip-compressed.mp4` in the same folder); results without a source file, like
  recordings and downloads, go to `~/Downloads`. No folder is created per job, and a clashing name
  gets a number instead of replacing a file. Change this in Settings (Downloads, a custom folder or
  ask every time).
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
3. Register it in that category's `<Category>Tools.swift`. If it can run on files with no further
   input, put its options in a nested `Settings: ToolSettings` view (`@AppStorage` values, the form,
   and `job(for:)`), show `Settings()` on the page with `BatchToolView(… job: { Settings().job(for: tool) })`,
   and register `quickAction: QuickAction("Compress", settings: MyToolView.Settings.self)`. The
   launcher then runs it without the window and shows the same options form (see
   `Tools/Video/CompressVideoView.swift`). Build the form from the controls in `UI/OptionControls.swift`
   (`OptionPicker`, `OptionToggle`, `OptionSlider`, `OptionNumberField`, `OptionNote`…): they're standard
   controls on the tool's page and keyboard-driven rows in the launcher. Plain SwiftUI controls only
   work with the mouse there.
