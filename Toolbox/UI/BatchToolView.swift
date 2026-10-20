import SwiftUI
import UniformTypeIdentifiers

/// The common "pick files → set options → run" tool layout.
///
/// Per-file tools (convert, compress, resize…) use `init(… each:)`, which processes inputs one by one.
/// Combining tools (merge, images to PDF…) use `init(… all:)`, which receives every input at once.
/// Tools with a launcher quick action pass `job:` instead, built from their saved `ToolSettings`, so the
/// page and the launcher run the same job.
///
/// Options live in the calling view as `@State`, or in a `ToolSettings` view for tools with a quick action.
/// The work closure captures their current values when the user presses the action button. The closure
/// runs off the main actor.
struct BatchToolView<Options: View>: View {
    let tool: Tool
    let accepts: [UTType]
    var allowsMultiple: Bool
    var reorderable: Bool
    var minimumFiles: Int
    var actionTitle: String
    var noun: String
    var canRun: Bool
    var options: Options
    /// Built when the action button is pressed, so it reads the latest settings. Nil disables the button.
    let makeJob: () -> ToolJob?

    @State private var runner: JobRunner
    /// Bumped when saved settings change, so the button re-checks `makeJob`.
    @State private var settingsRevision = 0

    /// Processes each input separately.
    init(
        tool: Tool,
        accepts: [UTType],
        allowsMultiple: Bool = true,
        actionTitle: String,
        verb: String = "Processing",
        noun: String = "files",
        canRun: Bool = true,
        @ViewBuilder options: () -> Options,
        each: @escaping @Sendable (_ input: URL, _ context: JobContext, _ progress: @escaping @Sendable (Double) -> Void) async throws -> Void
    ) {
        self.tool = tool
        self.accepts = accepts
        self.allowsMultiple = allowsMultiple
        self.reorderable = false
        self.minimumFiles = 1
        self.actionTitle = actionTitle
        self.noun = noun
        self.canRun = canRun
        self.options = options()
        self.makeJob = { .each(verb: verb, each) }
        _runner = State(initialValue: JobCenter.shared.runner(for: tool.id))
    }

    /// Receives all inputs at once (in the user's order when `reorderable`).
    init(
        tool: Tool,
        accepts: [UTType],
        reorderable: Bool = true,
        minimumFiles: Int = 2,
        actionTitle: String,
        noun: String = "files",
        canRun: Bool = true,
        @ViewBuilder options: () -> Options,
        all: @escaping @Sendable (_ inputs: [URL], _ context: JobContext) async throws -> Void
    ) {
        self.tool = tool
        self.accepts = accepts
        self.allowsMultiple = true
        self.reorderable = reorderable
        self.minimumFiles = minimumFiles
        self.actionTitle = actionTitle
        self.noun = noun
        self.canRun = canRun
        self.options = options()
        self.makeJob = { .all(all) }
        _runner = State(initialValue: JobCenter.shared.runner(for: tool.id))
    }

    /// Runs the job `makeJob` builds from the tool's saved settings, typically `{ Settings().job(for: tool) }`,
    /// the same job its launcher quick action runs.
    init(
        tool: Tool,
        accepts: [UTType],
        reorderable: Bool = false,
        minimumFiles: Int = 1,
        actionTitle: String,
        noun: String = "files",
        job makeJob: @escaping () -> ToolJob?,
        @ViewBuilder options: () -> Options
    ) {
        self.tool = tool
        self.accepts = accepts
        self.allowsMultiple = true
        self.reorderable = reorderable
        self.minimumFiles = minimumFiles
        self.actionTitle = actionTitle
        self.noun = noun
        self.canRun = true
        self.options = options()
        self.makeJob = makeJob
        _runner = State(initialValue: JobCenter.shared.runner(for: tool.id))
    }

    private var hasEnoughFiles: Bool { runner.inputs.count >= minimumFiles }

    /// Whether the saved settings make a runnable job. Reads `settingsRevision` to refresh when they change.
    private var settingsReady: Bool {
        _ = settingsRevision
        return makeJob() != nil
    }

    var body: some View {
        ToolPage(tool: tool, runner: runner) {
            FileListInput(files: $runner.inputs, accepts: accepts, allowsMultiple: allowsMultiple,
                          reorderable: reorderable, noun: noun)
                .disabled(runner.isRunning)
            if Options.self != EmptyView.self {
                ToolSection("Options") { options }
                    .disabled(runner.isRunning)
            }
        } footer: {
            JobBar(runner: runner, actionTitle: actionTitle, canRun: hasEnoughFiles && canRun && settingsReady,
                   hint: hasEnoughFiles ? nil : (minimumFiles > 1 ? "Add at least \(minimumFiles) \(noun)." : "Add \(noun) to get started."),
                   action: start)
        }
        .onChange(of: runner.inputs) { if !runner.isRunning { runner.reset() } }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            settingsRevision += 1
        }
    }

    private func start() {
        guard let job = makeJob() else { return }
        runner.start(job, title: tool.name, inputs: runner.inputs)
    }
}

extension BatchToolView where Options == EmptyView {
    init(
        tool: Tool, accepts: [UTType], allowsMultiple: Bool = true, actionTitle: String,
        verb: String = "Processing", noun: String = "files", canRun: Bool = true,
        each: @escaping @Sendable (_ input: URL, _ context: JobContext, _ progress: @escaping @Sendable (Double) -> Void) async throws -> Void
    ) {
        self.init(tool: tool, accepts: accepts, allowsMultiple: allowsMultiple, actionTitle: actionTitle,
                  verb: verb, noun: noun, canRun: canRun, options: { EmptyView() }, each: each)
    }

    init(
        tool: Tool, accepts: [UTType], reorderable: Bool = true, minimumFiles: Int = 2, actionTitle: String,
        noun: String = "files", canRun: Bool = true,
        all: @escaping @Sendable (_ inputs: [URL], _ context: JobContext) async throws -> Void
    ) {
        self.init(tool: tool, accepts: accepts, reorderable: reorderable, minimumFiles: minimumFiles,
                  actionTitle: actionTitle, noun: noun, canRun: canRun, options: { EmptyView() }, all: all)
    }
}

/// Temporary view for tools that aren't implemented yet.
struct PlaceholderToolView: View {
    let tool: Tool

    var body: some View {
        ToolPage(tool: tool) {
            ContentUnavailableView("Coming soon", systemImage: "hammer",
                                   description: Text("\(tool.name) is being built."))
                .frame(maxWidth: .infinity, minHeight: 240)
        }
    }
}
