import SwiftUI

/// A box for pasting links, one per line, with a count of the links found and a Paste button.
struct LinkListEditor: View {
    @Binding var text: String
    /// How many links the tool found in `text`.
    let count: Int
    let placeholder: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Links").font(.headline)
                if count > 0 {
                    Text("\(count)").font(.caption.weight(.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                }
                Spacer()
                Button("Paste") {
                    if let pasted = NSPasteboard.general.string(forType: .string) {
                        text = text.isEmpty ? pasted : text + "\n" + pasted
                    }
                }
            }
            TextEditor(text: $text)
                .font(.body.monospaced())
                .frame(minHeight: 110, maxHeight: 200)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text(placeholder)
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 11).padding(.vertical, 6)
                            .allowsHitTesting(false)
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.separator.opacity(0.5)))
        }
    }
}
