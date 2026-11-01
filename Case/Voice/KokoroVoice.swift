import AVFoundation
#if canImport(KokoroTTS)
@preconcurrency import KokoroTTS
#endif

/// Kokoro: a natural-sounding voice model that runs on the Mac. It downloads once (about 170 MB)
/// the first time; until then, and if anything goes wrong, Aman speaks instead.
/// While one sentence plays, the next is already being made, so there are no gaps.
final class KokoroEngine: SpeechEngine {
    /// The voices offered in the menu, by Kokoro's names.
    static let voices: [(id: String, name: String)] = [
        ("af_heart", "Heart (US)"), ("af_bella", "Bella (US)"), ("am_michael", "Michael (US)"),
        ("am_fenrir", "Fenrir (US)"), ("bf_emma", "Emma (UK)"), ("bm_george", "George (UK)"),
    ]

    var onFinish: (Bool) -> Void = { _ in }
    var voice = "af_heart"
    private(set) var isReady = false
    /// Called with a short status for the menu, like "Downloading voice… 40%".
    var onStatus: (String) -> Void = { _ in }

    private let model = KokoroModel()
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!
    /// Sentences being made ahead of time.
    private var upcoming: [String: Task<[Float], Never>] = [:]
    /// Bumped by stop(), so audio made for an old answer is never played.
    private var generation = 0
    /// What's queued for the sentence being said, in case it has to start over.
    private var scheduled: [(buffer: AVAudioPCMBuffer, isLast: Bool)] = []
    /// Bumped when the audio restarts, so nothing from before that says the sentence finished.
    private var restarts = 0
    private var restart: Task<Void, Never>?

    static var isAvailable: Bool {
        #if canImport(KokoroTTS)
        true
        #else
        false
        #endif
    }

    init() {
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.audioChanged() }
        }
    }

    /// AirPods switch audio modes when the mic turns on or off. That stops the engine and drops what
    /// was queued, without saying so, so the sentence would never finish. Wait for it to settle,
    /// since one switch can report several changes, then say the sentence again.
    private func audioChanged() {
        restarts += 1
        restart?.cancel()
        restart = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            defer { restart = nil }
            restarts += 1
            player.stop()
            guard !scheduled.isEmpty else { return }
            engine.connect(player, to: engine.mainMixerNode, format: format)
            scheduled.forEach { schedule($0.buffer, isLast: $0.isLast) }
            if !startPlaying() { giveUpOnSentence() }
        }
    }

    private func schedule(_ buffer: AVAudioPCMBuffer, isLast: Bool) {
        let (generation, restarts) = (generation, restarts)
        // Lives as long as the app, so holding on to it here is fine.
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in
            guard isLast else { return }
            Task { @MainActor in
                guard generation == self.generation, restarts == self.restarts else { return }
                self.scheduled = []
                self.onFinish(true)
            }
        }
    }

    private func startPlaying() -> Bool {
        if !engine.isRunning { try? engine.start() }
        guard engine.isRunning else { return false }
        player.play()
        return true
    }

    private func giveUpOnSentence() {
        scheduled = []
        onFinish(true)
    }

    /// Loads the model in the background, downloading it the first time.
    func load() {
        guard Self.isAvailable else { return }
        Task {
            do {
                try await model.load { fraction in
                    Task { @MainActor in self.onStatus("Getting voice ready… \(Int(fraction * 100))%") }
                }
                isReady = true
                onStatus("")
            } catch {
                onStatus("Voice couldn't load, using Apple's voice")
            }
        }
    }

    func prepare(_ text: String) {
        guard isReady else { return }
        for piece in Self.pieces(of: text) where upcoming[piece] == nil {
            let voice = voice
            upcoming[piece] = Task { [model] in await model.samples(for: piece, voice: voice) }
        }
    }

    /// Plays the sentence piece by piece as each is ready, so speech starts after the first few words are made.
    func speak(_ text: String) {
        prepare(text)
        let making = Self.pieces(of: text).compactMap { upcoming.removeValue(forKey: $0) }
        guard !making.isEmpty else { return onFinish(true) }
        let generation = generation
        Task {
            var lastPlays = false
            for (index, piece) in making.enumerated() {
                let samples = await piece.value
                guard generation == self.generation else { return }
                let isLast = index == making.count - 1
                guard !samples.isEmpty, let buffer = buffer(from: samples) else { continue }
                scheduled.append((buffer, isLast))
                schedule(buffer, isLast: isLast)
                lastPlays = isLast
                // While the audio is switching, this piece is queued and starts with the rest.
                guard restart != nil || startPlaying() else { return giveUpOnSentence() }
            }
            // The last piece couldn't be made, so nothing will say it's finished: move on anyway.
            if !lastPlays, generation == self.generation { onFinish(true) }
        }
    }

    /// The sentence in parts at commas, each at least a few words long, so the first part is quick to make.
    /// Kokoro makes at most about five seconds at a time anyway, so this costs nothing in how it sounds.
    private static func pieces(of text: String) -> [String] {
        let spoken = SpokenText.forSpeech(text)
        var pieces: [String] = []
        var current = ""
        for word in spoken.split(separator: " ") {
            current += current.isEmpty ? String(word) : " " + word
            if let last = word.last, ",;:".contains(last), current.split(separator: " ").count >= 4 {
                pieces.append(current)
                current = ""
            }
        }
        if !current.isEmpty {
            // A short tail joins the part before it.
            if current.split(separator: " ").count < 3, let previous = pieces.popLast() {
                pieces.append(previous + " " + current)
            } else {
                pieces.append(current)
            }
        }
        return pieces
    }

    func stop() {
        generation += 1
        upcoming.values.forEach { $0.cancel() }
        upcoming = [:]
        scheduled = []
        restart?.cancel()
        restart = nil
        player.stop()
    }

    private func buffer(from samples: [Float]) -> AVAudioPCMBuffer? {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        return buffer
    }
}

/// Owns the Kokoro model and does the heavy work off the main thread.
private actor KokoroModel {
    #if canImport(KokoroTTS)
    private var model: KokoroTTSModel?
    #endif

    func load(progress: @escaping @Sendable (Double) -> Void) async throws {
        #if canImport(KokoroTTS)
        guard model == nil else { return }
        model = try await KokoroTTSModel.fromPretrained(progressHandler: { fraction, _ in progress(fraction) })
        #endif
    }

    /// 24 kHz mono audio for one sentence, or nothing if it couldn't be made.
    func samples(for text: String, voice: String) -> [Float] {
        #if canImport(KokoroTTS)
        guard let model, !Task.isCancelled else { return [] }
        guard let samples = try? model.synthesize(text: text, voice: voice, speed: 1.0) else { return [] }
        return SpokenAudio.louder(SpokenAudio.tightened(samples))
        #else
        return []
        #endif
    }
}
