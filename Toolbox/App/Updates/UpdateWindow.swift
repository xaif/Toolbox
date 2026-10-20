import AppKit
import SwiftUI

/// The Software Update window: the next version's number and changelog, and the button that installs it.
@MainActor
final class UpdateWindowController: NSObject, NSWindowDelegate {
    static let shared = UpdateWindowController()

    private var window: NSWindow?

    /// Brings the window forward. `check` looks for a new version first, as Check for Updates… does.
    func show(check: Bool = false) {
        let updater = Updater.shared
        if check { updater.check() }
        let window = self.window ?? makeWindow()
        if !window.isVisible { window.center() }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let hosting = NSHostingController(rootView: UpdateView(updater: .shared))
        hosting.sizingOptions = .preferredContentSize
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.title = "Software Update"
        window.identifier = NSUserInterfaceItemIdentifier("software-update")
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.fullScreenNone, .moveToActiveSpace]
        window.delegate = self
        self.window = window
        return window
    }
}

struct UpdateView: View {
    let updater: Updater

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 64, height: 64)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(headline).font(.title3.weight(.semibold))
                    if let detail { Text(detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                }
                progress
                if let notes, !notes.isEmpty {
                    ReleaseNotesList(notes: notes)
                }
                buttons
            }
        }
        .padding(22)
        .frame(width: 600, alignment: .topLeading)
    }

    private var update: AppUpdate? { updater.update }
    private var current: String { updater.currentVersion.description }

    private var headline: String {
        switch updater.phase {
        case .idle, .checking: "Checking for updates…"
        case .upToDate: "Toolbox is up to date"
        case .available: "A new version of Toolbox is available!"
        case .downloading: "Downloading Toolbox \(update?.version.description ?? "")…"
        case .installing: "Installing Toolbox \(update?.version.description ?? "")…"
        case .failed: update == nil ? "Couldn't check for updates" : "Couldn't install the update"
        }
    }

    private var detail: String? {
        switch updater.phase {
        case .idle, .checking:
            return nil
        case .upToDate:
            return "You have Toolbox \(current), the newest version."
        case .available:
            guard let update else { return nil }
            var parts = ["Toolbox \(update.version) is out. You have \(current)."]
            var facts: [String] = []
            if let date = update.date { facts.append("Released \(date.formatted(date: .abbreviated, time: .omitted))") }
            if update.downloadSize > 0 { facts.append(ByteCountFormatter.string(fromByteCount: update.downloadSize, countStyle: .file)) }
            if !facts.isEmpty { parts.append(facts.joined(separator: " · ")) }
            return parts.joined(separator: "\n")
        case .downloading(let fraction):
            guard let update, update.downloadSize > 0 else { return nil }
            let done = ByteCountFormatter.string(fromByteCount: Int64(Double(update.downloadSize) * fraction), countStyle: .file)
            let total = ByteCountFormatter.string(fromByteCount: update.downloadSize, countStyle: .file)
            return "\(done) of \(total)"
        case .installing:
            return "Toolbox will quit and open again by itself in a moment."
        case .failed(let message):
            return message
        }
    }

    /// The changes in the versions after this one, or what's new in this one when it's the newest.
    private var notes: [ReleaseNotes]? {
        switch updater.phase {
        case .upToDate: updater.installedNotes.map { [$0] }
        case .available, .downloading, .installing: update?.notes
        case .failed: update?.notes
        case .idle, .checking: nil
        }
    }

    @ViewBuilder
    private var progress: some View {
        switch updater.phase {
        case .idle, .checking, .installing:
            ProgressView().progressViewStyle(.linear)
        case .downloading(let fraction):
            ProgressView(value: fraction)
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private var buttons: some View {
        HStack {
            switch updater.phase {
            case .available:
                Button("Skip This Version") {
                    updater.skipThisVersion()
                    close()
                }
                Spacer()
                Button("Remind Me Later") {
                    updater.remindLater()
                    close()
                }
                Button("Install Update") { updater.install() }
                    .keyboardShortcut(.defaultAction)
            case .upToDate:
                Button("View All Releases") { updater.openReleasePage() }
                Spacer()
                Button("Check Again") { updater.check() }
                Button("OK") { close() }
                    .keyboardShortcut(.defaultAction)
            case .downloading:
                Spacer()
                Button("Cancel") { updater.cancelInstall() }
                    .keyboardShortcut(.cancelAction)
            case .installing:
                Spacer()
                Button("Cancel") {}.disabled(true)
            case .failed:
                if update != nil {
                    Button("Download from GitHub") { updater.openReleasePage() }
                }
                Spacer()
                Button("Close") { close() }
                    .keyboardShortcut(.cancelAction)
                Button("Try Again") { update == nil ? updater.check() : updater.install() }
                    .keyboardShortcut(.defaultAction)
            case .idle, .checking:
                Spacer()
                Button("Close") { close() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(.top, 2)
    }

    private func close() {
        NSApp.windows.first { $0.identifier?.rawValue == "software-update" }?.close()
    }
}

/// Changelogs, newest version first.
struct ReleaseNotesList: View {
    let notes: [ReleaseNotes]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ForEach(notes) { note in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("Toolbox \(note.version.description)").font(.headline)
                            if let date = note.date {
                                Text(date.formatted(date: .abbreviated, time: .omitted))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        let blocks = ReleaseNotesBlock.blocks(note.markdown)
                        if blocks.isEmpty {
                            Text("No notes for this version.").foregroundStyle(.secondary)
                        }
                        ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                            view(for: block)
                        }
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
        }
        .frame(height: 260)
        .background(.background, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.separator))
    }

    @ViewBuilder
    private func view(for block: ReleaseNotesBlock) -> some View {
        switch block {
        case .heading(let text):
            Text(ReleaseNotesBlock.inline(text)).font(.subheadline.weight(.semibold)).padding(.top, 4)
        case .bullet(let text):
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text("•").foregroundStyle(.secondary)
                Text(ReleaseNotesBlock.inline(text)).fixedSize(horizontal: false, vertical: true)
            }
        case .paragraph(let text):
            Text(ReleaseNotesBlock.inline(text)).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// On the home screen, like Raycast's: a new version is ready, with its headline change.
struct UpdateBanner: View {
    let updater: Updater

    var body: some View {
        if updater.showsBanner, let update = updater.update {
            HStack(spacing: 12) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Toolbox \(update.version.description) is available").font(.headline)
                    Text(Self.summary(of: update))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Button("What's New") { UpdateWindowController.shared.show() }
                Button("Update Now") {
                    updater.install()
                    UpdateWindowController.shared.show()
                }
                .buttonStyle(.borderedProminent)
                Button { updater.remindLater() } label: {
                    Image(systemName: "xmark").foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Hide until Toolbox opens again")
            }
            .padding(14)
            .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.accentColor.opacity(0.25)))
        }
    }

    /// The first change listed for the newest version, as plain text.
    static func summary(of update: AppUpdate) -> String {
        let first = update.notes.first.flatMap { ReleaseNotesBlock.blocks($0.markdown).first { block in
            if case .heading = block { false } else { true }
        } }
        switch first {
        case .bullet(let text), .paragraph(let text):
            return String(ReleaseNotesBlock.inline(text).characters)
        default:
            return "See what's new and install it in a minute."
        }
    }
}
