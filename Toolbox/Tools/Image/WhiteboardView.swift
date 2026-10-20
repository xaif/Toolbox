import SwiftUI

extension WhiteboardElement.Kind {
    var label: String {
        switch self {
        case .pen: "Pen"
        case .highlighter: "Highlighter"
        case .eraser: "Eraser"
        case .line: "Line"
        case .rectangle: "Rectangle"
        case .ellipse: "Ellipse"
        case .arrow: "Arrow"
        case .text: "Text"
        }
    }

    var symbol: String {
        switch self {
        case .pen: "pencil.tip"
        case .highlighter: "highlighter"
        case .eraser: "eraser"
        case .line: "line.diagonal"
        case .rectangle: "rectangle"
        case .ellipse: "circle"
        case .arrow: "arrow.up.right"
        case .text: "textformat"
        }
    }

    /// Line width for size 0, 1 or 2 (small, medium, large), as a fraction of the board width.
    /// The browser client uses the same values.
    func width(size: Int) -> Double {
        let size = min(max(size, 0), 2)
        if self == .text { return [0.015, 0.025, 0.04][size] }
        let base = [0.0025, 0.005, 0.0125][size]
        return self == .highlighter ? base * 3 : self == .eraser ? base * 4 : base
    }
}

struct WhiteboardView: View {
    let tool: Tool

    static let palette = ["#1E1E1E", "#E03131", "#F08C00", "#2F9E44", "#1971C2", "#7048E8", "#FFFFFF"]

    @State private var board = WhiteboardBoard.shared
    @State private var runner: JobRunner
    @AppStorage("image.whiteboard.tool") private var kind = WhiteboardElement.Kind.pen
    @AppStorage("image.whiteboard.color") private var color = "#1E1E1E"
    @AppStorage("image.whiteboard.size") private var size = 1
    @AppStorage("image.whiteboard.format") private var format = "png"
    @State private var activeID: String?
    @State private var shapeStart: CGPoint?
    @State private var textPoint: CGPoint?
    @State private var draftText = ""

    init(tool: Tool) {
        self.tool = tool
        _runner = State(initialValue: JobCenter.shared.runner(for: tool.id))
    }

    var body: some View {
        ToolPage(tool: tool, scrolls: false) {
            VStack(spacing: 10) {
                toolbar
                canvas
                if board.isInviting { inviteBar }
                if let error = board.error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        } footer: {
            JobBar(runner: runner, actionTitle: "Export \(format.uppercased())", canRun: !board.elements.isEmpty,
                   hint: "Draw something to export it.", action: export)
        }
        .alert("Add Text", isPresented: Binding(get: { textPoint != nil }, set: { if !$0 { textPoint = nil } })) {
            TextField("Text", text: $draftText)
            Button("Add") { addText() }
            Button("Cancel", role: .cancel) { textPoint = nil }
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Picker("Tool", selection: $kind) {
                    ForEach(WhiteboardElement.Kind.allCases, id: \.self) { kind in
                        Image(systemName: kind.symbol).help(kind.label).tag(kind)
                    }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                Spacer(minLength: 0)
                Button { board.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                    .help("Undo").keyboardShortcut("z").disabled(!board.canUndo)
                Button { board.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                    .help("Redo").keyboardShortcut("z", modifiers: [.command, .shift]).disabled(!board.canRedo)
                Button { board.clear() } label: { Image(systemName: "trash") }
                    .help("Clear the board (undo brings it back)").disabled(board.elements.isEmpty)
                Picker("Background", selection: Binding(get: { board.background }, set: { board.setBackground($0) })) {
                    ForEach(WhiteboardBackground.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .labelsHidden().fixedSize().help("Background")
            }
            HStack(spacing: 12) {
                HStack(spacing: 4) {
                    ForEach(Self.palette, id: \.self) { swatch($0) }
                }
                Picker("Size", selection: $size) {
                    Text("S").tag(0); Text("M").tag(1); Text("L").tag(2)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize().help("Line and text size")
                Spacer(minLength: 0)
                Picker("Export as", selection: $format) {
                    Text("PNG").tag("png"); Text("PDF").tag("pdf")
                }
                .pickerStyle(.segmented).fixedSize()
                Button {
                    if board.isInviting { board.stopInvite() } else { Task { await board.startInvite() } }
                } label: {
                    Label(board.isInviting ? "Stop Inviting" : "Invite…", systemImage: board.isInviting ? "person.2.slash" : "person.2.wave.2")
                }
                .disabled(board.isStarting)
            }
        }
    }

    private func swatch(_ hex: String) -> some View {
        Button { color = hex } label: {
            Circle()
                .fill(Color(cgColor: WhiteboardRenderer.cgColor(hex)))
                .overlay(Circle().strokeBorder(.secondary.opacity(0.4)))
                .frame(width: 20, height: 20)
                .padding(2)
                .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: color == hex ? 2 : 0))
        }
        .buttonStyle(.plain)
        .help(hex)
    }

    // MARK: - Board

    private var canvas: some View {
        // Read here so the view updates as marks arrive; the Canvas closure only draws.
        let elements = board.elements, background = board.background
        return GeometryReader { proxy in
            let boardSize = fittedSize(proxy.size)
            Canvas { context, size in
                context.withCGContext { cg in
                    WhiteboardRenderer.draw(elements, background: background, in: cg, size: size)
                }
            }
            .frame(width: boardSize.width, height: boardSize.height)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.separator))
            .shadow(color: .black.opacity(0.08), radius: 4, y: 1)
            .gesture(drawing(in: boardSize))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minHeight: 260)
        .accessibilityLabel("Whiteboard")
    }

    private func fittedSize(_ space: CGSize) -> CGSize {
        let width = max(min(space.width, space.height * WhiteboardRenderer.aspect), 50)
        return CGSize(width: width, height: width / WhiteboardRenderer.aspect)
    }

    private func drawing(in boardSize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                let point = CGPoint(x: value.location.x / boardSize.width, y: value.location.y / boardSize.height)
                guard kind != .text else { return }
                if let activeID {
                    if kind.isShape, let shapeStart {
                        board.reshape(activeID, points: [shapeStart, point])
                    } else {
                        board.extend(activeID, with: point)
                    }
                    return
                }
                let start = [Double(point.x), Double(point.y)]
                let element = WhiteboardElement(id: UUID().uuidString, kind: kind, color: color, width: kind.width(size: size),
                                                points: kind.isShape ? start + start : start)
                board.begin(element)
                activeID = element.id
                shapeStart = point
            }
            .onEnded { value in
                if kind == .text {
                    textPoint = CGPoint(x: value.location.x / boardSize.width, y: value.location.y / boardSize.height)
                    draftText = ""
                } else if let activeID {
                    board.end(activeID)
                }
                activeID = nil
                shapeStart = nil
            }
    }

    private func addText() {
        let text = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        if let point = textPoint, !text.isEmpty {
            board.addText(text, at: point, color: color, size: WhiteboardElement.Kind.text.width(size: size))
        }
        textPoint = nil
    }

    // MARK: - Invite

    private var inviteBar: some View {
        HStack(alignment: .center, spacing: 14) {
            if let qr = board.qrCode {
                Image(nsImage: qr)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 84, height: 84)
                    .padding(5)
                    .background(.white, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .accessibilityLabel("QR code for the invite link")
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("People on the same network can draw along in any browser:").foregroundStyle(.secondary)
                if let url = board.inviteURL {
                    Text(url.absoluteString).font(.body.monospaced()).textSelection(.enabled)
                    HStack {
                        Button("Copy Link") { AIText.copy(url.absoluteString) }
                        Button("Open in Browser") { NSWorkspace.shared.open(url) }
                    }
                    .controlSize(.small)
                }
                Text("If macOS asks whether Toolbox may accept incoming connections, choose Allow.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Label(board.guests == 0 ? "Only you" : "\(board.guests + 1) people", systemImage: "person.2.fill")
                .foregroundStyle(board.guests == 0 ? .secondary : .primary)
        }
        .padding(12)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.separator.opacity(0.5)))
    }

    // MARK: - Export

    private func export() {
        let elements = board.elements, background = board.background, format = format
        runner.start(title: tool.name) { context in
            let url = context.output(named: "Whiteboard", extension: format)
            context.setStatus("Exporting")
            if format == "pdf" {
                try WhiteboardRenderer.pdf(elements, background: background, to: url)
            } else {
                try WhiteboardRenderer.png(elements, background: background).write(to: url)
            }
        }
    }
}
