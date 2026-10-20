import SwiftUI
import SystemConfiguration
import UniformTypeIdentifiers

/// Shares files with phones and computers on the same network through a browser, and receives
/// files from them. One session for the app, so sharing keeps going while you use other tools.
@MainActor
@Observable
final class WiFiShare {
    static let shared = WiFiShare()

    struct Transfer: Identifiable {
        let id: UUID
        var device: String
        var name: String
        var isUpload: Bool
        var bytes: Int64
        var total: Int64
        var state: LocalHTTPServer.Transfer.State
        var date: Date
    }

    struct Device: Identifiable {
        var id: String { address }
        let address: String
        var name: String
        var lastSeen: Date
        var isConnected = false
    }

    /// What's shared. Changes reach open browser pages right away.
    var files: [URL] = [] {
        didSet { if files != oldValue { filesChanged() } }
    }
    var allowsUploads = true {
        didSet {
            guard allowsUploads != oldValue else { return }
            gate.setEnabled(allowsUploads)
            broadcastState()
        }
    }
    /// Where received files go. Nil uses the results folder from Settings, or Downloads when results
    /// go next to the originals.
    var receiveFolder: URL?

    private(set) var server: LocalHTTPServer?
    private(set) var url: URL?
    private(set) var qrCode: NSImage?
    private(set) var isStarting = false
    private(set) var error: String?
    private(set) var transfers: [Transfer] = []
    private(set) var devices: [Device] = []
    private(set) var received: [URL] = []

    private let gate = UploadGate()
    private var ids: [URL: String] = [:]
    private var nextID = 1
    /// Which device each open event stream belongs to.
    private var streams: [UUID: String] = [:]
    private var zip: (files: [URL], url: URL)?
    private var zipTask: (files: [URL], task: Task<URL, Error>)?
    private var scratch: URL?

    var isSharing: Bool { server != nil }
    var destinationFolder: URL { receiveFolder ?? OutputManager.fixedFolder ?? OutputManager.downloadsFolder }
    var connectedCount: Int { devices.filter(\.isConnected).count }

    func start() async {
        guard server == nil, !isStarting else { return }
        isStarting = true
        error = nil
        defer { isStarting = false }
        let gate = gate
        let server = LocalHTTPServer { [weak self] request in
            await self?.handle(request) ?? .notFound
        }
        server.uploadDestination = { gate.file(for: $0) }
        server.onTransfer = { [weak self] transfer in Task { @MainActor in self?.update(transfer) } }
        server.onEventStreamClosed = { [weak self] id in Task { @MainActor in self?.streamClosed(id) } }
        do {
            gate.configure(enabled: allowsUploads, staging: try OutputManager.makeStagingFolder(near: destinationFolder))
            try await server.start()
        } catch {
            gate.discard()
            self.error = error.localizedDescription
            return
        }
        self.server = server
        url = server.shareURL
        qrCode = url.flatMap { LocalHTTPServer.qrCode(for: $0.absoluteString) }
        if url == nil { error = "This Mac isn't on a network. Join the same Wi-Fi as the other device, then start again." }
    }

    func stop() {
        server?.stop()
        server = nil
        url = nil
        qrCode = nil
        streams = [:]
        devices = []
        zipTask?.task.cancel()
        zipTask = nil
        zip = nil
        gate.discard()
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
        scratch = nil
    }

    func clearHistory() {
        transfers.removeAll { $0.state != .active }
        received = []
    }

    // MARK: - Requests

    private func handle(_ request: LocalHTTPServer.Request) async -> LocalHTTPServer.Response {
        noteDevice(request)
        let reading = request.method == "GET" || request.method == "HEAD"
        switch (request.path, reading) {
        case ("/", true):
            return .html(WiFiSharePage.html)
        case ("/api/files", true):
            return .json(state)
        case ("/events", true):
            let id = UUID()
            streams[id] = request.client
            setConnected(request.client)
            server?.openEventStream(id, initial: [("files", stateJSON)])
            return LocalHTTPServer.Response(body: .events(id))
        case ("/all.zip", true):
            guard !files.isEmpty else { return .notFound }
            do { return .file(try await zipFile(), name: "\(Self.computerName) Files.zip") }
            catch { return .text("Couldn't create the ZIP: \(error.localizedDescription)", status: 500) }
        case ("/upload", false):
            return receive(request)
        default:
            guard reading, request.path.hasPrefix("/files/") else { return .notFound }
            let id = request.path.dropFirst("/files/".count).split(separator: "/").first.map(String.init)
            guard let url = files.first(where: { ids[$0] == id }), FileManager.default.fileExists(atPath: url.path) else { return .notFound }
            return .file(url, inline: request.query["inline"] != nil)
        }
    }

    private func receive(_ request: LocalHTTPServer.Request) -> LocalHTTPServer.Response {
        guard allowsUploads, let file = request.bodyFile else {
            return .text("This Mac isn't accepting files.", status: 403)
        }
        let folder = file.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: folder) }
        do {
            let published = try OutputManager.publish([(staging: folder, destination: destinationFolder)])
            received.insert(contentsOf: published, at: 0)
            return .json(["saved": published.first?.lastPathComponent ?? file.lastPathComponent])
        } catch {
            return .text("Couldn't save the file: \(error.localizedDescription)", status: 500)
        }
    }

    private func zipFile() async throws -> URL {
        let current = files
        if let zip, zip.files == current, FileManager.default.fileExists(atPath: zip.url.path) { return zip.url }
        if let zipTask, zipTask.files == current { return try await zipTask.task.value }
        let scratch = try scratchFolder()
        let task = Task.detached {
            let folder = scratch.appendingPathComponent(UUID().uuidString, isDirectory: true)
            let work = folder.appendingPathComponent("work", isDirectory: true)
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: work) }
            let output = folder.appendingPathComponent("Files.zip")
            try await ArchiveEngine.create(from: current, format: "zip", to: output, scratch: work)
            return output
        }
        zipTask = (current, task)
        let url = try await task.value
        if zipTask?.files == current { zipTask = nil }
        if files == current { zip = (current, url) }
        return url
    }

    private func scratchFolder() throws -> URL {
        if let scratch { return scratch }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Toolbox-Share-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        scratch = url
        return url
    }

    // MARK: - State

    private struct SharedState: Encodable {
        struct File: Encodable { let id: String; let name: String; let size: Int64; let kind: String }
        let host: String
        let uploads: Bool
        let files: [File]
    }

    private var state: SharedState {
        SharedState(host: Self.computerName, uploads: allowsUploads, files: files.map { url in
            SharedState.File(id: id(for: url), name: url.lastPathComponent, size: FileSize.bytes(for: url), kind: Self.kind(of: url))
        })
    }

    private var stateJSON: String {
        (try? JSONEncoder().encode(state)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    private func id(for url: URL) -> String {
        if let id = ids[url] { return id }
        let id = "\(nextID)"
        nextID += 1
        ids[url] = id
        return id
    }

    private func filesChanged() {
        zip = nil
        broadcastState()
    }

    private func broadcastState() {
        guard let server else { return }
        server.broadcast("files", data: stateJSON)
    }

    private func noteDevice(_ request: LocalHTTPServer.Request) {
        guard !request.client.isEmpty else { return }
        let name = LocalHTTPServer.deviceName(userAgent: request.userAgent)
        if let index = devices.firstIndex(where: { $0.address == request.client }) {
            devices[index].lastSeen = Date()
            if !request.userAgent.isEmpty { devices[index].name = name }
        } else {
            devices.insert(Device(address: request.client, name: name, lastSeen: Date()), at: 0)
        }
    }

    private func setConnected(_ client: String) {
        guard let index = devices.firstIndex(where: { $0.address == client }) else { return }
        devices[index].isConnected = true
    }

    private func streamClosed(_ id: UUID) {
        guard let client = streams.removeValue(forKey: id) else { return }
        guard !streams.values.contains(client), let index = devices.firstIndex(where: { $0.address == client }) else { return }
        devices[index].isConnected = false
        devices[index].lastSeen = Date()
    }

    private func update(_ transfer: LocalHTTPServer.Transfer) {
        if let index = transfers.firstIndex(where: { $0.id == transfer.id }) {
            // Progress can arrive after the end; never move a finished transfer back.
            guard transfers[index].state == .active else { return }
            transfers[index].bytes = max(transfers[index].bytes, transfer.bytes)
            transfers[index].state = transfer.state
        } else {
            transfers.insert(Transfer(id: transfer.id, device: LocalHTTPServer.deviceName(userAgent: transfer.userAgent),
                                      name: transfer.name, isUpload: transfer.isUpload, bytes: transfer.bytes,
                                      total: transfer.total, state: transfer.state, date: Date()), at: 0)
            if transfers.count > 30 { transfers.removeLast(transfers.count - 30) }
        }
    }

    // MARK: - Helpers

    static var computerName: String {
        (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? Host.current().localizedName ?? "Mac"
    }

    private static func kind(of url: URL) -> String {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return "file" }
        if type.conforms(to: .image) { return "image" }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return "video" }
        if type.conforms(to: .audio) { return "audio" }
        if type.conforms(to: .pdf) { return "pdf" }
        if type.conforms(to: .archive) { return "archive" }
        if type.conforms(to: .text) { return "text" }
        return "file"
    }
}

/// Decides, off the main actor, where an upload's bytes go while they arrive.
private final class UploadGate: @unchecked Sendable {
    private let lock = NSLock()
    private var enabled = false
    private var staging: URL?

    func configure(enabled: Bool, staging: URL) {
        lock.withLock { self.enabled = enabled; self.staging = staging }
    }

    func setEnabled(_ enabled: Bool) { lock.withLock { self.enabled = enabled } }

    func discard() {
        let staging = lock.withLock { defer { self.staging = nil }; return self.staging }
        if let staging { OutputManager.discard(staging: staging) }
    }

    /// A fresh file in its own staging folder, named after the upload.
    func file(for request: LocalHTTPServer.Request) -> URL? {
        guard request.path == "/upload", request.method == "PUT" || request.method == "POST" else { return nil }
        guard let staging = lock.withLock({ enabled ? staging : nil }) else { return nil }
        let folder = staging.appendingPathComponent(UUID().uuidString, isDirectory: true)
        guard (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)) != nil else { return nil }
        return folder.appendingPathComponent(Self.cleanName(request.query["name"] ?? ""))
    }

    /// A safe file name: no folders, no hidden files, at most 180 characters.
    static func cleanName(_ name: String) -> String {
        var clean = OutputManager.sanitize(name)
        while clean.hasPrefix(".") { clean.removeFirst() }
        if clean.isEmpty { clean = "Received file" }
        if clean.count > 180 {
            let ext = (clean as NSString).pathExtension
            clean = String((clean as NSString).deletingPathExtension.prefix(170)) + (ext.isEmpty ? "" : ".\(ext.prefix(9))")
        }
        return clean
    }
}

struct ShareWiFiView: View {
    let tool: Tool
    @State private var share = WiFiShare.shared
    /// Holds the list, so files handed over by the launcher show up here.
    @State private var runner: JobRunner
    @AppStorage("files.share-wifi.uploads") private var allowsUploads = true

    init(tool: Tool) {
        self.tool = tool
        _runner = State(initialValue: JobCenter.shared.runner(for: tool.id))
    }

    var body: some View {
        ToolPage(tool: tool) {
            FileListInput(files: $runner.inputs, accepts: [.item], title: "Files to share", noun: "files")
            if share.isSharing, let url = share.url {
                linkSection(url)
            }
            if let error = share.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            }
            ToolSection("Options") {
                OptionToggle("Let devices send files to this Mac", isOn: $allowsUploads)
                OptionNote("Received files are saved to \(share.destinationFolder.lastPathComponent) and never replace existing files.")
            }
            if !share.devices.isEmpty { devicesSection }
            if !share.transfers.isEmpty { transfersSection }
            if !share.received.isEmpty { receivedSection }
        } footer: {
            footer
        }
        .onChange(of: allowsUploads, initial: true) { share.allowsUploads = allowsUploads }
        .onChange(of: runner.inputs, initial: true) { share.files = runner.inputs }
    }

    private func linkSection(_ url: URL) -> some View {
        ToolSection("Open on your phone or computer",
                    footnote: "Both devices need to be on the same network. If macOS asks whether Toolbox may accept incoming network connections, choose Allow. Only people with this link can connect.") {
            HStack(alignment: .top, spacing: 18) {
                if let qr = share.qrCode {
                    Image(nsImage: qr)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 150, height: 150)
                        .padding(8)
                        .background(.white, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .accessibilityLabel("QR code for the sharing link")
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text("Scan the code with the phone's camera, or type this address into any browser:")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(url.absoluteString)
                        .font(.title3.monospaced())
                        .textSelection(.enabled)
                    HStack {
                        Button("Copy Link") { AIText.copy(url.absoluteString) }
                        Button("Open in Browser") { NSWorkspace.shared.open(url) }
                    }
                }
            }
        }
    }

    private var devicesSection: some View {
        ToolSection("Devices") {
            ForEach(share.devices) { device in
                HStack(spacing: 10) {
                    Image(systemName: symbol(for: device.name)).foregroundStyle(.secondary).frame(width: 20)
                    Text(device.name)
                    Text(device.address).foregroundStyle(.secondary).font(.callout.monospacedDigit())
                    Spacer()
                    if device.isConnected {
                        Label("Connected", systemImage: "circle.fill").labelStyle(.titleAndIcon)
                            .foregroundStyle(.green).font(.callout)
                    } else {
                        Text("Seen \(device.lastSeen, style: .relative) ago").foregroundStyle(.secondary).font(.callout)
                    }
                }
            }
        }
    }

    private var transfersSection: some View {
        ToolSection("Transfers") {
            ForEach(share.transfers) { transfer in
                HStack(spacing: 10) {
                    Image(systemName: transfer.isUpload ? "arrow.down.circle" : "arrow.up.circle")
                        .foregroundStyle(transfer.isUpload ? .blue : .green)
                        .help(transfer.isUpload ? "Received from \(transfer.device)" : "Sent to \(transfer.device)")
                    VStack(alignment: .leading, spacing: 1) {
                        Text(transfer.name).lineLimit(1).truncationMode(.middle)
                        Text("\(transfer.isUpload ? "From" : "To") \(transfer.device)").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    switch transfer.state {
                    case .active:
                        ProgressView(value: Double(transfer.bytes), total: Double(max(transfer.total, 1))).frame(width: 140)
                    case .finished:
                        Text(ByteCountFormatter.string(fromByteCount: transfer.total, countStyle: .file))
                            .foregroundStyle(.secondary).font(.callout.monospacedDigit())
                    case .failed:
                        Text("Stopped").foregroundStyle(.orange).font(.callout)
                    }
                }
            }
        }
    }

    private var receivedSection: some View {
        ToolSection("Received") {
            ForEach(share.received, id: \.self) { url in
                HStack(spacing: 10) {
                    FileThumbnail(url: url, size: 28)
                    Text(url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text(FileSize.string(for: url)).foregroundStyle(.secondary).font(.callout.monospacedDigit())
                    Button { NSWorkspace.shared.open(url) } label: { Image(systemName: "arrow.up.forward.app") }
                        .buttonStyle(.borderless).help("Open")
                    Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: { Image(systemName: "folder") }
                        .buttonStyle(.borderless).help("Show in Finder")
                }
                .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
            }
            HStack {
                Button("Show All in Finder") { NSWorkspace.shared.activateFileViewerSelecting(share.received) }
                Button("Clear List") { share.clearHistory() }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            Group {
                if share.isSharing {
                    let count = share.connectedCount
                    Label(count == 0 ? "Sharing. Waiting for a device to open the link…" : "Sharing with \(count) device\(count == 1 ? "" : "s")",
                          systemImage: "dot.radiowaves.left.and.right")
                } else if runner.inputs.isEmpty && !allowsUploads {
                    Text("Add files to share, or let devices send files to this Mac.").foregroundStyle(.secondary)
                } else {
                    Text("Files are sent straight over your network. Nothing is uploaded to the internet.").foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if share.isStarting { ProgressView().controlSize(.small) }
            Button {
                if share.isSharing { share.stop() } else { Task { await share.start() } }
            } label: {
                Text(share.isSharing ? "Stop Sharing" : "Start Sharing").frame(minWidth: 110)
            }
            .buttonStyle(.borderedProminent)
            .tint(share.isSharing ? .red : nil)
            .controlSize(.large)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(share.isStarting || (!share.isSharing && runner.inputs.isEmpty && !allowsUploads))
        }
        .frame(minHeight: 32)
    }

    private func symbol(for device: String) -> String {
        switch device {
        case "iPhone", "Android phone": "iphone"
        case "iPad", "Android tablet": "ipad"
        case "Mac": "laptopcomputer"
        default: "desktopcomputer"
        }
    }
}
