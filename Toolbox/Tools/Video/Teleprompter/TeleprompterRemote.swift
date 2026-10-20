import AppKit
import QuartzCore

/// What the phone remote shows, sent whenever it changes.
struct TeleprompterRemoteState: Encodable, Equatable {
    var showing: Bool
    var playing: Bool
    /// The text is moving right now (not waiting for your voice, a hover or the countdown).
    var moving: Bool
    var title: String
    var cues: [String]
    var cue: Int
    var progress: Double
    var wpm: Int
    var canGoBack: Bool
    var countdown: Int?
    var listening: Bool
    var speaking: Bool
    var secondsLeft: Int
    var finished: Bool
}

/// A button or gesture on the phone remote.
struct TeleprompterRemoteCommand: Codable, Equatable {
    /// toggle, play, pause, faster, slower, scroll, cue, next, previous, back, restart, show or hide.
    var action: String
    /// The cue for `cue`.
    var index: Int?
    /// Lines to scroll for `scroll`; negative scrolls back.
    var lines: Double?
}

/// Turns a phone (or any browser on the same network) into a remote for the teleprompter: play and
/// pause, a dial to scroll, speed, and the list of cues. Runs only between `start()` and `stop()`.
@MainActor
@Observable
final class TeleprompterRemote {
    private(set) var url: URL?
    private(set) var qrCode: NSImage?
    private(set) var isStarting = false
    private(set) var error: String?
    /// Phones with the remote open.
    private(set) var connected = 0

    @ObservationIgnored private(set) var server: LocalHTTPServer?
    @ObservationIgnored private var streams = Set<UUID>()
    @ObservationIgnored private var lastState: TeleprompterRemoteState?

    var isRunning: Bool { server != nil }

    func start() async {
        guard server == nil, !isStarting else { return }
        isStarting = true
        error = nil
        defer { isStarting = false }
        let server = LocalHTTPServer { [weak self] request in
            await self?.handle(request) ?? .notFound
        }
        server.maxBodySize = 16 << 10
        server.onEventStreamClosed = { [weak self] id in Task { @MainActor in self?.streamClosed(id) } }
        do { try await server.start() } catch {
            self.error = error.localizedDescription
            return
        }
        guard let url = server.shareURL else {
            server.stop()
            error = "This Mac isn't on a network. Join the same Wi-Fi as your phone, then try again."
            return
        }
        self.server = server
        self.url = url
        qrCode = LocalHTTPServer.qrCode(for: url.absoluteString)
        Teleprompter.shared.updateRemote(force: true)
    }

    func stop() {
        server?.stop()
        server = nil
        url = nil
        qrCode = nil
        streams = []
        connected = 0
        lastState = nil
    }

    /// Sends `state` to every phone, unless it's what they already have.
    func publish(_ state: TeleprompterRemoteState) {
        guard let server, state != lastState, let json = Self.json(state) else { return }
        lastState = state
        server.broadcast("state", data: json)
    }

    private func handle(_ request: LocalHTTPServer.Request) async -> LocalHTTPServer.Response {
        switch (request.method, request.path) {
        case ("GET", "/"), ("HEAD", "/"):
            return .html(TeleprompterRemotePage.html)
        case ("GET", "/events"):
            let id = UUID()
            streams.insert(id)
            connected = streams.count
            let initial = lastState.flatMap(Self.json).map { [("state", $0)] } ?? []
            server?.openEventStream(id, initial: initial)
            if lastState == nil { Teleprompter.shared.updateRemote(force: true) }
            return LocalHTTPServer.Response(body: .events(id))
        case ("POST", "/command"):
            guard let command = try? JSONDecoder().decode(TeleprompterRemoteCommand.self, from: request.body) else {
                return .text("Bad command", status: 400)
            }
            Teleprompter.shared.perform(command)
            return .json(["ok": true])
        default:
            return .notFound
        }
    }

    private func streamClosed(_ id: UUID) {
        guard streams.remove(id) != nil else { return }
        connected = streams.count
    }

    private static func json(_ state: TeleprompterRemoteState) -> String? {
        (try? JSONEncoder().encode(state)).flatMap { String(data: $0, encoding: .utf8) }
    }
}
