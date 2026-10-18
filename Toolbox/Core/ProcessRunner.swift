import Foundation

struct ProcessResult {
    let status: Int32
    let stdout: String
    let stderr: String
}

/// Runs command-line programs asynchronously, streaming output line by line.
/// Cancelling the calling task terminates the process.
enum ProcessRunner {
    /// PATH used for child processes. GUI apps launch with a minimal PATH, which hides Homebrew.
    static let searchPath = [
        "/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin", "/opt/local/bin",
        "/usr/bin", "/bin", "/usr/sbin", "/sbin",
    ]

    static var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        let existing = env["PATH"]?.split(separator: ":").map(String.init) ?? []
        var path = searchPath
        for entry in existing where !path.contains(entry) { path.append(entry) }
        env["PATH"] = path.joined(separator: ":")
        env["HOMEBREW_NO_ENV_HINTS"] = "1"
        env["HOMEBREW_NO_INSTALL_CLEANUP"] = "1"
        return env
    }

    @discardableResult
    static func run(
        _ executable: URL,
        arguments: [String],
        currentDirectory: URL? = nil,
        onStdoutLine: (@Sendable (String) -> Void)? = nil,
        onStderrLine: (@Sendable (String) -> Void)? = nil
    ) async throws -> ProcessResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }
        process.standardInput = FileHandle.nullDevice

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let stdoutCollector = LineCollector(onLine: onStdoutLine)
        let stderrCollector = LineCollector(onLine: onStderrLine)

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            stdoutCollector.append(handle.availableData)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            stderrCollector.append(handle.availableData)
        }

        try Task.checkCancellation()

        let status: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int32, Error>) in
                process.terminationHandler = { process in
                    continuation.resume(returning: process.terminationStatus)
                }
                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }

        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        stdoutCollector.append(stdoutPipe.fileHandleForReading.readDataToEndOfFile())
        stderrCollector.append(stderrPipe.fileHandleForReading.readDataToEndOfFile())
        stdoutCollector.finish()
        stderrCollector.finish()

        if Task.isCancelled { throw CancellationError() }
        return ProcessResult(status: status, stdout: stdoutCollector.text, stderr: stderrCollector.text)
    }

    /// Runs a program and throws `ToolError.processFailed` on a non-zero exit status.
    @discardableResult
    static func runChecked(
        _ executable: URL,
        arguments: [String],
        currentDirectory: URL? = nil,
        onStdoutLine: (@Sendable (String) -> Void)? = nil,
        onStderrLine: (@Sendable (String) -> Void)? = nil
    ) async throws -> ProcessResult {
        let result = try await run(executable, arguments: arguments, currentDirectory: currentDirectory,
                                   onStdoutLine: onStdoutLine, onStderrLine: onStderrLine)
        guard result.status == 0 else {
            throw ToolError.processFailed(program: executable.lastPathComponent, status: result.status,
                                          message: lastMeaningfulLines(of: result.stderr.isEmpty ? result.stdout : result.stderr))
        }
        return result
    }

    static func lastMeaningfulLines(of text: String, count: Int = 3) -> String {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .suffix(count)
            .joined(separator: "\n")
    }
}

/// Thread-safe accumulator that splits incoming bytes into lines.
private final class LineCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var all = Data()
    private let onLine: (@Sendable (String) -> Void)?

    init(onLine: (@Sendable (String) -> Void)?) {
        self.onLine = onLine
    }

    func append(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        all.append(data)
        var lines: [String] = []
        if onLine != nil {
            buffer.append(data)
            while let index = buffer.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
                let lineData = buffer[buffer.startIndex..<index]
                buffer.removeSubrange(buffer.startIndex...index)
                if let line = String(data: lineData, encoding: .utf8), !line.isEmpty { lines.append(line) }
            }
        }
        lock.unlock()
        lines.forEach { onLine?($0) }
    }

    func finish() {
        lock.lock()
        let rest = buffer
        buffer.removeAll()
        lock.unlock()
        if let line = String(data: rest, encoding: .utf8), !line.isEmpty { onLine?(line) }
    }

    var text: String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: all, as: UTF8.self)
    }
}
