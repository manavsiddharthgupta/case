import AVFoundation
import ScreenCaptureKit
import Speech

/// Listens to a meeting without joining it: your microphone becomes "You" and the Mac's sound
/// becomes "Them". Both are turned into text on the Mac, and no audio is kept.
@Observable
final class MeetingRecorder {
    enum Phase: Equatable {
        case idle, starting, recording, paused, stopping
    }

    private(set) var phase: Phase = .idle {
        didSet { onPhase(phase) }
    }
    private(set) var meetingID: UUID?
    private(set) var startedAt: Date?
    /// Words still being worked out, before they become a line.
    private(set) var hearing: [Meeting.Speaker: String] = [:]
    /// Why notes couldn't be made or recording stopped, to show on the meeting.
    var problem: String?
    /// For the badge on the buddy and the bar at the bottom of the screen.
    @ObservationIgnored var onPhase: (Phase) -> Void = { _ in }

    /// Recording or about to, so nothing else should start one.
    var isActive: Bool { phase != .idle }
    /// In the middle of a meeting, listening or paused.
    var isCapturing: Bool { phase == .recording || phase == .paused }

    private let meetings: MeetingStore
    @ObservationIgnored private var stream: SCStream?
    @ObservationIgnored private var tap: AudioTap?
    @ObservationIgnored private var listeners: [Listener] = []
    /// What happened during this meeting, for the log.
    @ObservationIgnored private var events: [String] = []

    private struct Listener {
        let analyzer: SpeechAnalyzer
        let feed: AudioFeed
        let results: Task<Void, Never>
    }

    init(meetings: MeetingStore) {
        self.meetings = meetings
    }

    func start() async {
        guard phase == .idle else { return }
        phase = .starting
        problem = nil
        events = []
        do {
            let id = meetings.start()
            meetingID = id
            let started = Date.now
            listeners.append(try await listen(as: .you, in: id, startedAt: started))
            listeners.append(try await listen(as: .them, in: id, startedAt: started))
            try await startCapture()
            startedAt = started
            phase = .recording
        } catch {
            saveLog(ending: "Couldn't start: \(error)")
            await finishListening()
            if let meetingID { meetings.delete(meetingID) }
            meetingID = nil
            phase = .idle
            problem = "Couldn't start recording. \(error.localizedDescription)"
        }
    }

    private func startCapture() async throws {
        let tap = AudioTap(you: listeners[0].feed, them: listeners[1].feed) { [weak self] message in
            Task { @MainActor in await self?.stoppedByItself(message) }
        }
        let stream = try await Self.capture(into: tap)
        self.tap = tap
        self.stream = stream
    }

    /// Turns the mic and the Mac's sound off completely, but keeps the meeting open.
    func pause() async {
        guard phase == .recording else { return }
        phase = .paused
        note("Paused")
        try? await stream?.stopCapture()
        stream = nil
        tap = nil
    }

    func resume() async {
        guard phase == .paused else { return }
        listeners.forEach { $0.feed.pickUpAgain() }
        do {
            try await startCapture()
            note("Resumed")
            phase = .recording
        } catch {
            problem = "Couldn't carry on recording. \(error.localizedDescription)"
        }
    }

    func note(_ event: String) {
        events.append("\(Date.now.formatted(date: .omitted, time: .standard)) \(event)")
    }

    /// Stops listening, then writes the notes.
    func stop() async {
        guard isCapturing, let id = meetingID else { return }
        phase = .stopping
        try? await stream?.stopCapture()
        saveLog(ending: "Stopped with the Stop button.")
        await wrapUp(id)
    }

    /// The call's sound or the mic went away, or macOS took the permission back.
    private func stoppedByItself(_ message: String) async {
        guard phase == .recording, let id = meetingID else { return }
        phase = .stopping
        saveLog(ending: message)
        await wrapUp(id)
        problem = message
    }

    /// Counts only, no words. Only the latest is kept, to show which step failed if a side comes out empty.
    private func saveLog(ending: String) {
        let lines = meetings.meeting(meetingID)?.lines ?? []
        let sides = zip([Meeting.Speaker.you, .them], listeners).map { speaker, listener in
            "\(speaker.name): \(listener.feed.report), \(lines.filter { $0.speaker == speaker }.count) lines so far"
        }
        let report = ([Date.now.formatted(), ending] + sides + events).joined(separator: "\n")
        try? report.write(to: Storage.folder.appending(path: "last-meeting.txt"), atomically: true, encoding: .utf8)
    }

    private func wrapUp(_ id: UUID) async {
        await finishListening()
        meetings.update(id) { $0.ended = .now }
        await makeNotes(for: id)
        meetingID = nil
        startedAt = nil
        phase = .idle
    }

    func makeNotes(for id: UUID) async {
        do {
            try await MeetingNotes.make(for: id, in: meetings)
        } catch {
            problem = error.localizedDescription
        }
    }

    private func finishListening() async {
        stream = nil
        tap = nil
        listeners.forEach { $0.feed.finish() }
        for listener in listeners {
            try? await listener.analyzer.finalizeAndFinishThroughEndOfInput()
            await listener.results.value
        }
        listeners = []
        hearing = [:]
    }

    /// One speech recognizer for one side of the call. Each line is saved as soon as it's final.
    private func listen(as speaker: Meeting.Speaker, in id: UUID, startedAt: Date) async throws -> Listener {
        let (transcriber, format) = try await VoiceInput.prepareTranscriber(attributes: .audioTimeRange)
        let (input, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
        let results = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    guard let self else { return }
                    let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard result.isFinal else {
                        hearing[speaker] = text
                        continue
                    }
                    hearing[speaker] = nil
                    guard !text.isEmpty else { continue }
                    let start = result.range.start
                    let at = start.isNumeric ? start.seconds : Date.now.timeIntervalSince(startedAt)
                    let line = Meeting.Line(speaker: speaker, text: text, at: at)
                    meetings.update(id) { meeting in
                        meeting.lines.append(line)
                        meeting.lines.sort { $0.at < $1.at }
                    }
                }
            } catch {}
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        try await analyzer.start(inputSequence: input)
        return Listener(analyzer: analyzer, feed: AudioFeed(format: format, continuation: continuation, startedAt: startedAt), results: results)
    }

    /// The Mac's sound and the mic come through the same stream. It needs a screen to attach to,
    /// so it's given the smallest, slowest picture possible.
    @concurrent
    private nonisolated static func capture(into tap: AudioTap) async throws -> SCStream {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else { throw ScreenCapture.CaptureError.noDisplay }
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])

        let config = SCStreamConfiguration()
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.showsCursor = false
        config.capturesAudio = true
        config.captureMicrophone = true
        config.sampleRate = 48_000
        config.channelCount = 1
        // Case's own voice isn't part of the meeting.
        config.excludesCurrentProcessAudio = true

        let stream = SCStream(filter: filter, configuration: config, delegate: tap)
        try stream.addStreamOutput(tap, type: .screen, sampleHandlerQueue: tap.screenQueue)
        try stream.addStreamOutput(tap, type: .audio, sampleHandlerQueue: tap.themQueue)
        try stream.addStreamOutput(tap, type: .microphone, sampleHandlerQueue: tap.youQueue)
        try await stream.startCapture()
        return stream
    }
}

/// Receives the stream's audio. Each side stays on its own queue, off the main actor.
private nonisolated final class AudioTap: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let youQueue = DispatchQueue(label: "case.meeting.you")
    let themQueue = DispatchQueue(label: "case.meeting.them")
    let screenQueue = DispatchQueue(label: "case.meeting.screen")

    private let you: AudioFeed
    private let them: AudioFeed
    private let onStop: @Sendable (String) -> Void

    init(you: AudioFeed, them: AudioFeed, onStop: @escaping @Sendable (String) -> Void) {
        self.you = you
        self.them = them
        self.onStop = onStop
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        switch type {
        case .microphone: you.take(sample)
        case .audio: them.take(sample)
        default: break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        onStop("Recording stopped early. \(error.localizedDescription)")
    }
}

/// Hands one side's audio to its recognizer, in the format it wants. Quiet spells can arrive as no
/// audio at all, so they're filled with silence to keep both sides on the same clock.
private nonisolated final class AudioFeed: @unchecked Sendable {
    private let format: AVAudioFormat
    private let continuation: AsyncStream<AnalyzerInput>.Continuation
    private let startedAt: Date
    private var converter: AVAudioConverter?
    /// Seconds into the meeting that the first sample arrived, and that sample's own time.
    private var anchor: (meeting: Double, sample: Double)?
    private var fedSeconds = 0.0
    /// For the meeting log.
    private var received = 0
    private var failed = 0
    private var firstFormat = "no audio arrived"

    var report: String {
        "\(received) audio pieces, \(failed) couldn't be read, \(Int(fedSeconds)) s fed in, from \(firstFormat)"
    }

    private static let longestGap = 0.25

    init(format: AVAudioFormat, continuation: AsyncStream<AnalyzerInput>.Continuation, startedAt: Date) {
        self.format = format
        self.continuation = continuation
        self.startedAt = startedAt
    }

    func finish() {
        continuation.finish()
    }

    /// After a pause: the next audio is placed by the clock, so the pause counts as silence.
    func pickUpAgain() {
        anchor = nil
    }

    func take(_ sample: CMSampleBuffer) {
        received += 1
        guard sample.isValid, let buffer = Self.pcmBuffer(from: sample) else {
            failed += 1
            return
        }
        if received == 1 { firstFormat = buffer.format.description }

        let time = sample.presentationTimeStamp.seconds
        let anchor = anchor ?? (Date.now.timeIntervalSince(startedAt), time)
        self.anchor = anchor
        let gap = anchor.meeting + (time - anchor.sample) - fedSeconds
        if gap > Self.longestGap { feedSilence(seconds: gap) }

        if let converted = convert(buffer) {
            feed(converted)
        } else {
            failed += 1
        }
    }

    private func feed(_ buffer: AVAudioPCMBuffer) {
        fedSeconds += Double(buffer.frameLength) / format.sampleRate
        continuation.yield(AnalyzerInput(buffer: buffer))
    }

    private func feedSilence(seconds: Double) {
        var remaining = AVAudioFrameCount(seconds * format.sampleRate)
        while remaining > 0 {
            let frames = min(remaining, AVAudioFrameCount(format.sampleRate))
            guard let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
            silence.frameLength = frames
            for part in UnsafeMutableAudioBufferListPointer(silence.mutableAudioBufferList) {
                if let data = part.mData { memset(data, 0, Int(part.mDataByteSize)) }
            }
            feed(silence)
            remaining -= frames
        }
    }

    private static func pcmBuffer(from sample: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard var description = sample.formatDescription?.audioStreamBasicDescription,
              let format = AVAudioFormat(streamDescription: &description),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(sample.numSamples))
        else { return nil }
        buffer.frameLength = buffer.frameCapacity
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sample, at: 0, frameCount: Int32(sample.numSamples), into: buffer.mutableAudioBufferList)
        return status == noErr ? buffer : nil
    }

    /// The mic's format changes when headphones are plugged in, so the converter follows the audio.
    private func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: format)
        }
        guard let converter else { return nil }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }

        let source = BufferOnce(buffer)
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            guard let next = source.take() else {
                status.pointee = .noDataNow
                return nil
            }
            status.pointee = .haveData
            return next
        }
        return error == nil && output.frameLength > 0 ? output : nil
    }
}
