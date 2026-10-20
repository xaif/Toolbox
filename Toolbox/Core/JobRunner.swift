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
    /// The folder the results were saved in (the first result's, if they went next to originals in several).
    private(set) var outputFolder: URL?
    private(set) var outputs: [URL] = []
    private(set) var startedAt: Date?
    /// True for jobs started without the tool's window (see `QuickRun`).
    private(set) var runsInBackground = false
    private var task: Task<Void, Never>?

    var isRunning: Bool { phase == .running }

    /// Starts a job.
    /// - Parameters:
    ///   - title: Shown when asking where to save, e.g. "Compress Video".
    ///   - publishesFiles: Pass false for jobs that don't write files (results are shown in the UI).
    ///   - inputs: The files the job works on. Results named without a source file go next to the first.
    ///   - inBackground: For jobs started without the tool's window. Their results are always shown
    ///     in Finder, and the Dock icon doesn't bounce.
    ///   - work: Runs off the main actor. Write outputs with `context.output(...)`.
    func start(
        title: String,
        publishesFiles: Bool = true,
        inputs: [URL] = [],
        inBackground: Bool = false,
        work: @escaping @Sendable (JobContext) async throws -> Void
    ) {
        guard !isRunning else { return }
        var destination: OutputDestination?
        if publishesFiles {
            guard let resolved = OutputManager.resolveDestination(jobTitle: title, inputs: inputs) else { return }
            destination = resolved
        }

        phase = .running
        runsInBackground = inBackground
        progress = 0
        status = "Starting…"
        outputs = []
        outputFolder = nil
        startedAt = Date()

        task = Task { [weak self] in
            var staging: URL?
            do {
                let context = try JobContext(destination: destination, inputs: inputs, runner: self)
                staging = context.stagingRoot
                let inner = Task.detached(priority: .userInitiated) { try await work(context) }
                try await withTaskCancellationHandler {
                    try await inner.value
                } onCancel: {
                    inner.cancel()
                }
                try Task.checkCancellation()

                if let staging {
                    let published = try OutputManager.publish(context.stagedResults)
                    guard !published.isEmpty else { throw ToolError.failed("Nothing was produced.") }
                    OutputManager.discard(staging: staging)
                    self?.finishSuccess(outputs: published)
                } else {
                    self?.finishSuccess(outputs: [])
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

    /// Runs a tool's `job` on `inputs`.
    func start(_ job: ToolJob, title: String, inputs: [URL], inBackground: Bool = false) {
        switch job {
        case .each(let verb, let body):
            start(title: title, inputs: inputs, inBackground: inBackground) { context in
                try await context.forEach(inputs, verb: verb) { input, progress in
                    try await body(input, context, progress)
                }
            }
        case .all(let body):
            start(title: title, inputs: inputs, inBackground: inBackground) { context in
                try await body(inputs, context)
            }
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

    private func finishSuccess(outputs published: [URL]) {
        outputs = published.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        outputFolder = outputs.first?.deletingLastPathComponent()
        progress = 1
        phase = .succeeded
        status = "Done"
        if !outputs.isEmpty, AppSettings.revealWhenDone || runsInBackground {
            NSWorkspace.shared.activateFileViewerSelecting(outputs)
        }
        if !NSApp.isActive, !runsInBackground { NSApp.requestUserAttention(.informationalRequest) }
    }

    fileprivate func update(progress: Double? = nil, status: String? = nil) {
        guard isRunning else { return }
        if let progress { self.progress = min(max(progress, 0), 1) }
        if let status { self.status = status }
    }
}

/// What a tool does with its input files, built from its settings when the job starts. Shared by the
/// tool's page and its launcher quick action.
enum ToolJob {
    /// Processes each file on its own. `verb` labels progress, e.g. "Compressing 2 of 5: clip.mov".
    case each(verb: String, @Sendable (_ input: URL, _ context: JobContext, _ progress: @escaping @Sendable (Double) -> Void) async throws -> Void)
    /// Receives every file at once, in order.
    case all(@Sendable (_ inputs: [URL], _ context: JobContext) async throws -> Void)
}

/// Handed to a job's work closure. Thread-safe; call from any context.
///
/// Outputs are written to staging folders, one per destination folder, and published together when the job
/// succeeds. Their names are already unique in the destination, so they normally keep them when published.
final class JobContext: @unchecked Sendable {
    /// Staging folder for results not made from a particular file. Write here directly only when a tool
    /// (like yt-dlp) picks its own file names. Nil for jobs that don't publish files.
    let stagingFolder: URL?
    /// Holds every staging folder. Nil for jobs that don't publish files.
    let stagingRoot: URL?
    private let destination: OutputDestination?
    /// Where results not made from a particular file go: next to the first input when results go next to originals.
    private let defaultFolder: URL?
    private weak var runner: JobRunner?
    private let lock = NSLock()
    /// Staging folder for each destination folder.
    private var staging: [URL: URL] = [:]
    /// Lowercased names handed out so far, per destination folder.
    private var usedNames: [URL: Set<String>] = [:]

    init(destination: OutputDestination?, inputs: [URL], runner: JobRunner?) throws {
        self.destination = destination
        self.runner = runner
        if let destination {
            let folder = destination.folder(for: inputs.first)
            let root = try OutputManager.makeStagingFolder(near: folder)
            let first = root.appendingPathComponent("1", isDirectory: true)
            try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
            defaultFolder = folder
            stagingRoot = root
            stagingFolder = first
            staging[folder] = first
        } else {
            defaultFolder = nil
            stagingRoot = nil
            stagingFolder = nil
        }
    }

    /// Each staging folder with the folder its contents are published to.
    var stagedResults: [(staging: URL, destination: URL)] {
        lock.lock(); defer { lock.unlock() }
        return staging.map { (staging: $0.value, destination: $0.key) }
    }

    /// A unique output URL derived from an input file, e.g. `clip.mov` → `clip-compressed.mp4`.
    /// It's published next to the input when results go next to originals.
    /// - Parameters:
    ///   - suffix: Appended to the base name with a hyphen. Nil keeps the original name.
    ///   - ext: New file extension. Nil keeps the input's extension.
    func output(for input: URL, suffix: String? = nil, extension ext: String? = nil) -> URL {
        let base = input.deletingPathExtension().lastPathComponent
        let name = suffix.map { "\(base)-\($0)" } ?? base
        return output(named: name, extension: ext ?? input.pathExtension, nextTo: input)
    }

    /// A unique output URL with an explicit name, e.g. `output(named: "Merged", extension: "pdf")`.
    /// - Parameter source: The file the result is made from. When results go next to originals, it's
    ///   published in that file's folder. Nil means the folder of the job's first input.
    func output(named name: String, extension ext: String, nextTo source: URL? = nil) -> URL {
        guard let destination, let stagingRoot, let defaultFolder else { preconditionFailure("This job doesn't publish files.") }
        let folder = source.map { destination.folder(for: $0) } ?? defaultFolder
        let fm = FileManager.default
        lock.lock(); defer { lock.unlock() }
        let stagingFolder = staging[folder] ?? {
            let url = stagingRoot.appendingPathComponent("\(staging.count + 1)", isDirectory: true)
            // A failure here surfaces when the tool writes its output.
            try? fm.createDirectory(at: url, withIntermediateDirectories: true)
            staging[folder] = url
            return url
        }()
        let used = usedNames[folder] ?? []
        let candidate = OutputManager.uniqueName(OutputManager.sanitize(name), extension: ext) {
            used.contains($0.lowercased()) || fm.fileExists(atPath: folder.appendingPathComponent($0).path)
        }
        usedNames[folder, default: []].insert(candidate.lowercased())
        return stagingFolder.appendingPathComponent(candidate)
    }

    /// A unique subfolder inside the results, e.g. for "PDF to Images" with many pages per input.
    /// - Parameter source: As for `output(named:extension:nextTo:)`.
    func outputFolder(named name: String, nextTo source: URL? = nil) throws -> URL {
        let url = output(named: name, extension: "", nextTo: source)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A scratch folder for intermediate files. Not published; deleted with the staging folders.
    func makeScratchFolder() throws -> URL {
        let parent = stagingRoot?.deletingLastPathComponent() ?? FileManager.default.temporaryDirectory
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
