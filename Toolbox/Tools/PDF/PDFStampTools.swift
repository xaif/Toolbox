import PDFKit
import SwiftUI
import UniformTypeIdentifiers

/// PDF tools that change every page the same way: rotation, size, marks drawn on top and colors.
enum PDFStampTools {
    static let all: [Tool] = [
        Tool(id: "pdf.rotate", name: "Rotate PDF", shortName: "Rotate", category: .pdf, symbol: "rotate.right",
             summary: "Turn all pages, odd or even pages, or a range by 90° or 180°.",
             keywords: ["turn", "orientation", "landscape", "portrait", "sideways", "upside down"], input: .pdfs,
             quickAction: QuickAction("Rotate", settings: PDFRotateView.Settings.self, asksFirst: true)) { PDFRotateView(tool: $0) },
        Tool(id: "pdf.crop-resize", name: "Crop & Resize PDF", shortName: "Crop & Resize", category: .pdf, symbol: "crop",
             summary: "Trim margins and fit pages to A4, Letter or a custom size.",
             keywords: ["crop", "margins", "trim", "whitespace", "resize", "page size", "a4", "letter", "legal", "a3", "a5", "scale"],
             input: .pdfs, quickAction: QuickAction("Crop & Resize", settings: PDFCropResizeView.Settings.self, asksFirst: true)) { PDFCropResizeView(tool: $0) },
        Tool(id: "pdf.watermark", name: "Add Watermark", shortName: "Watermark", category: .pdf, symbol: "water.waves",
             summary: "Stamp text or a logo on every page, with opacity, position and angle.",
             keywords: ["stamp", "confidential", "draft", "logo", "copyright", "overlay", "brand"], input: .pdfs,
             quickAction: QuickAction("Watermark", settings: PDFWatermarkView.Settings.self, asksFirst: true)) { PDFWatermarkView(tool: $0) },
        Tool(id: "pdf.page-numbers", name: "Add Page Numbers", shortName: "Page Numbers", category: .pdf, symbol: "number",
             summary: "Number pages in the style, position and starting number you choose.",
             keywords: ["paginate", "pagination", "numbering", "bates", "page x of y", "roman"], input: .pdfs,
             quickAction: QuickAction("Number Pages of", settings: PDFPageNumbersView.Settings.self)) { PDFPageNumbersView(tool: $0) },
        Tool(id: "pdf.headers-footers", name: "Headers & Footers", category: .pdf, symbol: "rectangle.topthird.inset.filled",
             summary: "Add a title, date, file name or page numbers to the top and bottom of every page.",
             keywords: ["header", "footer", "running head", "date", "title", "letterhead", "page numbers"], input: .pdfs,
             quickAction: QuickAction("Add Headers & Footers to", settings: PDFHeadersFootersView.Settings.self, asksFirst: true)) { PDFHeadersFootersView(tool: $0) },
        Tool(id: "pdf.invert-colors", name: "Invert PDF Colors", shortName: "Invert Colors", category: .pdf, symbol: "circle.lefthalf.filled",
             summary: "Make a dark mode, sepia or grayscale copy. Text stays selectable.",
             keywords: ["dark mode", "night", "invert", "negative", "sepia", "grayscale", "greyscale", "black and white", "colours"], input: .pdfs,
             quickAction: QuickAction("Invert Colors of", settings: PDFInvertColorsView.Settings.self)) { PDFInvertColorsView(tool: $0) },
        Tool(id: "pdf.flatten", name: "Flatten PDF", shortName: "Flatten", category: .pdf, symbol: "square.stack.3d.down.right",
             summary: "Burn in form fields and comments, and remove scripts, so nothing can be edited.",
             keywords: ["form fields", "annotations", "comments", "non-editable", "lock", "javascript", "acroform", "burn in"], input: .pdfs,
             quickAction: QuickAction("Flatten", settings: PDFFlattenView.Settings.self)) { PDFFlattenView(tool: $0) },
        Tool(id: "pdf.fingerprint", name: "Fingerprint PDF", shortName: "Fingerprint", category: .pdf, symbol: "touchid",
             summary: "Give each recipient a copy with an invisible mark, to trace leaks.",
             keywords: ["leak", "trace", "tracking", "invisible", "recipient", "watermark", "forensic", "identify"], input: .pdfs) { PDFFingerprintView(tool: $0) },
    ]
}

// MARK: - Shared options

/// Picks the pages a tool changes: all, odd, even or a typed range.
struct PDFPageScopeOptions: View {
    @Binding var scope: PDFPageScope
    @Binding var range: String

    var body: some View {
        OptionPicker("Pages", selection: $scope, choices: PDFPageScope.allCases.map { OptionChoice($0, $0.label) })
        if scope == .custom {
            StampTextOption("Page range", text: $range, prompt: "e.g. 1-3, 5, 8-")
        }
    }
}

/// A line of text in a tool's saved options: a text field on the tool's page, and in the launcher a
/// keyboard-driven row like the controls in `OptionControls.swift`.
struct StampTextOption: View {
    let title: String
    @Binding var text: String
    var prompt: String
    var width: CGFloat

    @Environment(OptionsNavigator.self) private var navigator: OptionsNavigator?
    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var isEditing: Bool

    init(_ title: String, text: Binding<String>, prompt: String = "", width: CGFloat = 240) {
        self.title = title
        _text = text
        self.prompt = prompt
        self.width = width
    }

    var body: some View {
        if let navigator {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text(title)
                    .foregroundStyle(.secondary)
                    .frame(width: 140, alignment: .trailing)
                    .padding(.trailing, 12)
                TextField("", text: $text, prompt: Text(prompt))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: width)
                    .focused($isEditing)
                    .onChange(of: isEditing) { if isEditing { navigator.focus(title) } }
                    .onChange(of: navigator.focusedID, initial: true) { isEditing = navigator.focusedID == title }
                    .onChange(of: navigator.textFocusRequest) { isEditing = navigator.focusedID == title }
                    .onKeyPress(phases: [.down, .repeat]) { navigator.handle($0) }
                Spacer(minLength: 8)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(minHeight: 36)
            .background(navigator.focusedID == title ? LauncherPalette(scheme: colorScheme).highlight : .clear,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
            .onTapGesture { navigator.focus(title) }
            .id(title)
            .preference(key: OptionFieldsKey.self, value: [OptionField(id: title, kind: .text)])
        } else {
            LabeledContent(title) {
                TextField(title, text: $text, prompt: Text(prompt))
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: width)
            }
        }
    }
}

private extension String {
    var isBlank: Bool { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

private let colorChoices = PDFStampColor.allCases.map { OptionChoice($0, $0.label) }

// MARK: - Rotate

struct PDFRotateView: View {
    let tool: Tool

    var body: some View {
        BatchToolView(tool: tool, accepts: UTType.pdfInputs, actionTitle: "Rotate", noun: "PDFs",
                      job: { Settings().job(for: tool) }) {
            Settings()
        }
    }

    /// The saved options, shown on this page and in the launcher, and the job they configure.
    struct Settings: ToolSettings {
        @AppStorage("pdf.rotate.degrees") private var degrees = 90
        @AppStorage("pdf.rotate.scope") private var scope = PDFPageScope.all
        @AppStorage("pdf.rotate.range") private var range = ""

        var body: some View {
            OptionPicker("Rotate", selection: $degrees, style: .segmented, choices: [
                OptionChoice(90, "90° right"),
                OptionChoice(180, "180°"),
                OptionChoice(270, "90° left"),
            ])
            PDFPageScopeOptions(scope: $scope, range: $range)
            OptionNote("Lossless: pages keep their text, links and quality.")
        }

        func job(for tool: Tool) -> ToolJob? {
            guard scope != .custom || !range.isBlank else { return nil }
            return PDFRotateView.job(degrees: degrees, scope: scope, range: range)
        }
    }

    static func job(degrees: Int, scope: PDFPageScope, range: String) -> ToolJob {
        .each(verb: "Rotating") { input, context, progress in
            let document = try PDFOps.open(input)
            let pages = try scope.pages(range: range, pageCount: document.pageCount)
            try PDFOps.write(PDFStampOps.rotate(document, pages: pages, degrees: degrees),
                             to: context.output(for: input, suffix: "rotated", extension: "pdf"))
            progress(1)
        }
    }
}

// MARK: - Crop & resize

struct PDFCropResizeView: View {
    let tool: Tool

    var body: some View {
        BatchToolView(tool: tool, accepts: UTType.pdfInputs, actionTitle: "Crop & Resize", noun: "PDFs",
                      job: { Settings().job(for: tool) }) {
            Settings()
        }
    }

    /// The saved options, shown on this page and in the launcher, and the job they configure.
    struct Settings: ToolSettings {
        @AppStorage("pdf.crop-resize.trim") private var trim = false
        @AppStorage("pdf.crop-resize.unit") private var unit = PDFLengthUnit.millimeters
        @AppStorage("pdf.crop-resize.top") private var top = 0.0
        @AppStorage("pdf.crop-resize.right") private var right = 0.0
        @AppStorage("pdf.crop-resize.bottom") private var bottom = 0.0
        @AppStorage("pdf.crop-resize.left") private var left = 0.0
        @AppStorage("pdf.crop-resize.paper") private var paper = PDFPaperSize.original
        @AppStorage("pdf.crop-resize.width") private var width = 210.0
        @AppStorage("pdf.crop-resize.height") private var height = 297.0
        @AppStorage("pdf.crop-resize.orientation") private var orientation = PDFPaperOrientation.match

        var body: some View {
            OptionToggle("Trim white margins automatically", isOn: $trim)
            OptionPicker("Units", selection: $unit, style: .segmented, choices: PDFLengthUnit.allCases.map { OptionChoice($0, $0.label) })
                .onChange(of: unit) { old, new in convert(from: old, to: new) }
            margin("Crop top", $top)
            margin("Crop bottom", $bottom)
            margin("Crop left", $left)
            margin("Crop right", $right)
            OptionPicker("Page size", selection: $paper, choices: PDFPaperSize.allCases.map {
                OptionChoice($0, $0.label, dividerBefore: $0 == .a3 || $0 == .custom)
            })
            if paper == .custom {
                margin("Width", $width, range: 10...5000)
                margin("Height", $height, range: 10...5000)
            }
            if paper != .original {
                OptionPicker("Orientation", selection: $orientation, choices: PDFPaperOrientation.allCases.map { OptionChoice($0, $0.label) })
            }
            OptionNote(paper == .original
                       ? "Cropping hides margins without deleting anything, so text and links are kept."
                       : "Each page is scaled to fit the new size and centered. Text stays sharp and selectable.")
        }

        private func margin(_ title: String, _ value: Binding<Double>, range: ClosedRange<Double> = 0...5000) -> some View {
            OptionNumberField(title, value: value, format: .number.precision(.fractionLength(0...2)), unit: unit.label, in: range, width: 70)
        }

        /// Keeps the lengths the same when the unit changes.
        private func convert(from old: PDFLengthUnit, to new: PDFLengthUnit) {
            let factor = old.points / new.points
            for value in [$top, $right, $bottom, $left, $width, $height] {
                value.wrappedValue = (value.wrappedValue * factor * 100).rounded() / 100
            }
        }

        func job(for tool: Tool) -> ToolJob? {
            let points = unit.points
            var options = PDFCropResize(top: top * points, right: right * points, bottom: bottom * points, left: left * points,
                                        trimWhitespace: trim, orientation: orientation)
            switch paper {
            case .original: options.paper = nil
            case .custom: options.paper = CGSize(width: width * points, height: height * points)
            default: options.paper = paper.size
            }
            guard options.trimWhitespace || options.hasMargins || options.paper != nil else { return nil }
            return PDFCropResizeView.job(options)
        }
    }

    static func job(_ options: PDFCropResize) -> ToolJob {
        let suffix = options.paper == nil ? "cropped" : "resized"
        return .each(verb: options.paper == nil ? "Cropping" : "Resizing") { input, context, progress in
            let document = try PDFOps.open(input)
            let output = try PDFStampOps.cropResize(document, options: options, progress: progress)
            try PDFOps.write(output, to: context.output(for: input, suffix: suffix, extension: "pdf"))
        }
    }
}

// MARK: - Watermark

enum PDFWatermarkKind: String, CaseIterable, Identifiable {
    case text, image
    var id: Self { self }
}

struct PDFWatermarkView: View {
    let tool: Tool

    var body: some View {
        BatchToolView(tool: tool, accepts: UTType.pdfInputs, actionTitle: "Add Watermark", noun: "PDFs",
                      job: { Settings().job(for: tool) }) {
            Settings()
        }
    }

    /// The saved options, shown on this page and in the launcher, and the job they configure.
    struct Settings: ToolSettings {
        @AppStorage("pdf.watermark.kind") private var kind = PDFWatermarkKind.text
        @AppStorage("pdf.watermark.text") private var text = "CONFIDENTIAL"
        @AppStorage("pdf.watermark.fontSize") private var fontSize = 60.0
        @AppStorage("pdf.watermark.bold") private var bold = true
        @AppStorage("pdf.watermark.color") private var color = PDFStampColor.red
        @AppStorage("pdf.watermark.imagePath") private var imagePath = ""
        @AppStorage("pdf.watermark.imageScale") private var imageScale = 0.4
        @AppStorage("pdf.watermark.opacity") private var opacity = 0.25
        @AppStorage("pdf.watermark.rotation") private var rotation = 45.0
        /// "tiled" or a `PDFStampPosition`.
        @AppStorage("pdf.watermark.placement") private var placement = PDFStampPosition.center.rawValue
        @AppStorage("pdf.watermark.scope") private var scope = PDFPageScope.all
        @AppStorage("pdf.watermark.range") private var range = ""

        var body: some View {
            OptionPicker("Watermark", selection: $kind, style: .segmented, choices: [
                OptionChoice(PDFWatermarkKind.text, "Text"),
                OptionChoice(PDFWatermarkKind.image, "Image"),
            ])
            if kind == .text {
                StampTextOption("Text", text: $text, prompt: "CONFIDENTIAL")
                OptionSlider("Font size", value: $fontSize, in: 12...200, step: 2) { "\(Int($0)) pt" }
                OptionToggle("Bold", isOn: $bold)
                OptionPicker("Color", selection: $color, choices: colorChoices)
            } else {
                LabeledContent("Image") {
                    HStack {
                        Button(imagePath.isEmpty ? "Choose Image…" : "Change…", action: chooseImage)
                        if !imagePath.isEmpty {
                            Text(URL(fileURLWithPath: imagePath).lastPathComponent)
                                .lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                        }
                    }
                }
                .optionIndent()
                OptionSlider("Width", value: $imageScale, in: 0.05...1, step: 0.05) { "\(Int(($0 * 100).rounded()))%" }
            }
            OptionSlider("Opacity", value: $opacity, in: 0.05...1, step: 0.05, presets: [0.15, 0.25, 0.5, 1]) {
                "\(Int(($0 * 100).rounded()))%"
            }
            OptionSlider("Angle", value: $rotation, in: -90...90, step: 5, presets: [-45, 0, 45, 90]) { "\(Int($0))°" }
            OptionPicker("Position", selection: $placement, choices:
                [OptionChoice("tiled", "Tiled across the page")]
                + PDFStampPosition.allCases.map { OptionChoice($0.rawValue, $0.label, dividerBefore: $0 == .topLeft) })
            PDFPageScopeOptions(scope: $scope, range: $range)
        }

        private func chooseImage() {
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.image]
            panel.message = "Choose a logo or image to stamp on the pages."
            if panel.runModal() == .OK, let url = panel.url { imagePath = url.path }
        }

        func job(for tool: Tool) -> ToolJob? {
            guard scope != .custom || !range.isBlank else { return nil }
            let content: PDFWatermark.Content
            switch kind {
            case .text:
                guard !text.isBlank else { return nil }
                content = .text(text, PDFTextStyle(size: fontSize, bold: bold, color: color.cgColor))
            case .image:
                guard !imagePath.isEmpty, let source = try? ImageIOHelpers.source(for: URL(fileURLWithPath: imagePath)),
                      let image = try? ImageIOHelpers.orientedImage(source, index: CGImageSourceGetPrimaryImageIndex(source)) else { return nil }
                content = .image(image, widthFraction: imageScale)
            }
            let mark = PDFWatermark(content: content, opacity: opacity, rotation: rotation, tiled: placement == "tiled",
                                    position: PDFStampPosition(rawValue: placement) ?? .center)
            return PDFWatermarkView.job(mark, scope: scope, range: range)
        }
    }

    static func job(_ mark: PDFWatermark, scope: PDFPageScope = .all, range: String = "") -> ToolJob {
        .each(verb: "Watermarking") { input, context, progress in
            let document = try PDFOps.open(input)
            let pages = try scope.pages(range: range, pageCount: document.pageCount)
            let output = try PDFStampOps.watermark(document, mark: mark, pages: pages, progress: progress)
            try PDFOps.write(output, to: context.output(for: input, suffix: "watermarked", extension: "pdf"))
        }
    }
}

// MARK: - Page numbers

struct PDFPageNumbersView: View {
    let tool: Tool

    var body: some View {
        BatchToolView(tool: tool, accepts: UTType.pdfInputs, actionTitle: "Add Numbers", noun: "PDFs",
                      job: { Settings().job(for: tool) }) {
            Settings()
        }
    }

    /// The saved options, shown on this page and in the launcher, and the job they configure.
    struct Settings: ToolSettings {
        @AppStorage("pdf.page-numbers.format") private var format = PDFPageNumberFormat.number
        @AppStorage("pdf.page-numbers.position") private var position = PDFStampPosition.bottom
        @AppStorage("pdf.page-numbers.start") private var start = 1
        @AppStorage("pdf.page-numbers.fontSize") private var fontSize = 11.0
        @AppStorage("pdf.page-numbers.color") private var color = PDFStampColor.black
        @AppStorage("pdf.page-numbers.margin") private var margin = 28.0
        @AppStorage("pdf.page-numbers.skipFirst") private var skipFirst = false
        @AppStorage("pdf.page-numbers.scope") private var scope = PDFPageScope.all
        @AppStorage("pdf.page-numbers.range") private var range = ""

        var body: some View {
            OptionPicker("Format", selection: $format, choices: PDFPageNumberFormat.allCases.map { OptionChoice($0, $0.label) })
            OptionPicker("Position", selection: $position, choices: PDFStampPosition.edges.map {
                OptionChoice($0, $0.label, dividerBefore: $0 == .bottomLeft)
            })
            OptionNumberField("Start at", value: $start, format: IntegerFormatStyle<Int>().grouping(.never), in: 0...99_999, step: 1, width: 70)
            OptionSlider("Font size", value: $fontSize, in: 6...36, step: 1) { "\(Int($0)) pt" }
            OptionPicker("Color", selection: $color, choices: colorChoices)
            OptionSlider("Margin", value: $margin, in: 8...96, step: 2) { "\(Int($0)) pt" }
            OptionToggle("Skip the first page (cover)", isOn: $skipFirst)
            PDFPageScopeOptions(scope: $scope, range: $range)
        }

        func job(for tool: Tool) -> ToolJob? {
            guard scope != .custom || !range.isBlank else { return nil }
            let numbering = PDFPageNumbering(format: format, position: position, start: start,
                                             style: PDFTextStyle(size: fontSize, color: color.cgColor),
                                             margin: margin, skipFirst: skipFirst)
            return PDFPageNumbersView.job(numbering, scope: scope, range: range)
        }
    }

    static func job(_ numbering: PDFPageNumbering, scope: PDFPageScope = .all, range: String = "") -> ToolJob {
        .each(verb: "Numbering") { input, context, progress in
            let document = try PDFOps.open(input)
            let pages = try scope.pages(range: range, pageCount: document.pageCount)
            let output = try PDFStampOps.addPageNumbers(document, numbering: numbering, pages: pages, progress: progress)
            try PDFOps.write(output, to: context.output(for: input, suffix: "numbered", extension: "pdf"))
        }
    }
}

// MARK: - Headers & footers

struct PDFHeadersFootersView: View {
    let tool: Tool

    var body: some View {
        BatchToolView(tool: tool, accepts: UTType.pdfInputs, actionTitle: "Add", noun: "PDFs",
                      job: { Settings().job(for: tool) }) {
            Settings()
        }
    }

    /// The saved options, shown on this page and in the launcher, and the job they configure.
    struct Settings: ToolSettings {
        @AppStorage("pdf.headers-footers.headerLeft") private var headerLeft = "{title}"
        @AppStorage("pdf.headers-footers.headerCenter") private var headerCenter = ""
        @AppStorage("pdf.headers-footers.headerRight") private var headerRight = "{date}"
        @AppStorage("pdf.headers-footers.footerLeft") private var footerLeft = ""
        @AppStorage("pdf.headers-footers.footerCenter") private var footerCenter = "Page {page} of {pages}"
        @AppStorage("pdf.headers-footers.footerRight") private var footerRight = ""
        @AppStorage("pdf.headers-footers.dateStyle") private var dateStyle = PDFDateStyle.medium
        @AppStorage("pdf.headers-footers.fontSize") private var fontSize = 10.0
        @AppStorage("pdf.headers-footers.color") private var color = PDFStampColor.gray
        @AppStorage("pdf.headers-footers.margin") private var margin = 28.0
        @AppStorage("pdf.headers-footers.rules") private var rules = false
        @AppStorage("pdf.headers-footers.skipFirst") private var skipFirst = false

        var body: some View {
            StampTextOption("Header left", text: $headerLeft)
            StampTextOption("Header center", text: $headerCenter)
            StampTextOption("Header right", text: $headerRight)
            StampTextOption("Footer left", text: $footerLeft)
            StampTextOption("Footer center", text: $footerCenter)
            StampTextOption("Footer right", text: $footerRight)
            OptionNote("Use \(PDFHeaderFooter.tokens.joined(separator: ", ")) to fill in each page’s details.")
            OptionPicker("Date format", selection: $dateStyle, choices: PDFDateStyle.allCases.map { OptionChoice($0, $0.label) })
            OptionSlider("Font size", value: $fontSize, in: 6...24, step: 1) { "\(Int($0)) pt" }
            OptionPicker("Color", selection: $color, choices: colorChoices)
            OptionSlider("Margin", value: $margin, in: 8...96, step: 2) { "\(Int($0)) pt" }
            OptionToggle("Draw a line under the header and above the footer", isOn: $rules)
            OptionToggle("Skip the first page (cover)", isOn: $skipFirst)
        }

        func job(for tool: Tool) -> ToolJob? {
            let layout = PDFHeaderFooter(
                texts: [.topLeft: headerLeft, .top: headerCenter, .topRight: headerRight,
                        .bottomLeft: footerLeft, .bottom: footerCenter, .bottomRight: footerRight],
                style: PDFTextStyle(size: fontSize, color: color.cgColor), margin: margin, skipFirst: skipFirst,
                rules: rules, dateStyle: dateStyle)
            guard !layout.isEmpty else { return nil }
            return PDFHeadersFootersView.job(layout)
        }
    }

    static func job(_ layout: PDFHeaderFooter) -> ToolJob {
        .each(verb: "Adding headers to") { input, context, progress in
            let document = try PDFOps.open(input)
            let output = try PDFStampOps.addHeadersFooters(document, layout: layout,
                                                          fileName: input.deletingPathExtension().lastPathComponent, progress: progress)
            try PDFOps.write(output, to: context.output(for: input, suffix: "headers", extension: "pdf"))
        }
    }
}

// MARK: - Invert colors

struct PDFInvertColorsView: View {
    let tool: Tool

    var body: some View {
        BatchToolView(tool: tool, accepts: UTType.pdfInputs, actionTitle: "Convert", noun: "PDFs",
                      job: { Settings().job(for: tool) }) {
            Settings()
        }
    }

    /// The saved options, shown on this page and in the launcher, and the job they configure.
    struct Settings: ToolSettings {
        @AppStorage("pdf.invert-colors.mode") private var mode = PDFColorMode.dark

        var body: some View {
            OptionPicker("Colors", selection: $mode, style: .radioGroup, choices: [
                OptionChoice(PDFColorMode.dark, "Dark — white text on black"),
                OptionChoice(PDFColorMode.softDark, "Soft dark — light gray on dark gray"),
                OptionChoice(PDFColorMode.sepia, "Sepia — easy on the eyes"),
                OptionChoice(PDFColorMode.grayscale, "Grayscale"),
            ])
            OptionNote("Text stays selectable and searchable. Photos are recolored too, and comments are painted into the pages.")
        }

        func job(for tool: Tool) -> ToolJob? { PDFInvertColorsView.job(mode) }
    }

    static func job(_ mode: PDFColorMode) -> ToolJob {
        .each(verb: "Recoloring") { input, context, progress in
            let document = try PDFOps.open(input)
            let output = try PDFStampOps.recolor(document, mode: mode, progress: progress)
            try PDFOps.write(output, to: context.output(for: input, suffix: mode.suffix, extension: "pdf"))
        }
    }
}

// MARK: - Flatten

struct PDFFlattenView: View {
    let tool: Tool

    var body: some View {
        BatchToolView(tool: tool, accepts: UTType.pdfInputs, actionTitle: "Flatten", noun: "PDFs",
                      job: { Settings().job(for: tool) }) {
            Settings()
        }
    }

    /// The saved options, shown on this page and in the launcher, and the job they configure.
    struct Settings: ToolSettings {
        @AppStorage("pdf.flatten.keepLinks") private var keepLinks = true

        var body: some View {
            OptionToggle("Keep links clickable", isOn: $keepLinks)
            OptionNote("Form fields, comments, highlights and stamps become part of the page. Forms, scripts and actions that run when the file opens are removed.")
        }

        func job(for tool: Tool) -> ToolJob? { PDFFlattenView.job(keepLinks: keepLinks) }
    }

    static func job(keepLinks: Bool) -> ToolJob {
        .each(verb: "Flattening") { input, context, progress in
            let document = try PDFOps.open(input)
            let output = try PDFStampOps.flatten(document, keepLinks: keepLinks, progress: progress)
            try PDFOps.write(output, to: context.output(for: input, suffix: "flattened", extension: "pdf"))
        }
    }
}

// MARK: - Fingerprint

struct PDFFingerprintView: View {
    let tool: Tool

    enum Mode: String, CaseIterable {
        case create, check
    }

    struct Finding: Identifiable {
        let id = UUID()
        let fingerprint: PDFFingerprint
        let pages: [Int]
    }

    @State private var runner: JobRunner
    @State private var mode = Mode.create
    @AppStorage("pdf.fingerprint.recipients") private var recipientText = ""
    @State private var checkFiles: [URL] = []
    @State private var findings: [Finding]?
    @State private var checkError: String?

    init(tool: Tool) {
        self.tool = tool
        _runner = State(initialValue: JobCenter.shared.runner(for: tool.id))
    }

    private var recipients: [String] { Self.recipients(in: recipientText) }

    var body: some View {
        switch mode {
        case .create:
            ToolPage(tool: tool, runner: runner) {
                modePicker
                FileListInput(files: $runner.inputs, accepts: UTType.pdfInputs, noun: "PDFs")
                    .disabled(runner.isRunning)
                ToolSection("Recipients", footnote: "One name, email or ID per line. Each recipient gets their own copy, named after them.") {
                    TextEditor(text: $recipientText)
                        .font(.body)
                        .frame(minHeight: 110)
                        .scrollContentBackground(.hidden)
                        .disabled(runner.isRunning)
                    if !recipients.isEmpty {
                        Text("\(recipients.count) cop\(recipients.count == 1 ? "y" : "ies") per PDF")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                ToolSection("How it works") {
                    Text("Each copy carries invisible text with a unique code and the recipient’s name on every page, plus the same mark in the file’s metadata. It doesn’t change how pages look or print. If a copy leaks, open this tool’s Check tab to see whose it was.")
                    Text("The mark survives copying, merging, splitting and compressing. Printing, scanning, screenshots or turning pages into images remove it, and someone who knows to look can find and delete it.")
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
            } footer: {
                JobBar(runner: runner, actionTitle: "Create Copies", canRun: !runner.inputs.isEmpty && !recipients.isEmpty,
                       hint: runner.inputs.isEmpty ? "Add PDFs to fingerprint." : "Add at least one recipient.", action: run)
            }
            .onChange(of: runner.inputs) { if !runner.isRunning { runner.reset() } }
        case .check:
            ToolPage(tool: tool) {
                modePicker
                FileListInput(files: $checkFiles, accepts: UTType.pdfInputs, allowsMultiple: false, noun: "a PDF to check")
                if let checkError {
                    Label(checkError, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                } else if let findings {
                    ToolSection("Fingerprint") {
                        if findings.isEmpty {
                            Label("No Toolbox fingerprint found in this PDF.", systemImage: "questionmark.circle")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(findings) { finding in
                            VStack(alignment: .leading, spacing: 4) {
                                Label(finding.fingerprint.recipient, systemImage: "person.crop.circle.badge.checkmark")
                                    .font(.headline)
                                    .textSelection(.enabled)
                                Text("Code \(finding.fingerprint.code) · " + (finding.pages.isEmpty
                                     ? "in the file’s metadata only"
                                     : "on \(finding.pages.count == 1 ? "page" : "pages") \(PDFOps.rangeString(finding.pages.map { $0 - 1 }))"))
                                    .font(.callout).foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }
            }
            .onChange(of: checkFiles, initial: true) { check() }
        }
    }

    private var modePicker: some View {
        Picker("Mode", selection: $mode) {
            Text("Create Copies").tag(Mode.create)
            Text("Check a PDF").tag(Mode.check)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }

    private func check() {
        checkError = nil
        guard let url = checkFiles.first else { findings = nil; return }
        do {
            let document = try PDFOps.open(url)
            findings = PDFStampOps.fingerprints(in: document).map { Finding(fingerprint: $0.fingerprint, pages: $0.pages) }
        } catch {
            findings = nil
            checkError = error.localizedDescription
        }
    }

    private func run() {
        runner.start(Self.job(recipients: recipients), title: tool.name, inputs: runner.inputs)
    }

    /// Non-empty lines, without duplicates, in order.
    static func recipients(in text: String) -> [String] {
        var seen = Set<String>()
        return text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    static func job(recipients: [String]) -> ToolJob {
        .each(verb: "Fingerprinting") { input, context, progress in
            for (index, recipient) in recipients.enumerated() {
                try Task.checkCancellation()
                // Each copy starts from a fresh read: rebuilding moves annotations off the source pages.
                let document = try PDFOps.open(input)
                let marked = try PDFStampOps.fingerprint(document, with: PDFFingerprint(recipient: recipient)) {
                    progress((Double(index) + $0) / Double(recipients.count))
                }
                try PDFOps.write(marked, to: context.output(for: input, suffix: recipient, extension: "pdf"))
            }
        }
    }
}
