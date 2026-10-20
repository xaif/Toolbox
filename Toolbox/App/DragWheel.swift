import AppKit
import SwiftUI

enum WheelMode: String, CaseIterable {
    case conversions, tools, actions
    var title: String { rawValue.capitalized }
    var defaultModifier: WheelModifier {
        switch self { case .conversions: .shift; case .tools: .command; case .actions: .control }
    }
    var modifier: WheelModifier {
        WheelModifier(rawValue: UserDefaults.standard.string(forKey: "wheel.key.\(rawValue)") ?? "") ?? defaultModifier
    }
}
enum WheelModifier: String, CaseIterable, Identifiable {
    case shift, command, control, option
    var id: Self { self }
    var label: String {
        switch self { case .shift: "⇧ Shift"; case .command: "⌘ Command"; case .control: "⌃ Control"; case .option: "⌥ Option" }
    }
    var flags: NSEvent.ModifierFlags {
        switch self { case .shift: .shift; case .command: .command; case .control: .control; case .option: .option }
    }
}

struct WheelItem {
    let title: String
    let symbol: String
    let perform: @MainActor ([URL]) -> Void
}

@MainActor
final class DragWheel {
    static let shared = DragWheel()
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var timer: Timer?
    private var panel: WheelPanel?
    private var wheelView: WheelDropView?
    private var files: [URL] = []
    private var lastFlags: NSEvent.ModifierFlags = []
    private var isDragging = false
    private var keyboardMode = false
    private var currentMode: WheelMode = .conversions

    func update() {
        let enabled = UserDefaults.standard.object(forKey: "wheel.enabled") as? Bool ?? false
        guard enabled else { stop(); return }
        guard globalMonitor == nil else { return }
        let events: NSEvent.EventTypeMask = [.leftMouseDragged, .leftMouseUp, .flagsChanged, .keyDown]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: events) { [weak self] event in self?.handle(event) }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: events) { [weak self] event in
            if event.type == .keyDown, self?.panel?.isVisible == true, self?.handleKey(event) == true { return nil }
            self?.handle(event); return event
        }
    }
    private func stop() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil; localMonitor = nil
        close()
    }
    private func handle(_ event: NSEvent) {
        if event.type == .leftMouseDragged {
            if !isDragging {
                files = (NSPasteboard(name: .drag).readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
                guard !files.isEmpty else { return }
                isDragging = true; keyboardMode = false; lastFlags = []
                timer?.invalidate()
                timer = Timer.scheduledTimer(withTimeInterval: 0.04, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.pollDrag() }
                }
            }
            checkModifiers(event.modifierFlags)
        } else if event.type == .flagsChanged, isDragging || keyboardMode {
            checkModifiers(event.modifierFlags)
        } else if event.type == .leftMouseUp, isDragging {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.close() }
        } else if event.type == .keyDown, panel?.isVisible == true { _ = handleKey(event) }
    }
    private func pollDrag() {
        guard isDragging else { return }
        checkModifiers(NSEvent.modifierFlags)
        if NSEvent.pressedMouseButtons & 1 == 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in if self?.isDragging == true { self?.close() } }
        }
    }
    private func checkModifiers(_ flags: NSEvent.ModifierFlags) {
        let flags = flags.intersection([.shift, .control, .command, .option])
        defer { lastFlags = flags }
        for mode in WheelMode.allCases where flags.contains(mode.modifier.flags) && !lastFlags.contains(mode.modifier.flags) {
            show(mode: mode)
            break
        }
    }
    func showForFinderSelection() {
        Task {
            let selection = await FinderSelection.fetch()
            guard !selection.isEmpty else { NSSound.beep(); return }
            files = selection; keyboardMode = true; isDragging = false
            show(mode: .conversions)
            panel?.makeKeyAndOrderFront(nil)
            panel?.makeFirstResponder(wheelView)
        }
    }
    private func show(mode: WheelMode) {
        currentMode = mode
        let items = items(for: mode)
        if panel == nil {
            let panel = WheelPanel(contentRect: NSRect(x: 0, y: 0, width: 390, height: 390), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
            panel.level = .popUpMenu; panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            let view = WheelDropView(frame: NSRect(x: 0, y: 0, width: 390, height: 390))
            view.onChoose = { [weak self] index, dropped in self?.choose(index, files: dropped) }
            view.onKey = { [weak self] event in self?.handleKey(event) ?? false }
            panel.contentView = view; self.panel = panel; wheelView = view
        }
        guard let panel, let wheelView else { return }
        if !panel.isVisible {
            let mouse = NSEvent.mouseLocation
            let area = (NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1000, height: 800)
            panel.setFrameOrigin(NSPoint(x: min(max(mouse.x-195, area.minX), area.maxX-390), y: min(max(mouse.y-195, area.minY), area.maxY-390)))
        }
        wheelView.items = items
        wheelView.heading = mode.title
        wheelView.detail = "\(files.count) \(files.count == 1 ? "file" : "files")"
        wheelView.selected = keyboardMode && !items.isEmpty ? 0 : nil
        wheelView.needsDisplay = true
        panel.orderFrontRegardless()
    }
    private func items(for mode: WheelMode) -> [WheelItem] {
        switch mode {
        case .conversions:
            return ConversionCatalog.commonTargets(for: files).map { target in
                WheelItem(title: ConversionCatalog.label(target), symbol: "arrow.triangle.2.circlepath") { files in
                    guard let tool = ToolRegistry.tool("files.convert") else { return }
                    let runner = JobCenter.shared.runner(for: tool.id)
                    guard !runner.isRunning else { NSSound.beep(); return }
                    runner.inputs = files
                    runner.start(ConversionEngine.job(target: target), title: "Convert to \(target.uppercased())", inputs: files, inBackground: true)
                    if runner.isRunning { JobHUD.shared.show(tool, runner: runner) }
                }
            }
        case .tools:
            return compatibleTools().map { tool in
                WheelItem(title: tool.shortName, symbol: tool.symbol) { files in
                    if tool.quickAction?.asksFirst == false, QuickRun.start(tool, on: files) { return }
                    AppModel.shared.openTool(tool, with: files)
                }
            }
        case .actions:
            return FileAction.allCases.map { action in WheelItem(title: action.title, symbol: action.symbol) { FileActions.perform(action, files: $0) } }
        }
    }
    private func compatibleTools() -> [Tool] {
        guard let first = files.first, let family = ConversionCatalog.family(of: first), files.allSatisfy({ ConversionCatalog.family(of: $0) == family }) else { return [] }
        let ids: [String]
        switch family {
        case .image: ids = ["image.compress", "files.metadata", "image.edit", "image.annotate", "image.background", "image.crop", "image.redact", "pdf.images-to-pdf", "image.collage", "image.read-qr"]
        case .video: ids = ["video.compress", "files.metadata", "video.mute", "video.trim", "video.crop-rotate", "video.speed", "video.merge", "video.snapshots", "video.split", "video.redact"]
        case .audio: ids = ["audio.compress", "files.metadata", "audio.normalize", "audio.visualize", "audio.trim", "audio.channels", "audio.bleep"]
        case .pdf: ids = ["pdf.compress", "files.metadata", "pdf.split", "pdf.organize", "pdf.merge"]
        case .archive: ids = ["files.extract-archive"]
        default: ids = []
        }
        return ids.compactMap(ToolRegistry.tool).filter { files.count >= ($0.quickAction?.minimumFiles ?? 1) }
    }
    private func choose(_ index: Int, files dropped: [URL] = []) {
        let items = items(for: currentMode)
        guard items.indices.contains(index) else { return }
        let input = dropped.isEmpty ? files : dropped
        close()
        DispatchQueue.main.async { items[index].perform(input) }
    }
    @discardableResult private func handleKey(_ event: NSEvent) -> Bool {
        guard panel?.isVisible == true else { return false }
        if event.keyCode == 53 { close(); return true }
        if event.keyCode == 36, let selected = wheelView?.selected { choose(selected); return true }
        if [123, 124, 125, 126].contains(event.keyCode), let view = wheelView, !view.items.isEmpty {
            let delta = event.keyCode == 123 || event.keyCode == 126 ? -1 : 1
            view.selected = ((view.selected ?? 0) + delta + view.items.count) % view.items.count
            view.needsDisplay = true; return true
        }
        return false
    }
    func close() {
        timer?.invalidate(); timer = nil
        panel?.orderOut(nil); files = []; isDragging = false; keyboardMode = false; lastFlags = []
    }
}

private final class WheelPanel: NSPanel { override var canBecomeKey: Bool { true } }

private final class WheelDropView: NSView {
    var items: [WheelItem] = []
    var heading = "Convert", detail = ""
    var selected: Int?
    var onChoose: ((Int, [URL]) -> Void)?
    var onKey: ((NSEvent) -> Bool)?
    override var acceptsFirstResponder: Bool { true }
    override init(frame: NSRect) { super.init(frame: frame); registerForDraggedTypes([.fileURL]) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func keyDown(with event: NSEvent) { if onKey?(event) != true { super.keyDown(with: event) } }
    override func mouseDown(with event: NSEvent) {
        if let index = index(at: convert(event.locationInWindow, from: nil)) { onChoose?(index, []) }
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { update(sender); return .copy }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { update(sender); return selected == nil ? [] : .copy }
    override func draggingExited(_ sender: NSDraggingInfo?) { selected = nil; needsDisplay = true }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { selected != nil }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let selected, let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty else { return false }
        onChoose?(selected, urls); return true
    }
    private func update(_ sender: NSDraggingInfo) { selected = index(at: convert(sender.draggingLocation, from: nil)); needsDisplay = true }
    private func index(at point: CGPoint) -> Int? {
        let dx = point.x-bounds.midX, dy = point.y-bounds.midY
        let distance = hypot(dx, dy)
        guard !items.isEmpty, distance >= 64, distance <= 174 else { return nil }
        let step = 2 * Double.pi / Double(items.count)
        var angle = Double.pi/2 - atan2(dy, dx) + step/2
        while angle < 0 { angle += 2 * .pi }
        return Int(angle.truncatingRemainder(dividingBy: 2 * .pi)/step) % items.count
    }
    override func draw(_ dirtyRect: NSRect) {
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let count = max(items.count, 1)
        for (index, item) in items.enumerated() {
            let angle = 90 - CGFloat(index) * 360/CGFloat(count)
            let half = 180/CGFloat(count)-1.2
            let shape = NSBezierPath()
            shape.appendArc(withCenter: center, radius: 174, startAngle: angle-half, endAngle: angle+half)
            shape.appendArc(withCenter: center, radius: 64, startAngle: angle+half, endAngle: angle-half, clockwise: true)
            shape.close()
            (selected == index ? NSColor.controlAccentColor.withAlphaComponent(0.97) : NSColor.windowBackgroundColor.withAlphaComponent(0.97)).setFill(); shape.fill()
            NSColor.separatorColor.setStroke(); shape.lineWidth = 0.6; shape.stroke()
            let radians = angle * .pi/180
            let point = CGPoint(x: center.x+cos(radians)*118, y: center.y+sin(radians)*118)
            let color = selected == index ? NSColor.onAccent : NSColor.labelColor
            let symbol = NSImage(systemSymbolName: item.symbol, accessibilityDescription: item.title)?.withSymbolConfiguration(.init(pointSize: 18, weight: .medium))
            symbol?.lockFocus(); color.set(); NSRect(origin: .zero, size: symbol?.size ?? .zero).fill(using: .sourceAtop); symbol?.unlockFocus()
            symbol?.draw(in: NSRect(x: point.x-11, y: point.y+2, width: 22, height: 22))
            let style = NSMutableParagraphStyle(); style.alignment = .center
            (item.title as NSString).draw(in: NSRect(x: point.x-43, y: point.y-31, width: 86, height: 31), withAttributes: [.font: NSFont.systemFont(ofSize: count > 8 ? 10 : 12, weight: .semibold), .foregroundColor: color, .paragraphStyle: style])
        }
        NSColor.windowBackgroundColor.withAlphaComponent(0.98).setFill()
        NSBezierPath(ovalIn: NSRect(x: center.x-59, y: center.y-59, width: 118, height: 118)).fill()
        let style = NSMutableParagraphStyle(); style.alignment = .center
        let title = items.isEmpty ? "No options" : selected.map { items[$0].title } ?? heading
        (title as NSString).draw(in: NSRect(x: center.x-56, y: center.y-2, width: 112, height: 30), withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.labelColor, .paragraphStyle: style])
        (detail as NSString).draw(in: NSRect(x: center.x-52, y: center.y-24, width: 104, height: 18), withAttributes: [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: style])
    }
}

struct DragWheelSettings: View {
    @AppStorage("wheel.enabled") private var enabled = false
    @AppStorage("wheel.key.conversions") private var conversions = WheelModifier.shift.rawValue
    @AppStorage("wheel.key.tools") private var tools = WheelModifier.command.rawValue
    @AppStorage("wheel.key.actions") private var actions = WheelModifier.control.rawValue
    @AppStorage("files.terminal") private var terminal = "terminal"
    var body: some View {
        Form {
            Toggle("Show the wheel while dragging files", isOn: $enabled)
            keyPicker("Conversions", selection: $conversions)
            keyPicker("Tools", selection: $tools)
            keyPicker("File actions", selection: $actions)
            if Set([conversions, tools, actions]).count < 3 { Label("Choose a different key for each wheel.", systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
            Text("Start dragging files in Finder, tap a key, then drop onto an option. Release the key and the wheel stays open. Use Escape to cancel. Choose File Wheel from the menu bar for keyboard control: arrow keys choose, Return applies.").foregroundStyle(.secondary)
            Picker("Terminal app", selection: $terminal) { Text("Terminal").tag("terminal"); Text("iTerm2").tag("iterm") }
            Button("Enable global keyboard navigation…") { _ = CGRequestListenEventAccess() }
            Text("macOS may require Input Monitoring for Escape and arrow keys while another app is active. Drag and drop also works with the mouse.").font(.caption).foregroundStyle(.secondary)
        }.formStyle(.grouped)
    }
    private func keyPicker(_ title: String, selection: Binding<String>) -> some View {
        Picker(title, selection: selection) { ForEach(WheelModifier.allCases) { Text($0.label).tag($0.rawValue) } }.disabled(!enabled)
    }
}
