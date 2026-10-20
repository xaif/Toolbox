import AppKit
import SwiftUI

/// One mark on the whiteboard. Coordinates are normalized to the board (0…1, origin top-left), so
/// every screen and browser shows the same picture whatever its size. Short JSON keys keep the
/// sync messages small; browsers use the same shape.
struct WhiteboardElement: Codable, Identifiable, Sendable, Equatable {
    enum Kind: String, Codable, Sendable, CaseIterable {
        case pen, highlighter, eraser, line, rectangle, ellipse, arrow, text

        var isShape: Bool { [.line, .rectangle, .ellipse, .arrow].contains(self) }
    }

    var id: String
    var kind: Kind
    /// `#RRGGBB`.
    var color: String
    /// Line width, or font size for text, as a fraction of the board's width.
    var width: Double
    /// Flat x, y pairs. Shapes have a start and an end; text has its top-left corner.
    var points: [Double]
    var text: String?

    enum CodingKeys: String, CodingKey {
        case id, kind = "k", color = "c", width = "w", points = "p", text = "t"
    }

    var cgPoints: [CGPoint] {
        stride(from: 0, to: points.count - 1, by: 2).map { CGPoint(x: points[$0], y: points[$0 + 1]) }
    }

    /// Rejects malformed or oversized marks from browsers.
    var isValid: Bool {
        guard !id.isEmpty, id.count <= 64, width.isFinite, width > 0, width <= 0.2,
              points.count >= 2, points.count <= 40_000, points.count.isMultiple(of: 2),
              points.allSatisfy({ $0.isFinite && $0 > -1 && $0 < 2 }),
              color.count == 7, color.hasPrefix("#"), UInt32(color.dropFirst(), radix: 16) != nil else { return false }
        if kind == .text { return !(text ?? "").isEmpty && (text ?? "").count <= 1000 }
        return true
    }
}

enum WhiteboardBackground: String, Codable, Sendable, CaseIterable {
    case white, grid, dark

    var label: String { rawValue.capitalized }
}

/// A change to the board, as posted by browsers and sent to everyone on the event stream.
struct WhiteboardOp: Codable, Sendable {
    /// add, append, set, remove, clear or bg.
    var op: String
    var e: WhiteboardElement?
    var id: String?
    var p: [Double]?
    var ids: [String]?
    var b: WhiteboardBackground?
    /// The client that made the change, so it can skip its own echo.
    var from: String?
}

/// The shared board: what the Mac draws, what browsers draw, and the local server they use.
@MainActor
@Observable
final class WhiteboardBoard {
    static let shared = WhiteboardBoard()
    static let hostID = "mac"

    private(set) var elements: [WhiteboardElement] = []
    private(set) var background = WhiteboardBackground.white
    private(set) var server: LocalHTTPServer?
    private(set) var inviteURL: URL?
    private(set) var qrCode: NSImage?
    private(set) var isStarting = false
    private(set) var error: String?
    /// Browsers with the board open.
    private(set) var guests = 0

    private enum Action {
        case added(WhiteboardElement)
        case cleared([WhiteboardElement])
    }

    private var index: [String: Int] = [:]
    private var undoStack: [Action] = []
    private var redoStack: [Action] = []
    private var streams = Set<UUID>()
    /// Points drawn locally but not sent yet; sent at most every 40 ms.
    private var pendingPoints: [String: [Double]] = [:]
    private var lastFlush = Date.distantPast

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    var isInviting: Bool { server != nil }

    // MARK: - Drawing on the Mac

    func begin(_ element: WhiteboardElement) {
        flush()
        insert(element)
        broadcast(WhiteboardOp(op: "add", e: element, from: Self.hostID))
    }

    /// Extends a freehand stroke.
    func extend(_ id: String, with point: CGPoint) {
        guard let position = index[id] else { return }
        let values = [Self.round(point.x), Self.round(point.y)]
        elements[position].points += values
        pendingPoints[id, default: []] += values
        if Date().timeIntervalSince(lastFlush) > 0.04 { flush() }
    }

    /// Moves a shape's end point.
    func reshape(_ id: String, points: [CGPoint]) {
        guard let position = index[id] else { return }
        let values = points.flatMap { [Self.round($0.x), Self.round($0.y)] }
        elements[position].points = values
        if Date().timeIntervalSince(lastFlush) > 0.04 {
            lastFlush = Date()
            broadcast(WhiteboardOp(op: "set", id: id, p: values, from: Self.hostID))
        }
    }

    /// Finishes a mark so it can be undone, and sends what's left of it.
    func end(_ id: String) {
        flush()
        guard let position = index[id] else { return }
        let element = elements[position]
        if element.kind.isShape { broadcast(WhiteboardOp(op: "set", id: id, p: element.points, from: Self.hostID)) }
        undoStack.append(.added(element))
        redoStack = []
    }

    func addText(_ text: String, at point: CGPoint, color: String, size: Double) {
        let element = WhiteboardElement(id: UUID().uuidString, kind: .text, color: color, width: size,
                                        points: [Self.round(point.x), Self.round(point.y)], text: text)
        begin(element)
        end(element.id)
    }

    func undo() {
        flush()
        guard let action = undoStack.popLast() else { return }
        switch action {
        case .added(let element):
            remove([element.id])
            broadcast(WhiteboardOp(op: "remove", ids: [element.id], from: Self.hostID))
        case .cleared(let previous):
            for element in previous { insert(element); broadcast(WhiteboardOp(op: "add", e: element, from: Self.hostID)) }
        }
        redoStack.append(action)
    }

    func redo() {
        guard let action = redoStack.popLast() else { return }
        switch action {
        case .added(let element):
            insert(element)
            broadcast(WhiteboardOp(op: "add", e: element, from: Self.hostID))
        case .cleared:
            clearAll()
        }
        undoStack.append(action)
    }

    func clear() {
        guard !elements.isEmpty else { return }
        flush()
        undoStack.append(.cleared(elements))
        redoStack = []
        clearAll()
    }

    func setBackground(_ background: WhiteboardBackground) {
        guard background != self.background else { return }
        self.background = background
        broadcast(WhiteboardOp(op: "bg", b: background, from: Self.hostID))
    }

    private func clearAll() {
        elements = []
        index = [:]
        pendingPoints = [:]
        broadcast(WhiteboardOp(op: "clear", from: Self.hostID))
    }

    private func flush() {
        lastFlush = Date()
        for (id, points) in pendingPoints where !points.isEmpty {
            broadcast(WhiteboardOp(op: "append", id: id, p: points, from: Self.hostID))
        }
        pendingPoints = [:]
    }

    // MARK: - Changes from browsers

    /// Applies a browser's change and passes it on to everyone else. Guests can draw and undo their
    /// own marks; clearing and the background stay with the Mac.
    @discardableResult
    func apply(_ op: WhiteboardOp) -> Bool {
        var op = op
        if op.from == nil || op.from == Self.hostID { op.from = "guest" }
        switch op.op {
        case "add":
            guard let element = op.e, element.isValid, index[element.id] == nil, elements.count < 20_000 else { return false }
            insert(element)
        case "append":
            guard let id = op.id, let position = index[id], let points = op.p, points.count.isMultiple(of: 2),
                  elements[position].points.count + points.count <= 40_000,
                  points.allSatisfy({ $0.isFinite && $0 > -1 && $0 < 2 }) else { return false }
            elements[position].points += points
        case "set":
            guard let id = op.id, let position = index[id], let points = op.p, points.count == 4,
                  points.allSatisfy({ $0.isFinite && $0 > -1 && $0 < 2 }) else { return false }
            elements[position].points = points
        case "remove":
            guard let ids = op.ids, !ids.isEmpty, ids.count <= 100 else { return false }
            remove(ids)
        default:
            return false
        }
        broadcast(op)
        return true
    }

    private func insert(_ element: WhiteboardElement) {
        if let position = index[element.id] { elements[position] = element; return }
        index[element.id] = elements.count
        elements.append(element)
    }

    private func remove(_ ids: [String]) {
        let doomed = Set(ids)
        elements.removeAll { doomed.contains($0.id) }
        index = Dictionary(uniqueKeysWithValues: elements.enumerated().map { ($1.id, $0) })
    }

    // MARK: - Inviting

    func startInvite() async {
        guard server == nil, !isStarting else { return }
        isStarting = true
        error = nil
        defer { isStarting = false }
        let server = LocalHTTPServer { [weak self] request in
            await self?.handle(request) ?? .notFound
        }
        server.maxBodySize = 2 << 20
        server.onEventStreamClosed = { [weak self] id in Task { @MainActor in self?.streamClosed(id) } }
        do { try await server.start() } catch {
            self.error = error.localizedDescription
            return
        }
        self.server = server
        inviteURL = server.shareURL
        qrCode = inviteURL.flatMap { LocalHTTPServer.qrCode(for: $0.absoluteString) }
        if inviteURL == nil { error = "This Mac isn't on a network. Join the same Wi-Fi as your guests, then invite again." }
    }

    func stopInvite() {
        server?.stop()
        server = nil
        inviteURL = nil
        qrCode = nil
        streams = []
        guests = 0
    }

    private func handle(_ request: LocalHTTPServer.Request) async -> LocalHTTPServer.Response {
        switch (request.method, request.path) {
        case ("GET", "/"), ("HEAD", "/"):
            return .html(WhiteboardPage.html)
        case ("GET", "/events"):
            // Send pending points first so the snapshot and later appends don't overlap.
            flush()
            let id = UUID()
            streams.insert(id)
            guests = streams.count
            server?.openEventStream(id, initial: [("snapshot", snapshotJSON)])
            sendPeople()
            return LocalHTTPServer.Response(body: .events(id))
        case ("POST", "/op"):
            guard let op = try? JSONDecoder().decode(WhiteboardOp.self, from: request.body) else {
                return .text("Bad change", status: 400)
            }
            return apply(op) ? .json(["ok": true]) : .text("Change refused", status: 400)
        default:
            return .notFound
        }
    }

    private struct Snapshot: Encodable {
        let elements: [WhiteboardElement]
        let background: WhiteboardBackground
        let people: Int
        let host: String
    }

    private var snapshotJSON: String {
        let snapshot = Snapshot(elements: elements, background: background, people: guests + 1, host: WiFiShare.computerName)
        return (try? JSONEncoder().encode(snapshot)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    private func streamClosed(_ id: UUID) {
        guard streams.remove(id) != nil else { return }
        guests = streams.count
        sendPeople()
    }

    private func sendPeople() {
        server?.broadcast("people", data: "\(guests + 1)")
    }

    private func broadcast(_ op: WhiteboardOp) {
        guard let server, let data = try? JSONEncoder().encode(op), let text = String(data: data, encoding: .utf8) else { return }
        server.broadcast("op", data: text)
    }

    private static func round(_ value: CGFloat) -> Double { (Double(value) * 10_000).rounded() / 10_000 }
}

/// Draws the board with Core Graphics, for the screen and for exports. Expects a context whose
/// origin is top-left (y grows downward) and that spans `size`.
enum WhiteboardRenderer {
    /// Width ÷ height of the board everywhere.
    static let aspect: CGFloat = 1.6

    static func draw(_ elements: [WhiteboardElement], background: WhiteboardBackground, in context: CGContext, size: CGSize) {
        drawBackground(background, in: context, size: size)
        drawMarks(elements, in: context, size: size)
    }

    static func drawBackground(_ background: WhiteboardBackground, in context: CGContext, size: CGSize) {
        context.saveGState()
        context.setFillColor(background == .dark ? CGColor(red: 0.12, green: 0.12, blue: 0.13, alpha: 1) : CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
        if background == .grid {
            let step = size.width / 32
            context.setStrokeColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 0.13))
            context.setLineWidth(max(size.width / 1600, 0.5))
            var x = step
            while x < size.width { context.move(to: CGPoint(x: x, y: 0)); context.addLine(to: CGPoint(x: x, y: size.height)); x += step }
            var y = step
            while y < size.height { context.move(to: CGPoint(x: 0, y: y)); context.addLine(to: CGPoint(x: size.width, y: y)); y += step }
            context.strokePath()
        }
        context.restoreGState()
    }

    /// Marks go in their own layer so the eraser cuts through ink but not the background.
    static func drawMarks(_ elements: [WhiteboardElement], in context: CGContext, size: CGSize) {
        guard !elements.isEmpty else { return }
        context.saveGState()
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        for element in elements { draw(element, in: context, size: size) }
        context.endTransparencyLayer()
        context.restoreGState()
    }

    static func draw(_ element: WhiteboardElement, in context: CGContext, size: CGSize) {
        let points = element.cgPoints.map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) }
        guard let first = points.first else { return }
        let width = max(CGFloat(element.width) * size.width, 0.5)
        let color = cgColor(element.color)
        context.saveGState()
        defer { context.restoreGState() }
        context.setStrokeColor(color)
        context.setLineWidth(width)
        switch element.kind {
        case .pen, .highlighter, .eraser:
            if element.kind == .highlighter { context.setAlpha(0.35) }
            if element.kind == .eraser { context.setBlendMode(.clear) }
            context.addPath(smoothPath(points))
            context.strokePath()
        case .line, .arrow:
            let last = points.last ?? first
            context.move(to: first)
            context.addLine(to: last)
            if element.kind == .arrow {
                let angle = atan2(last.y - first.y, last.x - first.x)
                let head = max(width * 4, size.width / 80)
                for side in [-0.45, 0.45] {
                    context.move(to: last)
                    context.addLine(to: CGPoint(x: last.x - head * cos(angle + side), y: last.y - head * sin(angle + side)))
                }
            }
            context.strokePath()
        case .rectangle, .ellipse:
            let last = points.last ?? first
            let rect = CGRect(x: min(first.x, last.x), y: min(first.y, last.y), width: abs(last.x - first.x), height: abs(last.y - first.y))
            if element.kind == .rectangle { context.stroke(rect) } else { context.strokeEllipse(in: rect) }
        case .text:
            let font = NSFont.systemFont(ofSize: max(width, 4), weight: .medium)
            let string = NSAttributedString(string: element.text ?? "", attributes: [.font: font, .foregroundColor: NSColor(cgColor: color) ?? .black])
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
            string.draw(at: first)
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    /// A curve through the midpoints, so strokes look smooth without extra points.
    static func smoothPath(_ points: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard let first = points.first else { return path }
        path.move(to: first)
        if points.count == 1 {
            path.addLine(to: CGPoint(x: first.x + 0.01, y: first.y))
            return path
        }
        for index in 1..<points.count {
            let previous = points[index - 1], point = points[index]
            path.addQuadCurve(to: CGPoint(x: (previous.x + point.x) / 2, y: (previous.y + point.y) / 2), control: previous)
        }
        path.addLine(to: points[points.count - 1])
        return path
    }

    static func cgColor(_ hex: String) -> CGColor {
        let value = UInt32(hex.dropFirst(), radix: 16) ?? 0
        return CGColor(red: CGFloat((value >> 16) & 0xff) / 255, green: CGFloat((value >> 8) & 0xff) / 255,
                       blue: CGFloat(value & 0xff) / 255, alpha: 1)
    }

    // MARK: - Export

    /// A PNG at `width` pixels wide.
    static func png(_ elements: [WhiteboardElement], background: WhiteboardBackground, width: Int = 3200) throws -> Data {
        let size = CGSize(width: width, height: Int((CGFloat(width) / aspect).rounded()))
        guard let image = bitmap(size: size, draw: { draw(elements, background: background, in: $0, size: size) }),
              let data = PDFOps.encode(image, as: .png, quality: 1, dpi: nil) else {
            throw ToolError.failed("Couldn't draw the whiteboard.")
        }
        return data
    }

    /// A one-page PDF. Ink stays vector unless something was erased, which PDF can't express;
    /// then the marks are embedded as a sharp image over the vector background.
    static func pdf(_ elements: [WhiteboardElement], background: WhiteboardBackground, to url: URL) throws {
        var box = CGRect(x: 0, y: 0, width: 1600, height: 1000)
        guard let context = CGContext(url as CFURL, mediaBox: &box, nil) else { throw ToolError.failed("Couldn't create the PDF.") }
        context.beginPDFPage(nil)
        context.translateBy(x: 0, y: box.height)
        context.scaleBy(x: 1, y: -1)
        drawBackground(background, in: context, size: box.size)
        if elements.contains(where: { $0.kind == .eraser }) {
            let pixels = CGSize(width: box.width * 3, height: box.height * 3)
            if let marks = bitmap(size: pixels, opaque: false, draw: { drawMarks(elements, in: $0, size: pixels) }) {
                // The bitmap is already top-down; flip back so it isn't drawn upside down.
                context.saveGState()
                context.translateBy(x: 0, y: box.height)
                context.scaleBy(x: 1, y: -1)
                context.draw(marks, in: box)
                context.restoreGState()
            }
        } else {
            drawMarks(elements, in: context, size: box.size)
        }
        context.endPDFPage()
        context.closePDF()
    }

    private static func bitmap(size: CGSize, opaque: Bool = true, draw: (CGContext) -> Void) -> CGImage? {
        guard let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: (opaque ? CGImageAlphaInfo.noneSkipLast : CGImageAlphaInfo.premultipliedLast).rawValue) else { return nil }
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        draw(context)
        return context.makeImage()
    }
}
