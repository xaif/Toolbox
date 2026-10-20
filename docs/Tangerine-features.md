# Tangerine feature coverage

Reference: [Tangerine's feature demo](https://tangerineformac.com/) and
[App Store description](https://apps.apple.com/us/app/tangerine-file-converter/id6813034065).
Implemented in Toolbox with its own interface and existing job/launcher architecture.

## Interaction

Drag files in Finder, tap Shift (convert), Command (tools), or Control (actions), and drop onto the wheel.
The key can be released before dropping. The wheel closes when the drag ends or Escape is received.
Change the three modifier keys in Settings › Drag Wheel. Each wheel needs a different modifier.
Input Monitoring may be needed for global keyboard navigation. The menu bar also offers a keyboard
wheel for the Finder selection; arrows choose, Return applies, Escape cancels.

The six actions are AirDrop, Float, Copy, Move, Copy Path and Terminal. Float supports dragging files
back out, adding files and pinning to either screen edge. Move operates on originals, asks for a folder,
uses unique names and attempts to roll back a failed batch. Other processing writes copies through
the app's staged output publisher.

## Conversion routes

`ConversionCatalog` contains the reference site's 275 directed routes plus PDF → HTML (276). Additional aliases such as
JPEG, TIF, AIF, Markdown and TGZ are normalized. Unsupported or mixed selections get the intersection
of their available outputs. No RAR, XLS, PPT, RTF, RTFD or clipping export is advertised.

| Input | Outputs |
|---|---|
| JPG/PNG/WebP/HEIC/TIFF/AVIF/BMP, SVG input | Other raster formats and PDF |
| MP3/M4A/WAV/FLAC/OGG/Opus/AIFF/WMA | Other audio formats |
| MP4/MOV/MKV/WebM/AVI/WMV | Other video formats, GIF and MP3 |
| GIF | Video formats |
| PDF | DOCX, PAGES, PPTX, XLSX, JPG, PNG, EPUB, HTML, TXT, MD |
| DOCX/PAGES/MD/TXT; RTF/RTFD/text clippings input | DOCX, PAGES, PDF, TXT, MD, HTML, EPUB, JPG, PNG |
| PPT/PPTX | PDF, JPG, PNG |
| XLS/XLSX/ODS/CSV/TSV | XLSX, ODS, CSV, TSV, PDF |
| EPUB | PDF, DOCX, PAGES, TXT, MD, HTML |
| MOBI/AZW3/AZW/FB2 input (Calibre) | PDF, EPUB, DOCX, PAGES, TXT, MD, HTML |
| SRT/VTT | SRT, VTT, TXT |
| ZIP/TAR/GZIP; RAR input | ZIP, TAR, GZIP |

The same source and destination format is excluded. GZIP conversion creates a `.tar.gz` archive;
single-file `.gz` inputs are also extracted. Unsafe archive paths, links and special files are rejected.

## Advanced tools

| Reference tool | Toolbox implementation |
|---|---|
| Compress | Image/video/audio/PDF: presets, target size, percentage reduction |
| Metadata | Read and edit embedded tags or strip metadata with ExifTool |
| Edit Photo | Exposure, brightness, contrast, saturation, sharpness, sepia, vignette; preview |
| Annotate Photo | Rectangles, ellipses, arrows, text, numbered callouts |
| Add Background | Solid color, gradient or another image; aspect, spacing, corners |
| Crop Image | Draw a region or choose a ratio; optional exact output dimensions |
| Normalize Volume | LUFS target with true peak limiting |
| Remove Audio | Existing Mute Video |
| Trim Video | Existing timeline preview and range selection |
| Split PDF | Existing page and range splitting |
| Organize PDF | Existing reorder, rotate, delete and duplicate page controls |
| Extract Archive | ZIP, TAR, GZIP and RAR through macOS libarchive |
| Create PDF | Existing Images to PDF |
| Merge PDF | Existing PDF merger |
| Crop Video | Existing crop/rotate tool |
| Change Speed | Existing video speed tool with pitch-preserving audio |
| Join Videos | Existing merger with ordered inputs |
| Video Snapshots | Scrub, step and add times; full-resolution PNG outputs |
| Split Video | Choose split points; frame-accurate re-encoded MP4 sections |
| Audio Visualizer | Waveform or static image; landscape, portrait, square MP4 |
| Trim Audio | Existing waveform handles; silence detection trims ends and keeps interior pauses |
| Audio Channels | Mono or stereo conversion |
| Collage | Reorder inputs; grid, row, column, featured image; spacing/corners/background |
| Redact Photo | Manual regions, local face/text detection; solid cover or blur |
| Redact Video | Selected region, optional time range; solid black or blur |
| Bleep Audio | Select waveform ranges or enter ranges; replace speech with a chosen tone |

QR/barcode reading is also included, as described by the App Store listing.

## Requirements and practical limits

- External engines are detected/installed through Settings › Dependencies and are not bundled.
  Office slide and spreadsheet conversion requires LibreOffice. Metadata editing requires ExifTool.
  Media operations require FFmpeg. WebP and AVIF use their dedicated encoders, since Homebrew's
  minimal FFmpeg build does not necessarily contain those image encoders.
- PAGES conversion uses a scratch copy and Apple Pages automation. Pages must be installed and
  Automation must be granted by the user. This path is implemented but was not exercised on this Mac,
  which has no Pages installation. LibreOffice and ExifTool were also absent during verification.
- PDF DOCX/text exports reconstruct editable text in reading order and OCR scanned pages locally.
  XLSX tables are inferred from line/column spacing. Complex layout, images and original table
  structures may change. PPTX keeps each PDF page as an image on its own slide. EPUB supports
  reflowable text or fixed PDF page images.
- HTML, Markdown and EPUB → PDF are laid out by WebKit (CSS, tables and pictures kept; JavaScript
  off; files load resources only from their own folder). CSV/TSV → PDF draws paginated tables
  natively. Other document/EPUB fallback exports preserve readable text. DOCX/PAGES interchange uses Pages; Word-to-PDF prefers
  LibreOffice when installed. Core Text supplies the local fallback.
- Image target compression can lower resolution. PDF target compression rasterizes pages and removes
  selectable text. Audio/video target sizes are approximate; impossible targets report an error.
- Photo/video blur obscures pixels but is less suitable than solid covers for sensitive text. Video
  redaction uses a stationary region; it does not track moving subjects. Snapshot stepping uses a
  30 fps increment; exported times are processed by FFmpeg at the requested timestamp.
- Local conversions and tools do not upload files. AirDrop deliberately shares selected items through
  the macOS recipient picker; Download Video deliberately retrieves a user-supplied URL.

## Verification

Run `scripts/build.sh` and `scripts/test.sh`. Tests generate temporary files and cover the 276-route
matrix, subtitle timing round trips, ZIP/TAR/GZIP round trips and unsafe archive rejection, PDF
Word/Excel/PowerPoint/EPUB/text exports, 300 DPI rendering, SVG and raster formats, image crop/redaction
pixels, real video splits and snapshots, channel conversion, bleep frequency, audio visualization,
video redaction and silence trimming. Automation permission, AirDrop recipients and platform privacy
permissions remain user-controlled and aren't altered by the tests.
