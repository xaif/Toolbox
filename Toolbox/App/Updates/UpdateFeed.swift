import Foundation

/// A version like 0.2.0, compared number by number, so 0.10.0 is newer than 0.9.3 and 1.0 equals 1.0.0.
struct AppVersion: Comparable, Hashable, CustomStringConvertible, Sendable {
    let components: [Int]

    /// Accepts "0.2.0", "v0.2.0" and "0.2.0-beta" (the suffix is ignored).
    init?(_ string: String) {
        var text = Substring(string.trimmingCharacters(in: .whitespaces))
        if text.first == "v" || text.first == "V" { text = text.dropFirst() }
        let core = text.split(separator: "-", maxSplits: 1).first ?? text
        let parts = core.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !parts.isEmpty, parts.allSatisfy({ $0 != nil && $0! >= 0 }) else { return nil }
        components = parts.compactMap { $0 }
    }

    /// This copy of Toolbox.
    static let current = AppVersion(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") ?? AppVersion("0")!

    var description: String { components.map(String.init).joined(separator: ".") }

    /// Without trailing zeros, so equal versions compare and hash the same.
    private var trimmed: [Int] {
        var parts = components
        while parts.count > 1, parts.last == 0 { parts.removeLast() }
        return parts
    }

    static func == (lhs: AppVersion, rhs: AppVersion) -> Bool { lhs.trimmed == rhs.trimmed }
    func hash(into hasher: inout Hasher) { hasher.combine(trimmed) }

    static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0..<count {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }
        return false
    }
}

/// A release on GitHub, as the REST API describes it.
struct GitHubRelease: Decodable, Sendable {
    struct Asset: Decodable, Sendable {
        let name: String
        let size: Int64
        let browserDownloadURL: URL
        /// "sha256:<hex>". GitHub computes it when the file is uploaded.
        let digest: String?

        enum CodingKeys: String, CodingKey {
            case name, size, digest
            case browserDownloadURL = "browser_download_url"
        }
    }

    let tagName: String
    let name: String?
    let body: String?
    let draft: Bool
    let prerelease: Bool
    let publishedAt: Date?
    let htmlURL: URL
    let assets: [Asset]

    enum CodingKeys: String, CodingKey {
        case name, body, draft, prerelease, assets
        case tagName = "tag_name"
        case publishedAt = "published_at"
        case htmlURL = "html_url"
    }

    var version: AppVersion? { AppVersion(tagName) }
    var dmg: Asset? { assets.first { $0.name.lowercased().hasSuffix(".dmg") } }
}

/// One version's changes, as shown in the update window.
struct ReleaseNotes: Identifiable, Equatable, Sendable {
    let version: AppVersion
    let date: Date?
    /// Markdown from the changelog.
    let markdown: String

    var id: String { version.description }
}

/// The newest release above this copy of Toolbox, with everything that changed since.
struct AppUpdate: Equatable, Sendable {
    let version: AppVersion
    let date: Date?
    let pageURL: URL
    let downloadURL: URL
    let downloadSize: Int64
    /// "sha256:<hex>", when GitHub reports one.
    let digest: String?
    /// Every version newer than the installed one, newest first.
    let notes: [ReleaseNotes]
}

/// Reads Toolbox's releases on GitHub. A release's notes are its section of CHANGELOG.md, followed by
/// install help for people downloading it from the website, which the app leaves out.
enum UpdateFeed {
    static let defaultURL = URL(string: "https://api.github.com/repos/xaif/Toolbox/releases?per_page=30")!
    /// Separates the changelog from the install help in release notes; see .github/workflows/release.yml.
    static let installMarker = "<!-- install -->"

    struct FeedError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// In debug builds, `updates.feedURL` points the app at another feed, e.g. a local file while testing.
    static var url: URL {
        #if DEBUG
        if let custom = UserDefaults.standard.string(forKey: "updates.feedURL").flatMap(URL.init(string:)) { return custom }
        #endif
        return defaultURL
    }

    static func fetch(from url: URL = url) async throws -> [GitHubRelease] {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Toolbox/\(AppVersion.current)", forHTTPHeaderField: "User-Agent")
        let data: Data, response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch let error as URLError where error.code == .notConnectedToInternet || error.code == .networkConnectionLost {
            throw FeedError(message: "You're offline. Connect to the internet and try again.")
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            switch http.statusCode {
            case 403, 429: throw FeedError(message: "GitHub is limiting update checks from your network right now. Try again in a little while.")
            case 404: throw FeedError(message: "Couldn't find Toolbox's releases on GitHub.")
            default: throw FeedError(message: "Checking for updates failed (HTTP \(http.statusCode)).")
            }
        }
        return try decode(data)
    }

    static func decode(_ data: Data) throws -> [GitHubRelease] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode([GitHubRelease].self, from: data)
        } catch {
            throw FeedError(message: "GitHub sent a list of releases Toolbox couldn't read.")
        }
    }

    /// The newest published, non-prerelease version above `current` that has a DMG to install.
    static func update(from releases: [GitHubRelease], current: AppVersion) -> AppUpdate? {
        let newer = published(releases).filter { $0.version > current }
        guard let latest = newer.first(where: { $0.release.dmg != nil }), let dmg = latest.release.dmg else { return nil }
        let notes = newer.filter { $0.version <= latest.version }.map { notesFor($0.release, version: $0.version) }
        return AppUpdate(version: latest.version, date: latest.release.publishedAt, pageURL: latest.release.htmlURL,
                         downloadURL: dmg.browserDownloadURL, downloadSize: dmg.size, digest: dmg.digest, notes: notes)
    }

    /// The notes for `version` itself, to show what's new in the installed version.
    static func notes(for version: AppVersion, in releases: [GitHubRelease]) -> ReleaseNotes? {
        published(releases).first { $0.version == version }.map { notesFor($0.release, version: $0.version) }
    }

    /// The changelog part of a release's notes.
    static func changelog(fromBody body: String) -> String {
        let changes = body.range(of: installMarker).map { String(body[..<$0.lowerBound]) } ?? body
        return changes.replacingOccurrences(of: "\r\n", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Published releases with a version, newest first.
    private static func published(_ releases: [GitHubRelease]) -> [(release: GitHubRelease, version: AppVersion)] {
        releases
            .filter { !$0.draft && !$0.prerelease }
            .compactMap { release in release.version.map { (release, $0) } }
            .sorted { $0.version > $1.version }
    }

    private static func notesFor(_ release: GitHubRelease, version: AppVersion) -> ReleaseNotes {
        ReleaseNotes(version: version, date: release.publishedAt, markdown: changelog(fromBody: release.body ?? ""))
    }
}

/// Changelog Markdown split into what the update window shows: headings, bullet points and paragraphs.
/// Bold, italics, code and links inside them are kept.
enum ReleaseNotesBlock: Equatable {
    case heading(String)
    case bullet(String)
    case paragraph(String)

    static func blocks(_ markdown: String) -> [ReleaseNotesBlock] {
        var blocks: [ReleaseNotesBlock] = []
        var paragraph: [String] = []
        func endParagraph() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: " "))) }
            paragraph = []
        }
        for raw in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line == "---" || line == "***" {
                endParagraph()
            } else if line.hasPrefix("#") {
                endParagraph()
                let title = line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
                if !title.isEmpty { blocks.append(.heading(title)) }
            } else if let marker = ["- ", "* ", "+ ", "• "].first(where: line.hasPrefix) {
                endParagraph()
                blocks.append(.bullet(String(line.dropFirst(marker.count))))
            } else if case .bullet(let text) = blocks.last, paragraph.isEmpty, raw.hasPrefix("  ") {
                // An indented line continues the bullet above.
                blocks[blocks.count - 1] = .bullet(text + " " + line)
            } else {
                paragraph.append(line)
            }
        }
        endParagraph()
        return blocks
    }

    /// Inline Markdown as styled text; plain text if it doesn't parse.
    static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}
