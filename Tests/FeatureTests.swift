import XCTest
import AppKit
import AVFoundation
import PDFKit
@testable import Toolbox

final class FeatureTests: XCTestCase {
    private var root: URL!
    private var staging: [URL] = []
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ToolboxTests-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        for folder in staging { OutputManager.discard(staging: folder) }
        staging = []
        try? FileManager.default.removeItem(at: root)
    }
    private func context(_ inputs: [URL] = []) throws -> JobContext {
        let context = try JobContext(destination: OutputDestination(folder: root.appendingPathComponent("results"), besideSources: false), inputs: inputs, runner: nil)
        if let folder = context.stagingRoot { staging.append(folder) }
        return context
    }
    private func outputs(_ context: JobContext) throws -> [URL] {
        try context.stagedResults.flatMap { try FileManager.default.contentsOfDirectory(at: $0.staging, includingPropertiesForKeys: nil) }
    }
    private func run(_ job: ToolJob, inputs: [URL], context: JobContext) async throws {
        switch job {
        case .each(_, let body): for input in inputs { try await body(input, context, { _ in }) }
        case .all(let body): try await body(inputs, context)
        }
    }
    private func makePDF() throws -> URL {
        let output = root.appendingPathComponent("Document.pdf")
        try DocumentConverter.renderPDF(DocumentConverter.styled("Hello Toolbox\nName  Amount\nApples  42\nPrivate & <public>"), to: output)
        return output
    }

    func testAdvertisedConversionMatrixHas276Routes() {
        let inputs = ["jpg","png","webp","heic","tiff","svg","avif","bmp", "mp3","m4a","wav","flac","ogg","opus","aiff","wma",
                      "mp4","mov","mkv","webm","avi","wmv","gif", "pdf", "docx","pages","md","rtf","rtfd","textClipping","txt",
                      "ppt","pptx", "xlsx","xls","ods","csv","tsv", "epub", "srt","vtt", "zip","tar","gz","rar"]
        let routes = inputs.flatMap { ConversionCatalog.targets(for: URL(fileURLWithPath: "sample.\($0)")) }
        XCTAssertEqual(routes.count, 276)
        XCTAssertFalse(routes.contains("rar")); XCTAssertFalse(routes.contains("xls")); XCTAssertFalse(routes.contains("ppt"))
        XCTAssertEqual(ConversionCatalog.commonTargets(for: [root.appendingPathComponent("a.pdf"), root.appendingPathComponent("b.docx")]), ["pages","jpg","png","epub","txt","md","html"])
        XCTAssertTrue(ConversionCatalog.targets(for: root.appendingPathComponent("unknown.xyz")).isEmpty)
    }
    func testSubtitleRoundTripRetainsTimings() throws {
        let cues = [SubtitleCue(start: 1.234, end: 4.567, text: "Hello\nworld"), SubtitleCue(start: 62, end: 65, text: "Another cue")]
        XCTAssertEqual(Subtitles.parse(Subtitles.serialize(cues, as: .vtt)), cues)
        XCTAssertEqual(Subtitles.parse(Subtitles.serialize(cues, as: .srt)), cues)
        XCTAssertNil(MediaEditOps.time("nan")); XCTAssertNil(MediaEditOps.time("-1"))
        XCTAssertThrowsError(try MediaEditOps.times("3,", duration: 4))
        XCTAssertThrowsError(try MediaEditOps.ranges("3-2", duration: 5))
    }
    func testArchivesRoundTripAndRejectTraversalAndLinks() async throws {
        let folder = root.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("file with spaces.txt")
        try "Original contents".write(to: file, atomically: true, encoding: .utf8)
        for format in ["zip", "tar", "gz"] {
            let archive = root.appendingPathComponent("archive.\(format == "gz" ? "tar.gz" : format)")
            try await ArchiveEngine.packDirectory(folder, format: format, to: archive)
            let extracted = root.appendingPathComponent("extracted-\(format)", isDirectory: true)
            try await ArchiveEngine.extract(archive, to: extracted)
            XCTAssertEqual(try String(contentsOf: extracted.appendingPathComponent(file.lastPathComponent), encoding: .utf8), "Original contents")
        }
        for unsafe in ["../outside", "/absolute", "a/../../outside", "a\\..\\outside"] { XCTAssertThrowsError(try ArchiveEngine.validatePath(unsafe)) }
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("link"), withDestinationURL: file)
        let archive = root.appendingPathComponent("links.tar")
        try await ArchiveEngine.packDirectory(folder, format: "tar", to: archive)
        do { try await ArchiveEngine.extract(archive, to: root.appendingPathComponent("unsafe")); XCTFail("Links must be rejected") } catch { }
    }
    func testPDFExportsProduceReadableDocuments() async throws {
        let input = try makePDF()
        let before = try Data(contentsOf: input)
        for target in ["docx", "xlsx", "pptx", "epub", "txt", "md"] {
            let context = try context([input])
            try await run(ConversionEngine.job(target: target), inputs: [input], context: context)
            let output = try XCTUnwrap(outputs(context).first)
            XCTAssertGreaterThan(PDFOps.fileSize(output), 0)
            if ["xlsx", "pptx", "epub"].contains(target) {
                let unpacked = root.appendingPathComponent("package-\(target)", isDirectory: true)
                try await ArchiveEngine.extract(output, to: unpacked)
                let enumerator = FileManager.default.enumerator(at: unpacked, includingPropertiesForKeys: nil)!
                while let file = enumerator.nextObject() as? URL {
                    if ["xml", "rels", "opf", "xhtml"].contains(file.pathExtension) {
                        XCTAssertNoThrow(try XMLDocument(contentsOf: file, options: .nodeLoadExternalEntitiesNever), file.lastPathComponent)
                    }
                }
                if target == "xlsx" {
                    let xml = try String(contentsOf: unpacked.appendingPathComponent("xl/worksheets/sheet1.xml"), encoding: .utf8)
                    XCTAssertTrue(xml.contains("Apples")); XCTAssertTrue(xml.contains("&amp;")); XCTAssertFalse(xml.contains("<f>"))
                }
            }
            if target == "docx" {
                let result = try await ProcessRunner.runChecked(URL(fileURLWithPath: "/usr/bin/textutil"), arguments: ["-convert", "txt", "-stdout", output.path])
                XCTAssertTrue(result.stdout.contains("Hello Toolbox"))
            }
            if target == "epub" {
                let text = try await DocumentConverter.readEPUB(output, scratch: root.appendingPathComponent("readbook"))
                XCTAssertTrue(text.contains("Hello Toolbox"))
            }
        }
        XCTAssertEqual(try Data(contentsOf: input), before)
    }
    func testPDFImageExportUses300DPI() async throws {
        let input = try makePDF(), context = try context()
        try await run(ConversionEngine.job(target: "png"), inputs: [input], context: context)
        let folder = try XCTUnwrap(outputs(context).first)
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).first)
        let image = try ImageEditorOps.load(file)
        XCTAssertEqual(image.width, 2550); XCTAssertEqual(image.height, 3300)
    }
    func testImageRedactionChangesPixelsAndCropMatchesPreviewCoordinates() throws {
        let cg = try XCTUnwrap(CGContext(data: nil, width: 200, height: 200, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        cg.setFillColor(NSColor.blue.cgColor); cg.fill(CGRect(x: 0,y: 0,width: 200,height: 200))
        cg.setFillColor(NSColor.red.cgColor); cg.fill(CGRect(x: 0,y: 100,width: 200,height: 100))
        let image = try XCTUnwrap(cg.makeImage())
        var options = ImageEditOptions(); options.crop = CGRect(x: 0, y: 0, width: 1, height: 0.5)
        let cropped = try ImageEditorOps.apply(image, operation: "crop", options: options)
        XCTAssertEqual(cropped.height, 100)
        let cropColor = sample(cropped, x: 50, y: 50)
        XCTAssertGreaterThan(cropColor.0, 200); XCTAssertLessThan(cropColor.2, 20)
        options.color = .black
        options.marks = [ImageMark(rect: CGRect(x: 0.25,y: 0.25,width: 0.5,height: 0.5),kind: "box",text: "")]
        let redacted = try ImageEditorOps.apply(image, operation: "redact", options: options)
        let center = sample(redacted, x: 100, y: 100)
        XCTAssertLessThan(center.0+center.1+center.2, 10)
        let original = sample(image, x: 100, y: 100)
        XCTAssertGreaterThan(original.0+original.1+original.2, 200)
    }
    private func sample(_ image: CGImage, x: Int, y: Int) -> (Int,Int,Int) {
        var pixel = [UInt8](repeating: 0, count: 4)
        let ctx = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: -x, y: -y, width: image.width, height: image.height))
        return (Int(pixel[0]), Int(pixel[1]), Int(pixel[2]))
    }
    func testRealMediaSplitSnapshotsChannelsAndBleep() async throws {
        guard Dependencies.locate(.ffmpeg) != nil else { throw XCTSkip("FFmpeg is not installed") }
        let video = root.appendingPathComponent("source.mp4")
        try await FFmpeg.run(["-f","lavfi","-i","color=c=red:s=160x120:r=30:d=2","-f","lavfi","-i","sine=frequency=440:duration=2","-c:v","libx264","-c:a","aac","-shortest",video.path])
        var options = MediaEditOptions(); options.times = "1"
        let split = try context()
        try await run(MediaEditOps.job(id: "video.split", options: options), inputs: [video], context: split)
        let clips = try FileManager.default.contentsOfDirectory(at: XCTUnwrap(outputs(split).first), includingPropertiesForKeys: nil)
        XCTAssertEqual(clips.count, 2)
        for clip in clips { let info = try await FFmpeg.probe(clip); XCTAssertEqual(info.duration, 1, accuracy: 0.1) }
        let frames = try context()
        options.times = "0, 1.5"
        try await run(MediaEditOps.job(id: "video.snapshots", options: options), inputs: [video], context: frames)
        let images = try FileManager.default.contentsOfDirectory(at: XCTUnwrap(outputs(frames).first), includingPropertiesForKeys: nil)
        XCTAssertEqual(images.count, 2)
        XCTAssertEqual(try ImageEditorOps.load(images[0]).width, 160)
        options.format = .wav; options.channels = 2
        let channels = try context()
        try await run(MediaEditOps.job(id: "audio.channels", options: options), inputs: [video], context: channels)
        let stereo = try AVAudioFile(forReading: XCTUnwrap(outputs(channels).first))
        XCTAssertEqual(stereo.processingFormat.channelCount, 2)
        options.ranges = "0.5-1.0"; options.frequency = 1000
        let bleep = try context()
        try await run(MediaEditOps.job(id: "audio.bleep", options: options), inputs: [video], context: bleep)
        let audio = try AVAudioFile(forReading: XCTUnwrap(outputs(bleep).first))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: AVAudioFrameCount(audio.length)))
        try audio.read(into: buffer)
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        let rate = audio.processingFormat.sampleRate
        func frequency(_ start: Double, _ end: Double) -> Double {
            let lo = Int(start*rate), hi = Int(end*rate)
            var crossings = 0
            for i in (lo+1)..<hi where samples[i-1] < 0 && samples[i] >= 0 { crossings += 1 }
            return Double(crossings)/(end-start)
        }
        XCTAssertEqual(frequency(0.1,0.4), 440, accuracy: 8)
        XCTAssertEqual(frequency(0.6,0.9), 1000, accuracy: 8)
    }
    func testImageFormatExportsAndSVGInput() async throws {
        let cg = try XCTUnwrap(CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        cg.setFillColor(NSColor.red.cgColor); cg.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        let image = try XCTUnwrap(cg.makeImage())
        let input = root.appendingPathComponent("source.png")
        try XCTUnwrap(PDFOps.encode(image, as: .png, quality: 1, dpi: nil)).write(to: input)
        for target in ["jpg", "tiff", "heic", "bmp", "webp", "avif", "pdf"] {
            if ["avif", "webp"].contains(target) && Dependencies.locate(.ffmpeg) == nil { continue }
            let context = try context()
            try await run(ConversionEngine.job(target: target), inputs: [input], context: context)
            let output = try XCTUnwrap(outputs(context).first)
            XCTAssertGreaterThan(PDFOps.fileSize(output), 0)
            if target == "pdf" { XCTAssertEqual(try PDFOps.open(output).pageCount, 1) }
            else {
                if let result = try? ImageEditorOps.load(output) { XCTAssertEqual(result.width, 64); XCTAssertEqual(result.height, 48) }
                else { let result = try await FFmpeg.probe(output); XCTAssertEqual(result.width, 64); XCTAssertEqual(result.height, 48) }
            }
        }
        let svg = root.appendingPathComponent("vector.svg")
        try "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"64\" height=\"48\"><rect width=\"64\" height=\"48\" fill=\"red\"/></svg>".write(to: svg, atomically: true, encoding: .utf8)
        let svgContext = try context()
        try await run(ConversionEngine.job(target: "png"), inputs: [svg], context: svgContext)
        XCTAssertEqual(try ImageEditorOps.load(XCTUnwrap(outputs(svgContext).first)).width, 64)
    }
    func testVideoRedactionAndAudioVisualizer() async throws {
        guard Dependencies.locate(.ffmpeg) != nil else { throw XCTSkip("FFmpeg is not installed") }
        let video = root.appendingPathComponent("red.mp4")
        try await FFmpeg.run(["-f","lavfi","-i","color=c=red:s=160x120:r=30:d=2","-f","lavfi","-i","sine=frequency=440:duration=2","-c:v","libx264","-c:a","aac","-shortest",video.path])
        for blur in [false,true] {
            var options = MediaEditOptions(); options.start = 0; options.end = 1; options.blur = blur
            let context = try context()
            try await run(MediaEditOps.job(id: "video.redact", options: options), inputs: [video], context: context)
            let info = try await FFmpeg.probe(XCTUnwrap(outputs(context).first))
            XCTAssertTrue(info.hasVideo)
        }
        let context = try context()
        try await run(MediaEditOps.job(id: "audio.visualize", options: MediaEditOptions()), inputs: [video], context: context)
        let info = try await FFmpeg.probe(XCTUnwrap(outputs(context).first))
        XCTAssertTrue(info.hasAudio); XCTAssertTrue(info.hasVideo); XCTAssertEqual(info.width, 1280)
    }
    func testSilenceTrimKeepsInteriorPauses() async throws {
        guard Dependencies.locate(.ffmpeg) != nil else { throw XCTSkip("FFmpeg is not installed") }
        let input = root.appendingPathComponent("silence.wav")
        try await FFmpeg.run(["-f","lavfi","-i","sine=frequency=440:duration=4", "-af", "volume=0:enable='lt(t,0.5)+between(t,1.5,2)+gte(t,3.5)'", input.path])
        let range = try await AudioSilence.edges(input, range: 0...4)
        XCTAssertEqual(range.lowerBound, 0.5, accuracy: 0.05)
        XCTAssertEqual(range.upperBound, 3.5, accuracy: 0.05)
    }
    func testSizeTargetsAndLegacyMediaFormats() async throws {
        let input = root.appendingPathComponent("large.png")
        let w = 256, h = 256
        var pixels = [UInt8](repeating: 255, count: w*h*4)
        var seed: UInt32 = 12345
        for i in pixels.indices where i % 4 != 3 { seed = seed &* 1664525 &+ 1013904223; pixels[i] = UInt8(truncatingIfNeeded: seed >> 24) }
        let context = try XCTUnwrap(CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w*4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try XCTUnwrap(context.makeImage())
        try XCTUnwrap(PDFOps.encode(image, as: .png, quality: 1, dpi: nil)).write(to: input)
        let output = root.appendingPathComponent("target.jpg")
        try TargetCompression.image(input, to: output, format: .jpeg, bytes: 20_000, maxDimension: 0, keepMetadata: false)
        XCTAssertLessThanOrEqual(PDFOps.fileSize(output), 20_000)
        XCTAssertGreaterThan(PDFOps.fileSize(output), 0)
        let pdf = try PDFOps.open(makePDF())
        let compressedPDF = root.appendingPathComponent("compressed.pdf")
        try TargetCompression.pdf(pdf, to: compressedPDF, bytes: 30_000)
        XCTAssertLessThanOrEqual(PDFOps.fileSize(compressedPDF), 30_000)
        guard Dependencies.locate(.ffmpeg) != nil else { throw XCTSkip("FFmpeg is not installed") }
        let audio = root.appendingPathComponent("tone.wav")
        try await FFmpeg.run(["-f","lavfi","-i","sine=frequency=440:duration=0.3", audio.path])
        for target in ["mp3","m4a","flac","ogg","opus","aiff","wma"] {
            let context = try self.context()
            try await run(ConversionEngine.job(target: target), inputs: [audio], context: context)
            let info = try await FFmpeg.probe(XCTUnwrap(outputs(context).first))
            XCTAssertTrue(info.hasAudio, target)
        }
        let video = root.appendingPathComponent("legacy.mp4")
        try await FFmpeg.run(["-f","lavfi","-i","color=c=red:s=160x120:r=30:d=0.3", "-c:v","libx264", video.path])
        let legacy = try self.context()
        try await run(ConversionEngine.job(target: "wmv"), inputs: [video], context: legacy)
        let info = try await FFmpeg.probe(XCTUnwrap(outputs(legacy).first))
        XCTAssertEqual(info.videoCodec, "wmv2")
    }
}
