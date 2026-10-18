import SwiftUI
import UniformTypeIdentifiers

/// The common "pick files → set options → run" tool layout.
///
/// Per-file tools (convert, compress, resize…) use `init(… each:)`, which processes inputs one by one.
/// Combining tools (merge, images to PDF…) use `init(… all:)`, which receives every input at once.
///
/// Options live in the calling view as `@State`; the work closure captures their current values
/// when the user presses the action button. The closure runs off the main actor.
struct BatchToolView<Options: View>: View {
    enum Work {
        case each(@Sendable (_ input: URL, _ context: JobContext, _ progress: @escaping @Sendable (Double) -> Void) async throws -> Void)
        case all(@Sendable (_ inputs: [URL], _ context: JobContext) async throws -> Void)
    }

    let tool: Tool
    let accepts: [UTType]
    var allowsMultiple: Bool
    var reorderable: Bool
    var minimumFiles: Int
    var actionTitle: String
    var verb: String
    var noun: String
    var canRun: Bool
    var options: Options
    let work: Work

    @State private var runner: JobRunner

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
        self.verb = verb
        self.noun = noun
        self.canRun = canRun
        self.options = options()
        self.work = .each(each)
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
        self.verb = "Processing"
        self.noun = noun
        self.canRun = canRun
        self.options = options()
        self.work = .all(all)
        _runner = State(initialValue: JobCenter.shared.runner(for: tool.id))
    }

    private var hasEnoughFiles: Bool { runner.inputs.count >= minimumFiles }

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
            JobBar(runner: runner, actionTitle: actionTitle, canRun: hasEnoughFiles && canRun,
                   hint: hasEnoughFiles ? nil : (minimumFiles > 1 ? "Add at least \(minimumFiles) \(noun)." : "Add \(noun) to get started."),
                   action: start)
        }
        .onChange(of: runner.inputs) { if !runner.isRunning { runner.reset() } }
    }

    private func start() {
        let inputs = runner.inputs
        let verb = verb
        switch work {
        case .each(let body):
            runner.start(title: tool.name) { context in
                try await context.forEach(inputs, verb: verb) { input, progress in
                    try await body(input, context, progress)
                }
            }
        case .all(let body):
            runner.start(title: tool.name) { context in
                try await body(inputs, context)
            }
        }
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
