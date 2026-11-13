import Foundation

/// Turns web pages into Markdown with markdown.new, a free service run on Cloudflare: it loads the page
/// (in a headless browser when asked) and returns clean Markdown. Only the page's link is sent, so it
/// works for public pages, up to 500 a day per IP address.
enum WebsiteMarkdown {
    struct Options: Sendable, Equatable {
        /// Keep the page's pictures as Markdown image links. The service drops them by default.
        var keepsImages = false
        /// Render the page in a browser first, for pages that load their content with JavaScript.
        var rendersInBrowser = false
        /// Note the page's title and link at the top of the file.
        var addsSource = true
    }

    struct Page: Sendable, Equatable {
        let link: URL
        /// Nil when the service found no title.
        let title: String?
        let markdown: String
    }

    static let endpoint = URL(string: "https://markdown.new/")!
    /// The title the service gives pages without one.
    private static let placeholderTitle = "Converted Content"

    // MARK: Links

    /// The web links in `text`, one per word or line, in order and without repeats. A link without a
    /// scheme, like `example.com/page`, gets `https://`.
    static func links(in text: String) -> [URL] {
        var seen = Set<String>()
        return text.components(separatedBy: .whitespacesAndNewlines).compactMap { word in
            let trimmed = word.trimmingCharacters(in: CharacterSet(charactersIn: "<>\"'"))
            guard !trimmed.isEmpty else { return nil }
            let candidate = trimmed.contains("://") ? trimmed : "https://" + trimmed
            guard let url = URL(string: candidate), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
                  url.user == nil, let host = url.host(),
                  // A real domain: "example.com", not "hello" or "e.g.".
                  let last = host.split(separator: ".", omittingEmptySubsequences: false).last, last.count >= 2,
                  host.contains("."), !host.hasPrefix("."),
                  seen.insert(url.absoluteString).inserted else { return nil }
            return url
        }
    }

    // MARK: The service

    static func request(for link: URL, options: Options) -> URLRequest {
        var request = URLRequest(url: endpoint, timeoutInterval: 90)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let body: [String: Any] = [
            "url": link.absoluteString,
            "method": options.rendersInBrowser ? "browser" : "auto",
            "retain_images": options.keepsImages,
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return request
    }

    /// Fetches `link` as Markdown.
    static func convert(_ link: URL, options: Options, session: URLSession = .shared) async throws -> Page {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request(for: link, options: options))
        } catch let error as URLError {
            switch error.code {
            case .cancelled: throw CancellationError()
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
                throw ToolError.failed("You're offline. Website to Markdown needs an internet connection.")
            case .timedOut:
                throw ToolError.failed("markdown.new took too long to answer. Try again in a moment.")
            default:
                throw ToolError.failed("Couldn't reach markdown.new: \(error.localizedDescription)")
            }
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 200
        return try page(from: data, status: status, link: link, options: options)
    }

    private struct Reply: Decodable {
        var success: Bool?
        var title: String?
        var content: String?
        var error: String?
    }

    /// Reads the service's JSON reply: `{"success": true, "title": …, "content": …}` or
    /// `{"success": false, "error": …}`.
    static func page(from data: Data, status: Int, link: URL, options: Options) throws -> Page {
        if status == 429 {
            throw ToolError.failed("markdown.new allows 500 pages a day from one network, and today's are used up. Try again tomorrow.")
        }
        guard let reply = try? JSONDecoder().decode(Reply.self, from: data) else {
            throw ToolError.failed("markdown.new couldn't convert this page (HTTP \(status)).")
        }
        let browserHint = options.rendersInBrowser ? "" : " If it loads its content with JavaScript, turn on “Render the page in a browser first”."
        guard (200..<300).contains(status), reply.success != false, let content = reply.content else {
            var message = (reply.error ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if let range = message.range(of: "Error from The API: "), range.lowerBound == message.startIndex {
                message.removeSubrange(range)
            }
            if message.isEmpty { message = "markdown.new couldn't convert this page (HTTP \(status))." }
            if message.contains("All conversion methods failed") {
                message = "The page is empty or couldn't be reached. Check the link; pages behind a login don't work."
            }
            throw ToolError.failed(message)
        }
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ToolError.failed("The page came back empty." + browserHint)
        }
        let title = reply.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return Page(link: link, title: title.isEmpty || title == placeholderTitle ? nil : title, markdown: content)
    }

    // MARK: The file

    /// The file's contents: the page's Markdown, with its title and link in front matter at the top
    /// when `addsSource` is on. Front matter the service already wrote gains a `source` line.
    static func document(for page: Page, options: Options) -> String {
        let body = page.markdown.replacingOccurrences(of: "\r\n", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard options.addsSource else { return body + "\n" }
        let source = "source: \(page.link.absoluteString)"
        var lines = body.components(separatedBy: "\n")
        if let close = frontMatterEnd(in: lines) {
            if !lines[1..<close].contains(where: { $0.hasPrefix("source:") || $0.hasPrefix("url:") }) {
                lines.insert(source, at: close)
            }
            return lines.joined(separator: "\n") + "\n"
        }
        var header = ["---"]
        if let title = page.title {
            let escaped = title.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            header.append("title: \"\(escaped)\"")
        }
        header += [source, "---", ""]
        return (header + [body]).joined(separator: "\n") + "\n"
    }

    /// The index of the `---` that closes front matter opening on the first line, or nil when the text
    /// doesn't start with front matter (a leading `---` can also be a horizontal rule).
    private static func frontMatterEnd(in lines: [String]) -> Int? {
        guard lines.first == "---", let close = lines.dropFirst().firstIndex(of: "---"), close > 1, close <= 40 else { return nil }
        let looksLikeYAML = lines[1..<close].allSatisfy { line in
            line.contains(":") || line.hasPrefix(" ") || line.hasPrefix("-")
        }
        return looksLikeYAML ? close : nil
    }

    /// A file name for the page, without the extension: its title, or its address when it has none
    /// (`example.com-docs-intro`).
    static func fileName(for page: Page) -> String {
        var name = page.title ?? ""
        if name.isEmpty {
            let host = page.link.host() ?? "Web Page"
            let pieces = page.link.pathComponents.filter { $0 != "/" }
            name = ([host.hasPrefix("www.") ? String(host.dropFirst(4)) : host] + pieces).joined(separator: "-")
        }
        name = String(name.prefix(120)).trimmingCharacters(in: .whitespaces)
        // A leading dot would hide the file.
        while name.hasPrefix(".") { name.removeFirst() }
        return name.isEmpty ? "Web Page" : name
    }
}
