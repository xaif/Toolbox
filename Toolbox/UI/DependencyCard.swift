import SwiftUI

/// Explains a missing dependency and offers one-click install through Homebrew.
struct DependencyCard: View {
    let dependency: ExternalDependency
    var compact = false

    @Environment(Dependencies.self) private var dependencies

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "shippingbox")
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(.secondary)
                    .frame(width: 34)
                VStack(alignment: .leading, spacing: 4) {
                    Text("This tool needs \(dependency.displayName)").font(.headline)
                    Text("\(dependency.purpose) It isn't bundled with Toolbox. Install it with one click through Homebrew, or point Toolbox at a copy you already have.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack {
                switch dependencies.installState(dependency) {
                case .installing:
                    ProgressView().controlSize(.small)
                    Text("Installing \(dependency.displayName)…").foregroundStyle(.secondary)
                case .failed(let message):
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(message).foregroundStyle(.secondary).textSelection(.enabled)
                case .idle:
                    EmptyView()
                }
                Spacer()
                Button("Choose Existing…") { chooseBinary() }
                    .disabled(dependencies.installState(dependency) == .installing)
                if Dependencies.homebrewURL != nil {
                    Button("Install with Homebrew") { dependencies.install(dependency) }
                        .buttonStyle(.borderedProminent)
                        .disabled(dependencies.installState(dependency) == .installing)
                } else {
                    Link("Get Homebrew", destination: URL(string: "https://brew.sh")!)
                        .buttonStyle(.borderedProminent)
                }
            }
            if !compact, dependencies.installState(dependency) != .idle, !dependencies.log(for: dependency).isEmpty {
                ScrollViewReader { proxy in
                    ScrollView {
                        Text(dependencies.log(for: dependency).joined(separator: "\n"))
                            .font(.system(.caption, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .padding(8)
                        Color.clear.frame(height: 1).id("end")
                    }
                    .frame(height: 140)
                    .background(.black.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                    .onChange(of: dependencies.log(for: dependency).count) { proxy.scrollTo("end") }
                }
            }
        }
        .padding(16)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.separator.opacity(0.5)))
    }

    private func chooseBinary() {
        let panel = NSOpenPanel()
        panel.message = "Choose the \(dependency.executableName) program"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/opt/homebrew/bin")
        panel.treatsFilePackagesAsDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        dependencies.setCustomExecutable(url, for: dependency)
    }
}
