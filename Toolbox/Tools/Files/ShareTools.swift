import SwiftUI

/// Tools that work with other devices on the same network, straight from this Mac.
enum ShareTools {
    static let all: [Tool] = [
        Tool(id: "files.share-wifi", name: "Share on Wi-Fi", category: .files, symbol: "wifi",
             summary: "Send files to any phone or computer on your network, and get files back, in a browser.",
             keywords: ["p2p", "peer to peer", "transfer", "send", "receive", "phone", "android", "windows", "local network", "qr", "upload", "share"],
             input: ToolInput(types: [.item])) { ShareWiFiView(tool: $0) },
        Tool(id: "image.whiteboard", name: "Whiteboard", category: .image, symbol: "scribble.variable",
             summary: "Sketch on a board and invite people on your network to draw along live.",
             keywords: ["collaborative", "draw", "sketch", "canvas", "board", "realtime", "live", "share", "drawing"]) { WhiteboardView(tool: $0) },
    ]
}
