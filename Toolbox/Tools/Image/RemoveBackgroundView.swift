import SwiftUI
import CoreImage
import UniformTypeIdentifiers
import Vision

struct RemoveBackgroundView: View {
    let tool: Tool

    enum Background: String, CaseIterable, Identifiable {
        case transparent, color
        var id: Self { self }
        var label: String { self == .transparent ? "Transparent" : "Solid color" }
    }

    @State private var background = Background.transparent
    @State private var color = Color.white
    @State private var cropToSubject = false

    var body: some View {
        BatchToolView(tool: tool, accepts: UTType.imageInputs, actionTitle: "Remove Background", noun: "images",
                      job: { Self.job(background: background, cropToSubject: cropToSubject,
                                      fill: NSColor(color).usingColorSpace(.sRGB)?.cgColor) }) {
            Picker("Background", selection: $background) {
                ForEach(Background.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .fixedSize()
            if background == .color {
                ColorPicker("Color", selection: $color, supportsOpacity: false)
            }
            Toggle("Crop to the subject", isOn: $cropToSubject)
            Text("Uses Apple's on-device subject detection. Results are saved as PNG.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    /// What the action button runs. The launcher's quick action runs it with the default settings.
    static func job(background: Background, cropToSubject: Bool, fill: CGColor?) -> ToolJob {
        .each(verb: "Cutting out") { input, context, progress in
            let source = try ImageIOHelpers.source(for: input)
            let image = try ImageIOHelpers.orientedImage(source, index: CGImageSourceGetPrimaryImageIndex(source))
            progress(0.2)
            let result = try ImageBackgroundRemover.cutOut(image, crop: cropToSubject,
                                                           background: background == .color ? fill : nil)
            progress(0.9)
            let output = context.output(for: input, suffix: "cutout", extension: "png")
            guard let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil) else {
                throw ToolError.failed("Couldn't create the PNG.")
            }
            CGImageDestinationAddImage(destination, result, nil)
            guard CGImageDestinationFinalize(destination) else { throw ToolError.failed("Couldn't write the PNG.") }
            progress(1)
        }
    }
}

enum ImageBackgroundRemover {
    /// Lifts every detected foreground subject and returns it on transparency (or on `background`).
    static func cutOut(_ image: CGImage, crop: Bool, background: CGColor?) throws -> CGImage {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            throw ToolError.failed("Subject detection failed: \(error.localizedDescription)")
        }
        guard let observation = request.results?.first, !observation.allInstances.isEmpty else {
            throw ToolError.failed("No subject found in this image.")
        }
        let buffer = try observation.generateMaskedImage(ofInstances: observation.allInstances, from: handler,
                                                         croppedToInstancesExtent: crop)
        var output = CIImage(cvPixelBuffer: buffer)
        if let background {
            output = output.composited(over: CIImage(color: CIColor(cgColor: background)).cropped(to: output.extent))
        }
        let space = image.colorSpace?.model == .rgb ? image.colorSpace! : CGColorSpace(name: CGColorSpace.sRGB)!
        guard let result = ImageIOHelpers.ciContext.createCGImage(output, from: output.extent, format: .RGBA8, colorSpace: space) else {
            throw ToolError.failed("Couldn't render the cutout.")
        }
        return result
    }
}
