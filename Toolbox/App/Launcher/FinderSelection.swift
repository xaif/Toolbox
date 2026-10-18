import Foundation

/// Reads the files currently selected in Finder. macOS asks the user once for permission
/// ("Toolbox wants to control Finder"); if they decline, this simply returns nothing.
enum FinderSelection {
    private static let script = """
    tell application "Finder"
        set output to ""
        repeat with anItem in (get selection)
            set output to output & POSIX path of (anItem as alias) & linefeed
        end repeat
        return output
    end tell
    """

    static func fetch(limit: Int = 1000) async -> [URL] {
        let osascript = URL(fileURLWithPath: "/usr/bin/osascript")
        guard let result = try? await ProcessRunner.run(osascript, arguments: ["-e", script]), result.status == 0 else {
            return []
        }
        return result.stdout
            .split(whereSeparator: \.isNewline)
            .prefix(limit)
            .map { URL(fileURLWithPath: String($0)) }
    }
}
