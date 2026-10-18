import AppKit
import AVFoundation
import ScreenCaptureKit

/// Records the screen with ScreenCaptureKit's SCRecordingOutput. Pausing finalizes the current
/// segment file and resuming starts a new one; the editor joins them. Also logs left clicks inside
/// the captured region for auto-zoom.
final class RecordingEngine: NSObject, SCStreamDelegate, SCRecordingOutputDelegate, SCStreamOutput, @unchecked Sendable {
    /// The captured region in global CoreGraphics coordinates (points, top-left origin).
    /// For a window capture that follows the window, `windowID` is used to look up its current bounds.
    struct Region {
        var rect: CGRect
        var windowID: CGWindowID?
    }

    private struct RawClick {
        var segment: Int
        var offset: Double
        var x: Double
        var y: Double
    }

    private let filter: SCContentFilter
    private let configuration: SCStreamConfiguration
    private let folder: URL
    private let fileType: AVFileType
    private let codec: AVVideoCodecType
    private let region: Region
    private let sampleQueue = DispatchQueue(label: "toolbox.recording.samples")

    private var stream: SCStream?
    private var currentOutput: SCRecordingOutput?
    private var clickMonitor: Any?

    private let lock = NSLock()
    private var segmentURLs: [URL] = []
    private var segmentStartedAt: Double?
    private var rawClicks: [RawClick] = []
    private var finishedOutputs: Set<ObjectIdentifier> = []
    private var finishWaiters: [ObjectIdentifier: CheckedContinuation<Void, Never>] = [:]
    private var recordingError: Error?

    /// Called on the main queue if capture stops on its own (e.g. the user stopped sharing from the menu bar).
    var onUnexpectedStop: ((Error) -> Void)?

    init(filter: SCContentFilter, configuration: SCStreamConfiguration, region: Region, folder: URL,
         fileType: AVFileType, codec: AVVideoCodecType) {
        self.filter = filter
        self.configuration = configuration
        self.region = region
        self.folder = folder
        self.fileType = fileType
        self.codec = codec
    }

    var segments: [URL] {
        lock.lock(); defer { lock.unlock() }
        return segmentURLs.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    var error: Error? {
        lock.lock(); defer { lock.unlock() }
        return recordingError
    }

    // MARK: Control

    func start() async throws {
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        // A screen output keeps frames flowing to the recording output; samples are ignored.
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
        if configuration.capturesAudio {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
        }
        if configuration.captureMicrophone {
            try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: sampleQueue)
        }
        self.stream = stream
        try beginSegment()
        try await stream.startCapture()
        await MainActor.run { installClickMonitor() }
    }

    func pause() async {
        guard let stream, let output = currentOutput else { return }
        currentOutput = nil
        clearSegmentStart()
        try? stream.removeRecordingOutput(output)
        await waitForFinish(of: output)
    }

    func resume() throws {
        guard currentOutput == nil else { return }
        try beginSegment()
    }

    /// Finalizes the current segment and stops capture.
    func stop() async {
        await MainActor.run { removeClickMonitor() }
        if let stream, let output = currentOutput {
            currentOutput = nil
            try? stream.removeRecordingOutput(output)
            await waitForFinish(of: output)
        }
        try? await stream?.stopCapture()
        stream = nil
    }

    /// Click positions mapped onto the joined timeline, given each segment's actual duration.
    func clicks(segmentDurations: [Double]) -> [RecordingClick] {
        lock.lock(); let raw = rawClicks; let urls = segmentURLs; lock.unlock()
        // Segments that never produced a file are skipped by the editor, so skip them here too.
        var offsets: [Int: Double] = [:]
        var cursor = 0.0
        var durationIndex = 0
        for (index, url) in urls.enumerated() where FileManager.default.fileExists(atPath: url.path) {
            offsets[index] = cursor
            cursor += durationIndex < segmentDurations.count ? segmentDurations[durationIndex] : 0
            durationIndex += 1
        }
        return raw.compactMap { click in
            guard let start = offsets[click.segment] else { return nil }
            return RecordingClick(time: start + click.offset, x: click.x, y: click.y)
        }
    }

    private func beginSegment() throws {
        guard let stream else { return }
        let ext = fileType == .mov ? "mov" : "mp4"
        lock.lock()
        let url = folder.appendingPathComponent(String(format: "segment-%02d.%@", segmentURLs.count + 1, ext))
        lock.unlock()
        let config = SCRecordingOutputConfiguration()
        config.outputURL = url
        config.outputFileType = fileType
        config.videoCodecType = codec
        let output = SCRecordingOutput(configuration: config, delegate: self)
        try stream.addRecordingOutput(output)
        lock.lock(); segmentURLs.append(url); lock.unlock()
        currentOutput = output
    }

    private func clearSegmentStart() {
        lock.lock(); segmentStartedAt = nil; lock.unlock()
    }

    private func waitForFinish(of output: SCRecordingOutput) async {
        let id = ObjectIdentifier(output)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if finishedOutputs.contains(id) {
                lock.unlock()
                continuation.resume()
                return
            }
            finishWaiters[id] = continuation
            lock.unlock()
            // Don't hang forever if the delegate never reports back.
            DispatchQueue.global().asyncAfter(deadline: .now() + 6) { [weak self] in self?.markFinished(id) }
        }
    }

    private func markFinished(_ id: ObjectIdentifier) {
        lock.lock()
        finishedOutputs.insert(id)
        let waiter = finishWaiters.removeValue(forKey: id)
        lock.unlock()
        waiter?.resume()
    }

    // MARK: Clicks

    @MainActor
    private func installClickMonitor() {
        // Global monitors see clicks in other apps without Accessibility permission. Clicks on
        // Toolbox's own windows (excluded from the capture) are deliberately ignored.
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] _ in
            self?.recordClick(at: NSEvent.mouseLocation)
        }
    }

    @MainActor
    private func removeClickMonitor() {
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
    }

    private func recordClick(at cocoaPoint: CGPoint) {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let point = CGPoint(x: cocoaPoint.x, y: primaryHeight - cocoaPoint.y)
        var rect = region.rect
        if let windowID = region.windowID, let bounds = Self.bounds(ofWindow: windowID) { rect = bounds }
        guard rect.width > 0, rect.height > 0, rect.contains(point) else { return }
        let x = Double((point.x - rect.minX) / rect.width)
        let y = Double((point.y - rect.minY) / rect.height)
        let now = CACurrentMediaTime()
        lock.lock()
        if let started = segmentStartedAt {
            rawClicks.append(RawClick(segment: segmentURLs.count - 1, offset: now - started, x: x, y: y))
        }
        lock.unlock()
    }

    private static func bounds(ofWindow id: CGWindowID) -> CGRect? {
        guard let info = (CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]])?.first,
              let dictionary = info[kCGWindowBounds as String] as? NSDictionary else { return nil }
        return CGRect(dictionaryRepresentation: dictionary as CFDictionary)
    }

    // MARK: Delegates

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {}

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        lock.lock(); if recordingError == nil { recordingError = error }; lock.unlock()
        DispatchQueue.main.async { self.onUnexpectedStop?(error) }
    }

    func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) {
        lock.lock(); segmentStartedAt = CACurrentMediaTime(); lock.unlock()
    }

    func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        lock.lock(); if recordingError == nil { recordingError = error }; lock.unlock()
        markFinished(ObjectIdentifier(recordingOutput))
    }

    func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        markFinished(ObjectIdentifier(recordingOutput))
    }
}
