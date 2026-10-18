import SwiftUI
import Vision
import PDFKit
import ImageIO
import UniformTypeIdentifiers

/// On-device text recognition with Vision.
enum AIOCR {
    struct Options: Sendable {
        /// Empty means detect automatically.
        var languages: [Locale.Language] = []
        var usesLanguageCorrection = true
        /// Join lines that Vision marks as wrapping into paragraphs.
        var joinWrappedLines = true
    }

    static var supportedLanguages: [Locale.Language] {
        RecognizeTextRequest().supportedRecognitionLanguages
    }

    static func displayName(for language: Locale.Language) -> String {
        Locale.current.localizedString(forIdentifier: language.maximalIdentifier)
            ?? Locale.current.localizedString(forIdentifier: language.minimalIdentifier)
            ?? language.minimalIdentifier
    }

    static func makeRequest(_ options: Options) -> RecognizeTextRequest {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = options.usesLanguageCorrection
        if options.languages.isEmpty {
            request.automaticallyDetectsLanguage = true
        } else {
            request.automaticallyDetectsLanguage = false
            request.recognitionLanguages = options.languages
        }
        return request
    }

    static func recognize(_ image: CGImage, options: Options) async throws -> String {
        let observations = try await makeRequest(options).perform(on: image)
        return layout(observations, options: options)
    }

    static func recognize(imageAt url: URL, options: Options) async throws -> String {
        // Load through ImageIO so EXIF orientation is applied the same way Finder shows the image.
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ToolError.unreadableInput(url)
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let rawOrientation = (properties?[kCGImagePropertyOrientation] as? UInt32) ?? 1
        let orientation = CGImagePropertyOrientation(rawValue: rawOrientation) ?? .up
        let observations = try await makeRequest(options).perform(on: image, orientation: orientation)
        return layout(observations, options: options)
    }

    /// Text of every page. Pages with a real text layer use it directly unless `forceOCR` is on;
    /// scanned pages are rendered at ~300 DPI and recognized.
    static func recognize(pdfAt url: URL, options: Options, forceOCR: Bool,
                          progress: @escaping @Sendable (Double) -> Void) async throws -> String {
        guard let document = PDFDocument(url: url) else { throw ToolError.unreadableInput(url) }
        if document.isLocked { throw ToolError.failed("It's password protected. Remove the password first.") }
        let count = document.pageCount
        guard count > 0 else { throw ToolError.failed("The PDF has no pages.") }
        var pages: [String] = []
        for index in 0..<count {
            try Task.checkCancellation()
            guard let page = document.page(at: index) else { continue }
            var text = ""
            if !forceOCR, let layer = page.string, layer.filter({ !$0.isWhitespace }).count >= 20 {
                text = layer.trimmingCharacters(in: .whitespacesAndNewlines)
            } else if let image = render(page, dpi: 300) {
                text = try await recognize(image, options: options)
            }
            pages.append(count > 1 ? "--- Page \(index + 1) ---\n\(text)" : text)
            progress(Double(index + 1) / Double(count))
        }
        return pages.joined(separator: "\n\n")
    }

    static func render(_ page: PDFPage, dpi: CGFloat) -> CGImage? {
        let bounds = page.bounds(for: .mediaBox)
        let rotated = page.rotation % 180 != 0
        let pageSize = rotated ? CGSize(width: bounds.height, height: bounds.width) : bounds.size
        var scale = dpi / 72
        let maxSide: CGFloat = 6000
        scale = min(scale, maxSide / max(pageSize.width, pageSize.height, 1))
        let width = Int(pageSize.width * scale), height = Int(pageSize.height * scale)
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: context)
        return context.makeImage()
    }

    /// Orders observations top-to-bottom, left-to-right and rebuilds lines and paragraphs.
    static func layout(_ observations: [RecognizedTextObservation], options: Options) -> String {
        struct Line { var top: CGFloat; var bottom: CGFloat; var items: [(x: CGFloat, text: String, wraps: Bool)] }
        let items: [(top: CGFloat, bottom: CGFloat, x: CGFloat, text: String, wraps: Bool)] = observations.compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let text = candidate.string.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { return nil }
            // Normalized coordinates have their origin at the bottom left.
            let top = max(observation.topLeft.y, observation.topRight.y)
            let bottom = min(observation.bottomLeft.y, observation.bottomRight.y)
            let x = min(observation.topLeft.x, observation.bottomLeft.x)
            return (top, bottom, x, text, observation.shouldWrapToNextLine ?? false)
        }
        .sorted { $0.top > $1.top }

        var lines: [Line] = []
        for item in items {
            // Same line if vertical centers overlap enough.
            let center = (item.top + item.bottom) / 2
            if let index = lines.lastIndex(where: { center <= $0.top && center >= $0.bottom }) {
                lines[index].items.append((item.x, item.text, item.wraps))
                lines[index].top = max(lines[index].top, item.top)
                lines[index].bottom = min(lines[index].bottom, item.bottom)
            } else {
                lines.append(Line(top: item.top, bottom: item.bottom, items: [(item.x, item.text, item.wraps)]))
            }
        }

        var output = ""
        var previous: Line?
        for line in lines {
            let sorted = line.items.sorted { $0.x < $1.x }
            let text = sorted.map(\.text).joined(separator: "  ")
            if let previous {
                let gap = previous.bottom - line.top
                let height = max(previous.top - previous.bottom, 0.001)
                let wraps = options.joinWrappedLines && (previous.items.last?.wraps ?? false)
                if gap > height * 1.2 {
                    output += "\n\n"
                } else if wraps {
                    if output.hasSuffix("-") { output.removeLast() } else { output += " " }
                } else {
                    output += "\n"
                }
            }
            output += text
            previous = Line(top: line.top, bottom: line.bottom, items: sorted)
        }
        return output
    }
}

struct ExtractTextView: View {
    let tool: Tool

    @State private var runner: JobRunner
    @State private var previews = AIPreviewStore.shared
    @AppStorage("ai.ocr.language") private var languageID = ""
    @AppStorage("ai.ocr.correction") private var languageCorrection = true
    @AppStorage("ai.ocr.paragraphs") private var joinLines = true
    @AppStorage("ai.ocr.forceOCR") private var forceOCR = false
    @AppStorage("ai.ocr.copy") private var copyWhenDone = false

    private static let languages = AIOCR.supportedLanguages
        .sorted { AIOCR.displayName(for: $0).localizedCaseInsensitiveCompare(AIOCR.displayName(for: $1)) == .orderedAscending }

    init(tool: Tool) {
        self.tool = tool
        _runner = State(initialValue: JobCenter.shared.runner(for: tool.id))
    }

    var body: some View {
        ToolPage(tool: tool, runner: runner) {
            FileListInput(files: $runner.inputs, accepts: [.image, .pdf], noun: "images or PDFs")
                .disabled(runner.isRunning)

            ToolSection("Options", footnote: "Text is recognized on your Mac with Apple's Vision framework.") {
                Picker("Language", selection: $languageID) {
                    Text("Detect automatically").tag("")
                    Divider()
                    ForEach(Self.languages, id: \.maximalIdentifier) { language in
                        Text(AIOCR.displayName(for: language)).tag(language.maximalIdentifier)
                    }
                }
                Toggle("Correct recognized words using the language", isOn: $languageCorrection)
                Toggle("Join wrapped lines into paragraphs", isOn: $joinLines)
                Toggle("For PDFs, recognize every page even if it already has text", isOn: $forceOCR)
                Toggle("Copy the text to the clipboard when done", isOn: $copyWhenDone)
            }
            .disabled(runner.isRunning)

            if let preview = previews.preview(for: tool.id) {
                AITextPreview(title: "Text · \(preview.title)", text: preview.text)
            }
        } footer: {
            JobBar(runner: runner, actionTitle: "Extract Text", canRun: !runner.inputs.isEmpty,
                   hint: "Add images or PDFs to get started.", action: start)
        }
        .onChange(of: runner.inputs) { if !runner.isRunning { runner.reset() } }
    }

    private func start() {
        let inputs = runner.inputs
        let options = AIOCR.Options(
            languages: languageID.isEmpty ? [] : [Locale.Language(identifier: languageID)],
            usesLanguageCorrection: languageCorrection,
            joinWrappedLines: joinLines)
        let forceOCR = forceOCR
        let copyWhenDone = copyWhenDone
        let toolID = tool.id
        runner.start(title: tool.name) { context in
            let collected = AICollector()
            try await context.forEach(inputs, verb: "Reading") { input, progress in
                let text: String
                if AIText.conforms(input, to: [.pdf]) {
                    text = try await AIOCR.recognize(pdfAt: input, options: options, forceOCR: forceOCR, progress: progress)
                } else {
                    text = try await AIOCR.recognize(imageAt: input, options: options)
                }
                try AIText.write(text + "\n", to: context.output(for: input, extension: "txt"))
                collected.append(inputs.count > 1 ? "# \(input.lastPathComponent)\n\n\(text)" : text)
                await MainActor.run {
                    AIPreviewStore.shared.set(toolID, title: input.lastPathComponent,
                                              text: text.isEmpty ? "(No text found)" : text)
                }
            }
            if copyWhenDone {
                let all = collected.joined(separator: "\n\n")
                await MainActor.run { AIText.copy(all) }
            }
        }
    }
}

/// Thread-safe string accumulator for job closures.
final class AICollector: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []

    func append(_ item: String) {
        lock.lock(); items.append(item); lock.unlock()
    }

    func joined(separator: String) -> String {
        lock.lock(); defer { lock.unlock() }
        return items.joined(separator: separator)
    }
}
