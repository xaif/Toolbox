import AppKit

/// Runs tools' quick actions without opening the window, for the launcher and tool hotkeys.
/// Progress shows in `JobHUD`, and the results are selected in Finder when the job is done.
@MainActor
enum QuickRun {
    /// Runs `tool` on `files` in the background when `run` is true and it can, otherwise opens the
    /// tool with the files.
    static func perform(_ tool: Tool, on files: [URL], run: Bool) {
        if run, AppSettings.launcherRunsTools, start(tool, on: files) { return }
        AppModel.shared.openTool(tool, with: files)
    }

    /// Whether `tool` could run unattended: it has a quick action, isn't busy and its dependencies
    /// (like FFmpeg) are installed. Its settings may still be incomplete.
    static func isAvailable(_ tool: Tool) -> Bool {
        tool.quickAction != nil && !JobCenter.shared.runner(for: tool.id).isRunning
            && tool.requirements.allSatisfy { Dependencies.shared.isAvailable($0) }
    }

    /// Whether `tool` can run unattended right now: it's available and its settings are complete.
    static func isReady(_ tool: Tool) -> Bool { job(for: tool) != nil }

    /// Starts `tool`'s quick action on the files it accepts, in name order (the page order for Merge and
    /// Images to PDF). Returns false when it can't run unattended or too few files fit, so the caller can
    /// open the tool instead.
    @discardableResult
    static func start(_ tool: Tool, on files: [URL]) -> Bool {
        guard let accepted = tool.input?.accepted(from: files), accepted.count >= (tool.quickAction?.minimumFiles ?? 1),
              let job = job(for: tool) else { return false }
        let inputs = accepted.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        let runner = JobCenter.shared.runner(for: tool.id)
        runner.inputs = inputs
        AppSettings.noteToolOpened(tool.id)
        // "Ask every time" shows a folder picker, which needs the app in front.
        if AppSettings.outputMode == .ask { NSApp.activate() }
        runner.start(job, title: tool.name, inputs: inputs, inBackground: true)
        // Not running means the folder picker was cancelled; there's nothing to report.
        if runner.isRunning { JobHUD.shared.show(tool, runner: runner) }
        return true
    }

    private static func job(for tool: Tool) -> ToolJob? {
        guard isAvailable(tool) else { return nil }
        return tool.quickAction?.makeJob(tool)
    }
}
