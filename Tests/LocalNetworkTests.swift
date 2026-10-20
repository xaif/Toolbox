import XCTest
import AppKit
import PDFKit
@testable import Toolbox

/// Share on Wi-Fi, the whiteboard and the server under them, over real loopback connections.
@MainActor
final class LocalNetworkTests: XCTestCase {
    private var root: URL!
    private let session = URLSession(configuration: .ephemeral)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("LocalNetworkTests-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func base(_ server: LocalHTTPServer) -> URL {
        URL(string: "http://127.0.0.1:\(server.port)/\(server.token)/")!
    }

    private func get(_ url: URL, headers: [String: String] = [:]) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        let (data, response) = try await session.data(for: request)
        return (data, response as! HTTPURLResponse)
    }

    private func send(_ method: String, _ url: URL, body: Data) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        let (data, response) = try await session.data(for: request)
        return (data, response as! HTTPURLResponse)
    }

    func testServerNeedsTokenAndParsesRanges() async throws {
        let server = LocalHTTPServer { request in .text("path=\(request.path) q=\(request.query["a"] ?? "")") }
        try await server.start()
        defer { server.stop() }
        XCTAssertNotEqual(server.port, 0)
        let root = URL(string: "http://127.0.0.1:\(server.port)")!

        let (_, wrong) = try await get(root.appendingPathComponent("nottoken/"))
        XCTAssertEqual(wrong.statusCode, 404)
        let (_, bare) = try await get(root)
        XCTAssertEqual(bare.statusCode, 404)
        // The token without a trailing slash redirects to the folder.
        let (redirected, response) = try await get(root.appendingPathComponent(server.token))
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(String(data: redirected, encoding: .utf8), "path=/ q=")
        let (data, _) = try await get(URL(string: "\(base(server))some/path?a=b%20c")!)
        XCTAssertEqual(String(data: data, encoding: .utf8), "path=/some/path q=b c")

        XCTAssertEqual(LocalHTTPServer.parseRange("bytes=10-19", size: 100).map { [$0.0, $0.1] }, [10, 19])
        XCTAssertEqual(LocalHTTPServer.parseRange("bytes=90-", size: 100).map { [$0.0, $0.1] }, [90, 99])
        XCTAssertEqual(LocalHTTPServer.parseRange("bytes=-5", size: 100).map { [$0.0, $0.1] }, [95, 99])
        XCTAssertEqual(LocalHTTPServer.parseRange("bytes=50-500", size: 100).map { [$0.0, $0.1] }, [50, 99])
        XCTAssertNil(LocalHTTPServer.parseRange("bytes=100-", size: 100))
        XCTAssertNil(LocalHTTPServer.parseRange("items=1-2", size: 100))
        XCTAssertNotNil(LocalHTTPServer.qrCode(for: base(server).absoluteString))
        XCTAssertEqual(LocalHTTPServer.deviceName(userAgent: "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X)"), "iPhone")
    }

    func testShareServesFilesRangesZipAndReceivesUploads() async throws {
        let first = root.appendingPathComponent("Report.txt")
        let second = root.appendingPathComponent("photo données.bin")
        let bytes = Data((0..<300_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        try bytes.write(to: first)
        try Data(repeating: 7, count: 1234).write(to: second)
        let received = root.appendingPathComponent("Received", isDirectory: true)

        let share = WiFiShare()
        share.receiveFolder = received
        share.files = [first, second]
        await share.start()
        let server = try XCTUnwrap(share.server)
        let base = base(server)

        // The page and the file list.
        let (page, pageResponse) = try await get(base)
        XCTAssertEqual(pageResponse.statusCode, 200)
        XCTAssertTrue(String(decoding: page, as: UTF8.self).contains("EventSource(\"events\")"))
        let (listData, _) = try await get(base.appendingPathComponent("api/files"))
        let list = try JSONSerialization.jsonObject(with: listData) as! [String: Any]
        let files = list["files"] as! [[String: Any]]
        XCTAssertEqual(files.map { $0["name"] as? String }, ["Report.txt", "photo données.bin"])
        XCTAssertEqual(files.first?["size"] as? Int, bytes.count)
        let id = try XCTUnwrap(files.first?["id"] as? String)

        // Whole file, a range and a suffix range.
        let fileURL = base.appendingPathComponent("files/\(id)/Report.txt")
        let (download, downloadResponse) = try await get(fileURL)
        XCTAssertEqual(download, bytes)
        XCTAssertTrue((downloadResponse.value(forHTTPHeaderField: "Content-Disposition") ?? "").contains("attachment"))
        let (slice, sliceResponse) = try await get(fileURL, headers: ["Range": "bytes=1000-1999"])
        XCTAssertEqual(sliceResponse.statusCode, 206)
        XCTAssertEqual(sliceResponse.value(forHTTPHeaderField: "Content-Range"), "bytes 1000-1999/\(bytes.count)")
        XCTAssertEqual(slice, bytes.subdata(in: 1000..<2000))
        let (tail, _) = try await get(fileURL, headers: ["Range": "bytes=-10"])
        XCTAssertEqual(tail, bytes.suffix(10))
        let (_, missing) = try await get(base.appendingPathComponent("files/999/x"))
        XCTAssertEqual(missing.statusCode, 404)

        // Everything as one ZIP.
        let (zip, zipResponse) = try await get(base.appendingPathComponent("all.zip"))
        XCTAssertEqual(zipResponse.statusCode, 200)
        let zipFile = root.appendingPathComponent("all.zip")
        try zip.write(to: zipFile)
        let unpacked = root.appendingPathComponent("unpacked", isDirectory: true)
        try await ArchiveEngine.extract(zipFile, to: unpacked)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: unpacked.path).count, 2)
        XCTAssertEqual(try Data(contentsOf: unpacked.appendingPathComponent("Report.txt")), bytes)

        // Uploads land in the receive folder with clean names and never replace files.
        let upload = Data("hello from a phone".utf8)
        let target = URL(string: "\(base)upload?name=\("note.txt".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!)")!
        let (_, uploaded) = try await send("PUT", target, body: upload)
        XCTAssertEqual(uploaded.statusCode, 200)
        let (_, again) = try await send("PUT", target, body: upload)
        XCTAssertEqual(again.statusCode, 200)
        let sneaky = URL(string: "\(base)upload?name=..%2F..%2Fevil.txt")!
        let (_, sneakyResponse) = try await send("PUT", sneaky, body: upload)
        XCTAssertEqual(sneakyResponse.statusCode, 200)
        let saved = try FileManager.default.contentsOfDirectory(atPath: received.path).sorted()
        XCTAssertEqual(saved, ["-..-evil.txt", "note 2.txt", "note.txt"])
        XCTAssertEqual(try Data(contentsOf: received.appendingPathComponent("note.txt")), upload)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.deletingLastPathComponent().appendingPathComponent("evil.txt").path))
        XCTAssertEqual(share.received.count, 3)
        // Big uploads stream to disk across many reads.
        let big = Data((0..<3_000_000).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ 3) })
        let (_, bigResponse) = try await send("PUT", URL(string: "\(base)upload?name=video.mov")!, body: big)
        XCTAssertEqual(bigResponse.statusCode, 200)
        XCTAssertEqual(try Data(contentsOf: received.appendingPathComponent("video.mov")), big)

        // Turning uploads off refuses them.
        share.allowsUploads = false
        let (_, refused) = try await send("PUT", target, body: upload)
        XCTAssertEqual(refused.statusCode, 403)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: received.path).count, 4)

        // Progress was reported for the download and the uploads.
        try await waitUntil { share.transfers.contains { !$0.isUpload && $0.state == .finished && $0.total == Int64(bytes.count) } }
        XCTAssertTrue(share.transfers.contains { $0.isUpload && $0.state == .finished })

        // Stopping closes the port.
        let port = server.port
        share.stop()
        XCTAssertFalse(share.isSharing)
        do {
            _ = try await get(URL(string: "http://127.0.0.1:\(port)/\(server.token)/")!)
            XCTFail("The server should be closed.")
        } catch let error as URLError {
            XCTAssertTrue([.cannotConnectToHost, .networkConnectionLost, .timedOut].contains(error.code), "\(error.code)")
        }
    }

    func testWhiteboardSyncsBetweenBrowsersAndTheMac() async throws {
        let board = WhiteboardBoard()
        await board.startInvite()
        let server = try XCTUnwrap(board.server)
        defer { board.stopInvite() }
        let base = base(server)

        let first = EventReader(session: session, url: base.appendingPathComponent("events"))
        defer { first.cancel() }
        try await first.waitFor { $0.event == "snapshot" }
        try await waitUntil { board.guests == 1 }

        // A browser draws: the Mac's board and the other browser get it.
        let stroke = WhiteboardElement(id: "web-1", kind: .pen, color: "#E03131", width: 0.005, points: [0.1, 0.1, 0.2, 0.2])
        let add = try JSONEncoder().encode(WhiteboardOp(op: "add", e: stroke, from: "web-b"))
        let (_, added) = try await send("POST", base.appendingPathComponent("op"), body: add)
        XCTAssertEqual(added.statusCode, 200)
        let echoed = try await first.waitFor { $0.event == "op" && $0.data.contains("web-1") }
        XCTAssertTrue(echoed.data.contains("\"from\":\"web-b\""))
        XCTAssertEqual(board.elements.map(\.id), ["web-1"])
        let append = try JSONEncoder().encode(WhiteboardOp(op: "append", id: "web-1", p: [0.3, 0.3], from: "web-b"))
        _ = try await send("POST", base.appendingPathComponent("op"), body: append)
        XCTAssertEqual(board.elements.first?.points, [0.1, 0.1, 0.2, 0.2, 0.3, 0.3])

        // Bad marks and guest clears are refused.
        var bad = stroke
        bad.id = "web-2"
        bad.color = "red"
        let (_, refused) = try await send("POST", base.appendingPathComponent("op"), body: try JSONEncoder().encode(WhiteboardOp(op: "add", e: bad)))
        XCTAssertEqual(refused.statusCode, 400)
        let (_, clear) = try await send("POST", base.appendingPathComponent("op"), body: Data(#"{"op":"clear"}"#.utf8))
        XCTAssertEqual(clear.statusCode, 400)
        XCTAssertEqual(board.elements.count, 1)

        // The Mac draws: browsers get it live, points included.
        board.begin(WhiteboardElement(id: "mac-1", kind: .pen, color: "#1E1E1E", width: 0.005, points: [0.5, 0.5]))
        board.extend("mac-1", with: CGPoint(x: 0.6, y: 0.6))
        board.end("mac-1")
        try await first.waitFor { $0.event == "op" && $0.data.contains("mac-1") && $0.data.contains("\"op\":\"add\"") }
        try await first.waitFor { $0.event == "op" && $0.data.contains("\"op\":\"append\"") && $0.data.contains("0.6") }

        // A late joiner gets the whole board in its snapshot.
        let second = EventReader(session: session, url: base.appendingPathComponent("events"))
        let snapshot = try await second.waitFor { $0.event == "snapshot" }
        XCTAssertTrue(snapshot.data.contains("web-1") && snapshot.data.contains("mac-1"))
        XCTAssertTrue(snapshot.data.contains("0.6"))
        try await waitUntil { board.guests == 2 }
        second.cancel()
        try await waitUntil { board.guests == 1 }

        // Undo removes the Mac's mark everywhere; clear and redo too.
        board.undo()
        try await first.waitFor { $0.event == "op" && $0.data.contains("\"op\":\"remove\"") && $0.data.contains("mac-1") }
        XCTAssertEqual(board.elements.map(\.id), ["web-1"])
        board.clear()
        XCTAssertTrue(board.elements.isEmpty)
        board.undo()
        XCTAssertEqual(board.elements.map(\.id), ["web-1"])
        board.setBackground(.grid)
        try await first.waitFor { $0.event == "op" && $0.data.contains("\"b\":\"grid\"") }
    }

    func testWhiteboardExportsDrawUprightAndEraserCutsInk() throws {
        // A thick black line across the top quarter, then an eraser over its left half.
        let line = WhiteboardElement(id: "a", kind: .pen, color: "#000000", width: 0.02, points: [0.1, 0.25, 0.9, 0.25])
        let eraser = WhiteboardElement(id: "b", kind: .eraser, color: "#000000", width: 0.05, points: [0.05, 0.25, 0.45, 0.25])
        let text = WhiteboardElement(id: "c", kind: .text, color: "#1971C2", width: 0.03, points: [0.1, 0.7], text: "Hello board")

        let png = try WhiteboardRenderer.png([line, eraser, text], background: .white, width: 800)
        let image = try XCTUnwrap(NSBitmapImageRep(data: png))
        XCTAssertEqual(image.pixelsWide, 800)
        XCTAssertEqual(image.pixelsHigh, 500)
        func brightness(_ x: Double, _ y: Double) -> CGFloat {
            image.colorAt(x: Int(x * 800), y: Int(y * 500))?.usingColorSpace(.sRGB)?.brightnessComponent ?? -1
        }
        XCTAssertLessThan(brightness(0.7, 0.25), 0.2, "ink stays where it wasn't erased")
        XCTAssertGreaterThan(brightness(0.3, 0.25), 0.9, "the eraser shows the background")
        XCTAssertGreaterThan(brightness(0.7, 0.75), 0.9, "the bottom is empty, so the image isn't upside down")

        // PDF keeps text as text and draws the same way up.
        let pdfURL = root.appendingPathComponent("board.pdf")
        try WhiteboardRenderer.pdf([line, text], background: .grid, to: pdfURL)
        let document = try XCTUnwrap(PDFDocument(url: pdfURL))
        XCTAssertEqual(document.pageCount, 1)
        XCTAssertTrue(document.page(at: 0)?.string?.contains("Hello board") == true)
        let rendered = try XCTUnwrap(PDFOps.renderPage(try XCTUnwrap(document.page(at: 0)), scale: 0.5))
        let rep = NSBitmapImageRep(cgImage: rendered)
        let top = rep.colorAt(x: Int(0.7 * Double(rep.pixelsWide)), y: Int(0.25 * Double(rep.pixelsHigh)))?.usingColorSpace(.sRGB)?.brightnessComponent ?? 1
        XCTAssertLessThan(top, 0.3)

        // With an eraser the marks become an image, still upright.
        try WhiteboardRenderer.pdf([line, eraser], background: .white, to: pdfURL)
        let erased = try XCTUnwrap(PDFDocument(url: pdfURL)?.page(at: 0))
        let erasedRep = NSBitmapImageRep(cgImage: try XCTUnwrap(PDFOps.renderPage(erased, scale: 0.5)))
        func pdfBrightness(_ x: Double, _ y: Double) -> CGFloat {
            erasedRep.colorAt(x: Int(x * Double(erasedRep.pixelsWide)), y: Int(y * Double(erasedRep.pixelsHigh)))?.usingColorSpace(.sRGB)?.brightnessComponent ?? -1
        }
        XCTAssertLessThan(pdfBrightness(0.7, 0.25), 0.3)
        XCTAssertGreaterThan(pdfBrightness(0.3, 0.25), 0.9)
        XCTAssertGreaterThan(pdfBrightness(0.7, 0.75), 0.9)
    }

    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { XCTFail("Timed out"); throw CancellationError() }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

/// Reads a server-sent event stream in the background.
private final class EventReader: @unchecked Sendable {
    struct Event { let event: String; let data: String }
    private let lock = NSLock()
    private var events: [Event] = []
    private var task: Task<Void, Never>?

    init(session: URLSession, url: URL) {
        task = Task { [weak self] in
            guard let (bytes, _) = try? await session.bytes(for: URLRequest(url: url)) else { return }
            var name = "message"
            do {
                for try await line in bytes.lines {
                    if line.hasPrefix("event: ") { name = String(line.dropFirst(7)) }
                    else if line.hasPrefix("data: ") {
                        let event = Event(event: name, data: String(line.dropFirst(6)))
                        self?.lock.withLock { self?.events.append(event) }
                    }
                }
            } catch {}
        }
    }

    func cancel() { task?.cancel() }

    @discardableResult
    func waitFor(timeout: TimeInterval = 5, _ match: (Event) -> Bool) async throws -> Event {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let event = lock.withLock({ events.first(where: match) }) { return event }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("No matching event arrived")
        throw CancellationError()
    }
}
