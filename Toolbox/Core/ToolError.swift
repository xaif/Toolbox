import Foundation

/// Errors surfaced to the user. Keep messages short and actionable.
enum ToolError: LocalizedError {
    case missingDependency(ExternalDependency)
    case processFailed(program: String, status: Int32, message: String)
    case unreadableInput(URL)
    case unsupported(String)
    case failed(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .missingDependency(let dependency):
            "\(dependency.displayName) isn't installed. Install it from Settings › Dependencies."
        case .processFailed(let program, let status, let message):
            message.isEmpty ? "\(program) failed (exit code \(status))." : "\(program) failed: \(message)"
        case .unreadableInput(let url):
            "Couldn't read “\(url.lastPathComponent)”."
        case .unsupported(let message):
            message
        case .failed(let message):
            message
        case .cancelled:
            "Cancelled."
        }
    }
}
