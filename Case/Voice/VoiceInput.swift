import AVFoundation
import Speech

/// Turns your voice into text on the Mac while you hold the hotkey, with live words as you speak.
/// Uses Apple's on-device SpeechTranscriber, in the accent chosen in setup, so nothing leaves the Mac.
final class VoiceInput {
    enum VoiceError: LocalizedError {
        case noMicrophone
        case unsupported

        var errorDescription: String? {
            switch self {
            case .noMicrophone: "Couldn't find a microphone."
            case .unsupported: "Speech recognition isn't available for English on this Mac."
            }
        }
    }

    /// The English accents Apple's speech model offers.
    static let accents: [(id: String, name: String)] = [
        ("en-AU", "Australia"), ("en-CA", "Canada"), ("en-IN", "India"), ("en-IE", "Ireland"), ("en-NZ", "New Zealand"),
        ("en-SG", "Singapore"), ("en-ZA", "South Africa"), ("en-GB", "United Kingdom"), ("en-US", "United States"),
    ]

    /// The chosen accent; until there is one, the Mac's own region if it's on the list.
    static var accent: String {
        get {
            let region = Locale.current.region?.identifier ?? ""
            return UserDefaults.standard.string(forKey: "voice.accent")
                ?? accents.first { $0.id == "en-\(region)" }?.id ?? "en-US"
        }
        set { UserDefaults.standard.set(newValue, forKey: "voice.accent") }
    }

    /// Called with everything heard so far, each time it changes.
    var onText: (String) -> Void = { _ in }
    /// How loud you are right now, from 0 (silent) to 1, for the voice wave.
    var onLevel: (Double) -> Void = { _ in }

    private var microphone: Microphone?
    private var analyzer: SpeechAnalyzer?
    private var startTask: Task<Void, Error>?
    private var resultsTask: Task<Void, Never>?
    private var finalized = ""
    private var volatile = ""

    func start() {
        finalized = ""
        volatile = ""
        startTask = Task { try await begin() }
    }

    /// Stops listening and returns everything that was said.
    func stop() async throws -> String {
        // Let a slow start finish first, so nothing is left running.
        try await startTask?.value
        microphone?.stop()
        onLevel(0)
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        await resultsTask?.value
        microphone = nil
        analyzer = nil
        resultsTask = nil
        return (finalized + volatile).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A recognizer for the chosen accent, and the audio format it wants.
    static func prepareTranscriber(attributes: SpeechTranscriber.ResultAttributeOption...) async throws -> (SpeechTranscriber, AVAudioFormat) {
        let transcriber = try await makeTranscriber(attributes: Set(attributes))
        // Setup has normally done this already; this only downloads if Apple's model is missing.
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw VoiceError.unsupported
        }
        return (transcriber, format)
    }

    /// Gets Apple's speech model onto this Mac if it's missing. Its progress stays at 0 until the
    /// download is over, so this can only say that one has started.
    static func installModel(onDownload: () -> Void) async throws {
        let transcriber = try await makeTranscriber(attributes: [])
        // Every accent tried keeps one of Apple's few reserved places until it's let go.
        let chosen = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: accent))
        for locale in await AssetInventory.reservedLocales where locale != chosen {
            await AssetInventory.release(reservedLocale: locale)
        }
        guard let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) else { return }
        onDownload()
        try await request.downloadAndInstall()
    }

    private static func makeTranscriber(attributes: Set<SpeechTranscriber.ResultAttributeOption>) async throws -> SpeechTranscriber {
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: accent)) else {
            throw VoiceError.unsupported
        }
        return SpeechTranscriber(locale: locale, transcriptionOptions: [],
                                 reportingOptions: [.volatileResults], attributeOptions: attributes)
    }

    private func begin() async throws {
        let (transcriber, format) = try await Self.prepareTranscriber()

        // Start the microphone before the analyzer, so the first words aren't lost while it loads.
        let (input, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
        let microphone = try Microphone(format: format, continuation: continuation)
        microphone.onLevel = { [weak self] level in
            Task { @MainActor in self?.onLevel(level) }
        }
        try microphone.start()
        self.microphone = microphone

        resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    guard let self else { return }
                    let text = String(result.text.characters)
                    if result.isFinal {
                        finalized += text
                        volatile = ""
                    } else {
                        volatile = text
                    }
                    onText(finalized + volatile)
                }
            } catch {}
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer
        try await analyzer.start(inputSequence: input)
    }
}

/// Feeds microphone audio to the analyzer in the format it wants.
/// Runs on the audio thread, so it stays off the main actor.
private nonisolated final class Microphone: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let converter: AVAudioConverter
    private let inputFormat: AVAudioFormat
    private let outputFormat: AVAudioFormat
    private let continuation: AsyncStream<AnalyzerInput>.Continuation
    /// Set before `start()`; called from the audio thread.
    var onLevel: @Sendable (Double) -> Void = { _ in }

    init(format: AVAudioFormat, continuation: AsyncStream<AnalyzerInput>.Continuation) throws {
        inputFormat = engine.inputNode.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, let converter = AVAudioConverter(from: inputFormat, to: format) else {
            throw VoiceInput.VoiceError.noMicrophone
        }
        self.converter = converter
        self.outputFormat = format
        self.continuation = continuation
    }

    func start() throws {
        engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [self] buffer, _ in
            onLevel(Self.loudness(of: buffer))
            if let converted = convert(buffer) {
                continuation.yield(AnalyzerInput(buffer: converted))
            }
        }
        engine.prepare()
        try engine.start()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        continuation.finish()
    }

    /// Average loudness mapped so normal speech lands around the middle: -50 dB is silent, -5 dB is loud.
    private static func loudness(of buffer: AVAudioPCMBuffer) -> Double {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var sum: Float = 0
        for index in 0..<Int(buffer.frameLength) { sum += samples[index] * samples[index] }
        let rms = sqrt(sum / Float(buffer.frameLength))
        let decibels = 20 * log10(max(rms, 0.000_01))
        return Double(min(max((decibels + 50) / 45, 0), 1))
    }

    private func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let ratio = outputFormat.sampleRate / inputFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return nil }

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

/// Hands the converter one buffer, then reports "no more for now".
nonisolated final class BufferOnce: @unchecked Sendable {
    private var buffer: AVAudioPCMBuffer?

    init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }

    func take() -> AVAudioPCMBuffer? {
        defer { buffer = nil }
        return buffer
    }
}
