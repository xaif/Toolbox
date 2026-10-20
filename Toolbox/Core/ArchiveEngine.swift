import Foundation

enum ArchiveEngine {
    static let tar = URL(fileURLWithPath: "/usr/bin/tar")

    /// Extract only ordinary files and folders. Reject links and paths outside the destination.
    static func extract(_ input: URL, to folder: URL) async throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let listing = try await ProcessRunner.run(tar, arguments: ["-tf", input.path])
        if listing.status != 0, input.pathExtension.lowercased() == "gz", !input.lastPathComponent.lowercased().hasSuffix(".tar.gz") {
            let copy = folder.appendingPathComponent(input.lastPathComponent)
            try FileManager.default.copyItem(at: input, to: copy)
            try await ProcessRunner.runChecked(URL(fileURLWithPath: "/usr/bin/gzip"), arguments: ["-d", copy.path])
            return
        }
        guard listing.status == 0 else { throw ToolError.failed("Couldn't read this archive. It may be encrypted or damaged.\n\(listing.stderr)") }
        let entries = listing.stdout.split(whereSeparator: \.isNewline).map(String.init)
        guard !entries.isEmpty, entries.count <= 100_000 else { throw ToolError.failed("The archive is empty or contains too many entries.") }
        for entry in entries { try validatePath(entry) }
        let details = try await ProcessRunner.runChecked(tar, arguments: ["-tvf", input.path])
        guard details.stdout.split(whereSeparator: \.isNewline).allSatisfy({ $0.first == "-" || $0.first == "d" }) else {
            throw ToolError.failed("This archive contains links or special files. Extract it with a dedicated archive utility.")
        }
        try await ProcessRunner.runChecked(tar, arguments: ["-xf", input.path, "-C", folder.path, "--no-same-owner", "--no-same-permissions"])
        try Task.checkCancellation()
    }

    static func validatePath(_ entry: String) throws {
        let parts = entry.replacingOccurrences(of: "\\", with: "/").split(separator: "/")
        guard !entry.hasPrefix("/"), !entry.hasPrefix("\\"), !parts.contains(".."),
              !entry.contains(":"), !entry.contains("\0") else {
            throw ToolError.failed("The archive contains an unsafe file path.")
        }
    }

    static func create(from files: [URL], format: String, to output: URL, scratch: URL) async throws {
        guard !files.isEmpty else { throw ToolError.failed("Add files or folders to archive.") }
        let contents = scratch.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        for input in files {
            try Task.checkCancellation()
            let name = OutputManager.uniqueName(input.deletingPathExtension().lastPathComponent, extension: input.pathExtension) {
                FileManager.default.fileExists(atPath: contents.appendingPathComponent($0).path)
            }
            try FileManager.default.copyItem(at: input, to: contents.appendingPathComponent(name))
        }
        try await packDirectory(contents, format: format, to: output)
    }

    static func packDirectory(_ folder: URL, format: String, to output: URL) async throws {
        let flags = format == "gz" ? "-czf" : "-caf"
        try await ProcessRunner.runChecked(tar, arguments: [flags, output.path, "-C", folder.path, "."])
    }

    static func convert(_ input: URL, target: String, context: JobContext) async throws {
        let scratch = try context.makeScratchFolder()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let contents = scratch.appendingPathComponent("contents", isDirectory: true)
        try await extract(input, to: contents)
        let base = input.lastPathComponent.replacingOccurrences(of: "(?i)(\\.tar\\.gz|\\.tgz|\\.[^.]+)$", with: "", options: .regularExpression)
        let output = context.output(named: base, extension: target == "gz" ? "tar.gz" : target, nextTo: input)
        try await packDirectory(contents, format: target, to: output)
    }

    static func zipPackage(_ folder: URL, to output: URL, epub: Bool = false) async throws {
        let zip = URL(fileURLWithPath: "/usr/bin/zip")
        if epub {
            try await ProcessRunner.runChecked(zip, arguments: ["-X0", output.path, "mimetype"], currentDirectory: folder)
            try await ProcessRunner.runChecked(zip, arguments: ["-Xr9", output.path, "META-INF", "OEBPS"], currentDirectory: folder)
        } else {
            try await ProcessRunner.runChecked(zip, arguments: ["-Xqr", output.path, "."], currentDirectory: folder)
        }
    }
}
