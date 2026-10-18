import AppKit
import Observation

/// Runs one tool job: resolves the destination, stages outputs, reports progress and publishes
/// results only if every item succeeded. One runner exists per tool (see `JobCenter`), so a job
/// keeps running when the user navigates to another tool.
@MainActor
@Observable
final class JobRunner {
    enum Phase: Equatable {
        case idle
        case running
        case succeeded
        case failed(String)
        case cancelled
    }

    /// The files the user picked for this tool. Kept here so the selection survives navigation.
    var inputs: [URL] = []

    private(set) var phase: Phase = .idle
    private(set) var progress: Double = 0
    private(set) var status = ""
    private(set) var outputFolder: URL?
    private(set) var outputs: [URL] = []
    private(set) var startedAt: Date?
    private var task: Task<Void, Never>?

    var isRunning: Bool { phase == .running }

    /// Starts a job.
    /// - Parameters:
    ///   - title: Used for the result folder name, e.g. "Compress Video".
    ///   - publishesFiles: Pass false for jobs that don't write files (results are shown in the UI).
    ///   - work: Runs off the main actor. Write outputs with `context.output(...)`.
    func start(
        title: String,
        publishesFiles: Bool = true,
        work: @escaping @Sendable (JobContext) async throws -> Void
    ) {
        guard !isRunning else { return }
        var base: URL?
        if publishesFiles {
            guard let resolved = OutputManager.resolveBaseFolder(jobTitle: title) else { return }
            base = resolved
        }

        phase = .running
        progress = 0
        status = "Starting…"
        outputs = []
        outputFolder = nil
        startedAt = Date()

        task = Task { [weak self] in
            var staging: URL?
            do {
                if let base { staging = try OutputManager.makeStagingFolder(near: base) }
                let context = JobContext(stagingFolder: staging, runner: self)
                let inner = Task.detached(priority: .userInitiated) { try await work(context) }
                try await withTaskCancellationHandler {
                    try await inner.value
                } onCancel: {
                    inner.cancel()
                }
                try Task.checkCancellation()

                if let base, let staging {
                    let produced = (try? FileManager.default.contentsOfDirectory(atPath: staging.path)) ?? []
                    guard !produced.isEmpty else { throw ToolError.failed("Nothing was produced.") }
                    let folder = try OutputManager.publish(staging: staging, to: base, jobTitle: title)
                    self?.finishSuccess(folder: folder)
                } else {
                    self?.finishSuccess(folder: nil)
                }
            } catch {
                if let staging { OutputManager.discard(staging: staging) }
                if error is CancellationError || (error as? ToolError).map({ if case .cancelled = $0 { true } else { false } }) == true || Task.isCancelled {
                    self?.phase = .cancelled
                    self?.status = "Cancelled"
                } else {
                    self?.phase = .failed(error.localizedDescription)
                    self?.status = ""
                }
            }
            self?.task = nil
        }
    }

    func cancel() {
        task?.cancel()
    }

    /// Clears the result so the tool returns to its ready state. Keeps the selected inputs.
    func reset() {
        guard !isRunning else { return }
        phase = .idle
        progress = 0
        status = ""
        outputs = []
        outputFolder = nil
    }

    private func finishSuccess(folder: URL?) {
        outputFolder = folder
        if let folder {
            let contents = (try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
            outputs = contents.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        }
        progress = 1
        phase = .succeeded
        status = "Done"
        if let folder, AppSettings.revealWhenDone {
            NSWorkspace.shared.activateFileViewerSelecting(outputs.isEmpty ? [folder] : outputs)
        }
        if !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
    }

    fileprivate func update(progress: Double? = nil, status: String? = nil) {
        guard isRunning else { return }
        if let progress { self.progress = min(max(progress, 0), 1) }
        if let status { self.status = status }
    }
}

/// Handed to a job's work closure. Thread-safe; call from any context.
final class JobContext: @unchecked Sendable {
    /// Folder where outputs must be written. Nil for jobs that don't publish files.
    let stagingFolder: URL?
    private weak var runner: JobRunner?
    private let lock = NSLock()
    private var usedNames = Set<String>()

    init(stagingFolder: URL?, runner: JobRunner?) {
        self.stagingFolder = stagingFolder
        self.runner = runner
    }

    /// A unique output URL derived from an input file, e.g. `clip.mov` → `clip-compressed.mp4`.
    /// - Parameters:
    ///   - suffix: Appended to the base name with a hyphen. Nil keeps the original name.
    ///   - ext: New file extension. Nil keeps the input's extension.
    func output(for input: URL, suffix: String? = nil, extension ext: String? = nil) -> URL {
        let base = input.deletingPathExtension().lastPathComponent
        let name = suffix.map { "\(base)-\($0)" } ?? base
        return output(named: name, extension: ext ?? input.pathExtension)
    }

    /// A unique output URL with an explicit name, e.g. `output(named: "Merged", extension: "pdf")`.
    func output(named name: String, extension ext: String) -> URL {
        guard let stagingFolder else { preconditionFailure("This job doesn't publish files.") }
        lock.lock(); defer { lock.unlock() }
        let cleanName = OutputManager.sanitize(name)
        var candidate = ext.isEmpty ? cleanName : "\(cleanName).\(ext)"
        var counter = 2
        while usedNames.contains(candidate.lowercased()) {
            candidate = ext.isEmpty ? "\(cleanName) \(counter)" : "\(cleanName) \(counter).\(ext)"
            counter += 1
        }
        usedNames.insert(candidate.lowercased())
        return stagingFolder.appendingPathComponent(candidate)
    }

    /// A unique subfolder inside the results, e.g. for "PDF to Images" with many pages per input.
    func outputFolder(named name: String) throws -> URL {
        let url = output(named: name, extension: "")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A scratch folder for intermediate files. Not published; deleted with the staging folder.
    func makeScratchFolder() throws -> URL {
        let parent = stagingFolder?.deletingLastPathComponent() ?? FileManager.default.temporaryDirectory
        let url = parent.appendingPathComponent("scratch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Overall progress, 0...1.
    func setProgress(_ value: Double) {
        Task { @MainActor [weak runner] in runner?.update(progress: value) }
    }

    func setStatus(_ text: String) {
        Task { @MainActor [weak runner] in runner?.update(status: text) }
    }

    /// Processes inputs one after another, mapping each item's 0...1 progress onto overall progress
    /// and updating the status line. Throws on the first failure, so nothing gets published.
    func forEach(
        _ inputs: [URL],
        verb: String = "Processing",
        _ body: (_ input: URL, _ progress: @escaping @Sendable (Double) -> Void) async throws -> Void
    ) async throws {
        let total = Double(max(inputs.count, 1))
        for (index, input) in inputs.enumerated() {
            try Task.checkCancellation()
            let prefix = inputs.count > 1 ? "\(verb) \(index + 1) of \(inputs.count): " : "\(verb) "
            setStatus(prefix + input.lastPathComponent)
            let start = Double(index) / total
            setProgress(start)
            do {
                try await body(input) { [weak self] fraction in
                    self?.setProgress(start + min(max(fraction, 0), 1) / total)
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw ToolError.failed("\(input.lastPathComponent): \(error.localizedDescription)")
            }
        }
        setProgress(1)
    }
}

/// Keeps one `JobRunner` per tool for the lifetime of the app.
@MainActor
final class JobCenter {
    static let shared = JobCenter()
    private var runners: [String: JobRunner] = [:]

    func runner(for toolID: String) -> JobRunner {
        if let runner = runners[toolID] { return runner }
        let runner = JobRunner()
        runners[toolID] = runner
        return runner
    }

    var activeCount: Int { runners.values.filter(\.isRunning).count }
}
