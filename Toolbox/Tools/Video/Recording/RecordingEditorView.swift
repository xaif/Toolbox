import SwiftUI
import AVFoundation

/// Edit a finished take: preview, trim, auto zoom, captions, then export.
struct RecordingEditorView: View {
    let tool: Tool
    let studio: RecordingStudio
    @Bindable var editor: RecordingEditorModel
    let runner: JobRunner

    @State private var confirmDiscard = false

    var body: some View {
        ToolPage(tool: tool, runner: runner) {
            HStack {
                Label("\(TimeFormat.string(editor.take.duration)) recorded · \(Int(editor.take.size.width)) × \(Int(editor.take.size.height))",
                      systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Record Again…") { confirmDiscard = true }
                    .disabled(runner.isRunning)
            }

            preview

            ToolSection("Trim") {
                RangeSlider(range: $editor.trim, bounds: 0...max(editor.take.duration, 0.1),
                            playhead: editor.currentTime, minimumLength: 0.5,
                            onScrub: { editor.seek(to: $0) })
                HStack(spacing: 20) {
                    TimeField(label: "Start", seconds: lowerBinding, range: 0...editor.take.duration)
                    TimeField(label: "End", seconds: upperBinding, range: 0...editor.take.duration)
                    Spacer()
                    Text("Length \(TimeFormat.string(editor.trim.upperBound - editor.trim.lowerBound, precise: true))")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }

            ToolSection("Effects") {
                Toggle("Auto zoom on clicks", isOn: $editor.autoZoom)
                    .disabled(editor.take.clicks.isEmpty)
                if editor.take.clicks.isEmpty {
                    Text("No clicks were recorded, so there's nothing to zoom into.")
                        .font(.caption).foregroundStyle(.secondary)
                } else if editor.autoZoom {
                    LabeledContent("Zoom level") {
                        HStack {
                            Slider(value: $editor.zoomScale, in: 1.3...2.6) { editing in
                                if !editing { editor.rebuildPreview() }
                            }
                            .frame(maxWidth: 220)
                            Text(String(format: "%.1f×", editor.zoomScale)).monospacedDigit().frame(width: 40)
                        }
                    }
                    Text("\(editor.take.clicks.count) click\(editor.take.clicks.count == 1 ? "" : "s") detected. The preview shows the zoom.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Divider()

                Toggle("Captions", isOn: $editor.captionsEnabled)
                    .disabled(!editor.transcriptionAvailable)
                if !editor.transcriptionAvailable {
                    Text("On-device transcription isn't available on this Mac.")
                        .font(.caption).foregroundStyle(.secondary)
                } else if editor.captionsEnabled {
                    Picker("Language", selection: $editor.locale) {
                        ForEach(editor.locales, id: \.identifier) { locale in
                            Text(Transcriber.displayName(for: locale)).tag(Optional(locale))
                        }
                    }
                    .frame(maxWidth: 320)
                    captionStatus
                }
            }
            .disabled(runner.isRunning)

            ToolSection("Export") {
                Picker("Format", selection: $editor.format) {
                    ForEach(RecordingExportFormat.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                Picker("Resolution", selection: $editor.resolution) {
                    Text("Original (\(Int(editor.take.size.width)) × \(Int(editor.take.size.height)))").tag(RecordingExportResolution.original)
                    Text("1080p").tag(RecordingExportResolution.p1080)
                }
                .frame(maxWidth: 320)
            }
            .disabled(runner.isRunning)
        } footer: {
            JobBar(runner: runner, actionTitle: "Export", canRun: editor.canExport,
                   hint: editor.isReady ? "Waiting for captions…" : "Loading recording…") {
                editor.player.pause()
                runner.start(title: tool.name, work: editor.exportJob())
            }
        }
        .confirmationDialog("Discard this recording?", isPresented: $confirmDiscard) {
            Button("Discard and Record Again", role: .destructive) {
                runner.reset()
                studio.discardTake()
            }
        } message: {
            Text("Anything you haven't exported will be lost.")
        }
    }

    @ViewBuilder
    private var preview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12).fill(.black)
            if let error = editor.loadError {
                Text(error).foregroundStyle(.white)
            } else if editor.isReady {
                PlayerView(player: editor.player)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(alignment: .bottom) {
                        if let caption = editor.activeCaption {
                            Text(caption)
                                .font(.system(size: 15, weight: .semibold))
                                .multilineTextAlignment(.center)
                                .foregroundStyle(.white)
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .background(.black.opacity(0.68), in: RoundedRectangle(cornerRadius: 6))
                                .padding(.bottom, 56)
                                .allowsHitTesting(false)
                        }
                    }
            } else {
                ProgressView().tint(.white)
            }
        }
        .frame(height: 380)
    }

    @ViewBuilder
    private var captionStatus: some View {
        if editor.transcribing {
            HStack(spacing: 8) {
                ProgressView(value: editor.transcriptionProgress).frame(maxWidth: 200)
                Text("Transcribing on your Mac…").foregroundStyle(.secondary)
            }
        } else if let error = editor.captionError {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(error).foregroundStyle(.secondary)
                Button("Try Again") { editor.transcribe() }
            }
        } else if let cues = editor.cues {
            Text("\(cues.count) captions ready. They're burned into the video and saved as an .srt file too.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var lowerBinding: Binding<Double> {
        Binding(get: { editor.trim.lowerBound },
                set: { editor.trim = min($0, editor.trim.upperBound - 0.5)...editor.trim.upperBound })
    }

    private var upperBinding: Binding<Double> {
        Binding(get: { editor.trim.upperBound },
                set: { editor.trim = editor.trim.lowerBound...max($0, editor.trim.lowerBound + 0.5) })
    }
}
