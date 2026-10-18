import SwiftUI
import UniformTypeIdentifiers
import QuickLookThumbnailing

/// Drop zone + file list used by most tools. Accepts files and folders (folders are scanned
/// recursively for matching files, which is how batch processing of a whole folder works).
struct FileListInput: View {
    @Binding var files: [URL]
    let accepts: [UTType]
    var allowsMultiple = true
    var reorderable = false
    var title = "Files"
    /// Short description of what to drop, e.g. "videos". Defaults to "files".
    var noun = "files"

    @State private var isTargeted = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.headline)
                if !files.isEmpty {
                    Text("\(files.count)").font(.caption.weight(.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                }
                Spacer()
                if !files.isEmpty {
                    if allowsMultiple {
                        Button("Add…") { choose() }
                    }
                    Button(allowsMultiple ? "Clear" : "Remove") { files.removeAll() }
                }
            }
            if files.isEmpty {
                dropZone
            } else {
                fileList
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            add(urls)
            return true
        } isTargeted: { isTargeted = $0 }
    }

    private var dropZone: some View {
        Button(action: choose) {
            VStack(spacing: 10) {
                Image(systemName: isTargeted ? "arrow.down.doc.fill" : "arrow.down.doc")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(isTargeted ? Color.accentColor : .secondary)
                Text(allowsMultiple ? "Drop \(noun) or a folder here" : "Drop a file here")
                    .font(.title3.weight(.medium))
                Text("or click to choose · \(typeDescription)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 150)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isTargeted ? Color.accentColor.opacity(0.08) : Color.secondary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(isTargeted ? Color.accentColor : Color.secondary.opacity(0.35),
                              style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
        )
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: isTargeted)
    }

    private var fileList: some View {
        List {
            ForEach(files, id: \.self) { url in
                HStack(spacing: 10) {
                    if reorderable {
                        Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary)
                    }
                    FileThumbnail(url: url, size: 30)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                        Text(url.deletingLastPathComponent().path(percentEncoded: false))
                            .font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.head)
                    }
                    Spacer()
                    Text(FileSize.string(for: url)).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    Button {
                        files.removeAll { $0 == url }
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.borderless)
                    .help("Remove")
                }
                .padding(.vertical, 2)
                .contextMenu {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    Button("Remove") { files.removeAll { $0 == url } }
                }
            }
            .onMove(perform: reorderable ? { files.move(fromOffsets: $0, toOffset: $1) } : nil)
        }
        .listStyle(.bordered)
        .alternatingRowBackgrounds()
        .frame(height: min(CGFloat(files.count) * 46 + 12, 300))
        .overlay {
            if isTargeted {
                RoundedRectangle(cornerRadius: 6).strokeBorder(Color.accentColor, lineWidth: 2)
            }
        }
    }

    private var typeDescription: String {
        let names = accepts.compactMap { type -> String? in
            if type == .item || type == .data { return "any file" }
            return type.localizedDescription?.lowercased()
        }
        return names.prefix(3).joined(separator: ", ")
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = allowsMultiple
        panel.canChooseDirectories = allowsMultiple
        panel.canChooseFiles = true
        panel.allowedContentTypes = accepts
        guard panel.runModal() == .OK else { return }
        add(panel.urls)
    }

    private func add(_ urls: [URL]) {
        let expanded = FileListInput.expand(urls, accepting: accepts)
        guard !expanded.isEmpty else { NSSound.beep(); return }
        if allowsMultiple {
            for url in expanded where !files.contains(url) { files.append(url) }
        } else {
            files = [expanded[0]]
        }
    }

    /// Expands folders recursively and keeps only files matching `types`.
    static func expand(_ urls: [URL], accepting types: [UTType]) -> [URL] {
        var result: [URL] = []
        for url in urls where url.isFileURL {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue, !conforms(url, to: types) {
                let enumerator = FileManager.default.enumerator(
                    at: url, includingPropertiesForKeys: [.isRegularFileKey, .contentTypeKey],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants])
                var found: [URL] = []
                while let item = enumerator?.nextObject() as? URL {
                    if (try? item.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true, conforms(item, to: types) {
                        found.append(item)
                    }
                }
                result += found.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            } else if conforms(url, to: types) {
                result.append(url)
            }
        }
        return result
    }

    static func conforms(_ url: URL, to types: [UTType]) -> Bool {
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType)
            ?? UTType(filenameExtension: url.pathExtension)
        guard let type else { return types.contains(.item) || types.contains(.data) }
        return types.contains { type.conforms(to: $0) }
    }
}

/// Finder-style thumbnail for a file, generated with Quick Look.
struct FileThumbnail: View {
    let url: URL
    var size: CGFloat = 32
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
            } else {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().aspectRatio(contentMode: .fit)
            }
        }
        .frame(width: size, height: size)
        .task(id: url) {
            let request = QLThumbnailGenerator.Request(
                fileAt: url, size: CGSize(width: size, height: size),
                scale: NSScreen.main?.backingScaleFactor ?? 2, representationTypes: .thumbnail)
            if let representation = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) {
                image = representation.nsImage
            }
        }
    }
}

extension UTType {
    /// Common media groupings used by tools.
    static let videoInputs: [UTType] = [.movie, .video, .mpeg4Movie, .quickTimeMovie, .avi,
                                        UTType("org.matroska.mkv") ?? .movie, UTType("org.webmproject.webm") ?? .movie]
    static let audioInputs: [UTType] = [.audio, .mp3, .wav, .aiff, .mpeg4Audio,
                                        UTType("org.xiph.flac") ?? .audio, UTType("org.xiph.ogg-audio") ?? .audio]
    static let mediaInputs: [UTType] = videoInputs + audioInputs
    static let imageInputs: [UTType] = [.image]
    static let pdfInputs: [UTType] = [.pdf]
}
