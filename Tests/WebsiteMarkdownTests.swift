import XCTest
@testable import Toolbox

final class WebsiteMarkdownTests: XCTestCase {
    private let link = URL(string: "https://example.com/docs/intro")!

    func testLinksAreReadFromPastedText() {
        let text = """
        https://example.com/a?x=1#top
        example.org/page  <http://Sub.Example.net>
        https://example.com/a?x=1#top
        hello e.g. mailto:me@example.com ftp://example.com/file me@example.com
        """
        XCTAssertEqual(WebsiteMarkdown.links(in: text).map(\.absoluteString),
                       ["https://example.com/a?x=1#top", "https://example.org/page", "http://Sub.Example.net"])
        XCTAssertTrue(WebsiteMarkdown.links(in: "  \n ").isEmpty)
    }

    func testRequestCarriesTheLinkAndOptions() throws {
        func body(_ options: WebsiteMarkdown.Options) throws -> [String: Any] {
            let request = WebsiteMarkdown.request(for: link, options: options)
            XCTAssertEqual(request.url, WebsiteMarkdown.endpoint)
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            return try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        }
        let plain = try body(.init())
        XCTAssertEqual(plain["url"] as? String, "https://example.com/docs/intro")
        XCTAssertEqual(plain["method"] as? String, "auto")
        XCTAssertEqual(plain["retain_images"] as? Bool, false)
        let full = try body(.init(keepsImages: true, rendersInBrowser: true))
        XCTAssertEqual(full["method"] as? String, "browser")
        XCTAssertEqual(full["retain_images"] as? Bool, true)
    }

    func testRepliesBecomePagesOrReadableErrors() throws {
        func page(_ json: String, status: Int = 200, options: WebsiteMarkdown.Options = .init()) throws -> WebsiteMarkdown.Page {
            try WebsiteMarkdown.page(from: Data(json.utf8), status: status, link: link, options: options)
        }
        func message(_ json: String, status: Int, options: WebsiteMarkdown.Options = .init()) -> String {
            do { _ = try page(json, status: status, options: options); return "no error" } catch { return error.localizedDescription }
        }

        let good = try page(##"{"success":true,"title":"Intro – Docs","content":"# Intro\n\nHello.","tokens":5}"##)
        XCTAssertEqual(good, .init(link: link, title: "Intro – Docs", markdown: "# Intro\n\nHello."))
        // The service's stand-in title isn't a title.
        XCTAssertNil(try page(#"{"success":true,"title":"Converted Content","content":"Hello."}"#).title)

        XCTAssertEqual(message(#"{"success":false,"error":"Error from The API: Invalid URL format. Please provide a valid URL with http:// or https:// prefix."}"#, status: 500),
                       "Invalid URL format. Please provide a valid URL with http:// or https:// prefix.")
        XCTAssertTrue(message(#"{"success":false,"error":"Error from The API: All conversion methods failed. The page might be empty or inaccessible."}"#, status: 500)
            .hasPrefix("The page is empty or couldn't be reached."))
        XCTAssertTrue(message("Too many requests", status: 429).contains("500 pages a day"))
        XCTAssertEqual(message("<html>Bad gateway</html>", status: 502), "markdown.new couldn't convert this page (HTTP 502).")
        XCTAssertTrue(message(#"{"success":true,"content":"  \n"}"#, status: 200).contains("Render the page in a browser first"))
        XCTAssertEqual(message(#"{"success":true,"content":""}"#, status: 200, options: .init(rendersInBrowser: true)), "The page came back empty.")
    }

    func testDocumentNotesTheTitleAndLink() {
        let plain = WebsiteMarkdown.Page(link: link, title: #"Say "hi": a guide"#, markdown: "\n# Hi\r\n\r\nText.\n\n")
        XCTAssertEqual(WebsiteMarkdown.document(for: plain, options: .init()), """
        ---
        title: "Say \\"hi\\": a guide"
        source: https://example.com/docs/intro
        ---

        # Hi

        Text.

        """)
        XCTAssertEqual(WebsiteMarkdown.document(for: plain, options: .init(addsSource: false)), "# Hi\n\nText.\n")

        // Front matter from the service keeps its title and gains the link.
        let withFrontMatter = WebsiteMarkdown.Page(link: link, title: "Intro", markdown: "---\ntitle: Intro\n---\n\n# Intro\n")
        XCTAssertEqual(WebsiteMarkdown.document(for: withFrontMatter, options: .init()),
                       "---\ntitle: Intro\nsource: https://example.com/docs/intro\n---\n\n# Intro\n")
        XCTAssertEqual(WebsiteMarkdown.document(for: withFrontMatter, options: .init(addsSource: false)), "---\ntitle: Intro\n---\n\n# Intro\n")
        let alreadySourced = WebsiteMarkdown.Page(link: link, title: nil, markdown: "---\ntitle: Intro\nsource: https://other.example\n---\nBody")
        XCTAssertEqual(WebsiteMarkdown.document(for: alreadySourced, options: .init()), "---\ntitle: Intro\nsource: https://other.example\n---\nBody\n")

        // A page that opens with a horizontal rule isn't front matter.
        let rules = WebsiteMarkdown.Page(link: link, title: nil, markdown: "---\nSome text\n---\nMore")
        XCTAssertEqual(WebsiteMarkdown.document(for: rules, options: .init()),
                       "---\nsource: https://example.com/docs/intro\n---\n\n---\nSome text\n---\nMore\n")
    }

    func testFileNamesComeFromTheTitleOrTheAddress() {
        func name(_ title: String?, _ address: String = "https://www.example.com/docs/intro/") -> String {
            WebsiteMarkdown.fileName(for: .init(link: URL(string: address)!, title: title, markdown: ""))
        }
        XCTAssertEqual(name("Markdown - Wikipedia"), "Markdown - Wikipedia")
        XCTAssertEqual(name(nil), "example.com-docs-intro")
        XCTAssertEqual(name(nil, "https://example.com"), "example.com")
        XCTAssertEqual(name(".env files explained"), "env files explained")
        XCTAssertEqual(name(String(repeating: "a", count: 300)).count, 120)
    }

    func testConvertPostsToTheServiceAndReadsTheReply() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        let session = URLSession(configuration: configuration)

        StubProtocol.reply = (200, ##"{"success":true,"title":"Intro","content":"# Intro"}"##)
        let page = try await WebsiteMarkdown.convert(link, options: .init(), session: session)
        XCTAssertEqual(page, .init(link: link, title: "Intro", markdown: "# Intro"))
        XCTAssertEqual(StubProtocol.lastRequest?.url, WebsiteMarkdown.endpoint)
        XCTAssertEqual(StubProtocol.lastRequest?.httpMethod, "POST")

        StubProtocol.reply = (500, #"{"success":false,"error":"Error from The API: Nope."}"#)
        do {
            _ = try await WebsiteMarkdown.convert(link, options: .init(), session: session)
            XCTFail("A failed reply must throw")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Nope.")
        }
    }

    func testTheToolIsRegisteredAndFoundBySearch() {
        XCTAssertNotNil(ToolRegistry.tool("files.website-to-markdown"))
        for query in ["website to markdown", "url to markdown", "web page", "html to markdown"] {
            XCTAssertEqual(ToolRegistry.search(query).first?.id, "files.website-to-markdown", query)
        }
    }
}

/// Answers every request with `reply` instead of touching the network.
private final class StubProtocol: URLProtocol {
    nonisolated(unsafe) static var reply: (status: Int, body: String) = (200, "")
    nonisolated(unsafe) static var lastRequest: URLRequest?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastRequest = request
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.reply.status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(Self.reply.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
