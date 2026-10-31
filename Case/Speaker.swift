import AppKit

/// Reads answers aloud, a sentence at a time as they stream in, so it starts talking before the whole
/// answer has arrived. The voice is Kokoro (a voice model on the Mac) once it's ready, or Apple's Aman.
/// It also sets the pace: when the buddy points at something, it waits for it to land before talking about it.
@Observable
final class Speaker {
    var isMuted = UserDefaults.standard.bool(forKey: "speaker.muted") {
        didSet {
            UserDefaults.standard.set(isMuted, forKey: "speaker.muted")
            if isMuted { stop() }
        }
    }

    private(set) var isSpeaking = false
    /// Called with each sentence as it starts being said, so the caption can follow along.
    @ObservationIgnored var onSentence: (String) -> Void = { _ in }

    /// A Kokoro voice id, or "aman" for Apple's voice.
    var voice = UserDefaults.standard.string(forKey: "speaker.voice") ?? KokoroEngine.voices[0].id {
        didSet {
            UserDefaults.standard.set(voice, forKey: "speaker.voice")
            kokoro.voice = voice
        }
    }
    /// For the menu while the voice model downloads, like "Downloading voice… 40%".
    private(set) var voiceStatus = ""

    /// Long enough for the buddy to fly to the next thing and settle.
    private static let pauseAfterPointing: Duration = .milliseconds(650)

    @ObservationIgnored private let aman = (LegacySpeech.self as SpeechEngineMaker.Type).make()
    @ObservationIgnored private let kokoro = KokoroEngine()
    /// Kokoro once it's loaded and chosen; Aman otherwise.
    private var engine: any SpeechEngine { kokoro.isReady && voice != "aman" ? kokoro : aman }
    @ObservationIgnored private var queue: [Item] = []
    /// Text that hasn't reached the end of a sentence yet.
    @ObservationIgnored private var pending = ""
    /// Pointing that arrived in the middle of `pending`; it happens when that sentence starts.
    @ObservationIgnored private var pendingMarks: [() -> Void] = []
    /// Bumped by stop(), so a pause that was waiting doesn't carry on afterwards.
    @ObservationIgnored private var generation = 0
    /// Moves on if a sentence never reports back. The buddy flying home and the caption fading
    /// both wait for speech, so without this one lost sentence leaves them stuck until Esc.
    @ObservationIgnored private var watchdog: Task<Void, Never>?

    private enum Item {
        case say(String)
        /// `evenIfStopped` actions still run when speech is cut short, e.g. "the explanation is over".
        case run(() -> Void, evenIfStopped: Bool)
        case pause(Duration)
    }

    init() {
        // A sentence that was cut off by stop() doesn't move the queue along.
        for engine in [aman, kokoro] as [any SpeechEngine] {
            engine.onFinish = { [weak self] completed in
                if completed { self?.speakNext() }
            }
        }
        kokoro.voice = voice
        kokoro.onStatus = { [weak self] status in self?.voiceStatus = status }
        kokoro.load()
    }

    /// Adds newly streamed answer text; complete sentences are spoken right away.
    func feed(_ text: String) {
        guard !isMuted else { return }
        pending += text
        while let end = Self.sentenceEnd(in: pending) {
            enqueue(String(pending[..<end]))
            pending = String(pending[end...])
        }
    }

    /// Runs `action` just before the next sentence is spoken, then pauses briefly.
    /// That's how the buddy lands on a thing right as Aman starts talking about it.
    func mark(_ action: @escaping () -> Void) {
        guard !isMuted else { return }
        if pending.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            queue += [.run(action, evenIfStopped: false), .pause(Self.pauseAfterPointing)]
            if !isSpeaking { speakNext() }
        } else {
            // In the middle of a sentence: point when that sentence starts, so it isn't cut in two.
            pendingMarks.append(action)
        }
    }

    /// Runs `action` once everything queued so far has been said, or right away if speech is stopped.
    func whenDone(_ action: @escaping () -> Void) {
        queue.append(.run(action, evenIfStopped: true))
        if !isSpeaking { speakNext() }
    }

    /// A short progress line, like "Opening WhatsApp". Skipped while something is still being said,
    /// so the voice never falls behind the work.
    func sayIfIdle(_ line: String) {
        guard !isMuted, !isSpeaking, queue.isEmpty else { return }
        enqueue(line)
    }

    /// The answer is complete: speak whatever is left.
    func finish() {
        guard !isMuted else { return }
        enqueue(pending)
        pending = ""
        // Pointing that never got a sentence of its own.
        queue += pendingMarks.map { .run($0, evenIfStopped: false) }
        pendingMarks = []
    }

    func stop() {
        generation += 1
        watchdog?.cancel()
        let mustRun = queue.compactMap { item -> (() -> Void)? in
            if case .run(let action, true) = item { action } else { nil }
        }
        queue.removeAll()
        pending = ""
        pendingMarks = []
        if isSpeaking {
            aman.stop()
            kokoro.stop()
        }
        isSpeaking = false
        mustRun.forEach { $0() }
    }

    private func enqueue(_ sentence: String) {
        let spoken = Self.plainText(sentence)
        guard !spoken.isEmpty else { return }
        // One pointing per sentence; any extra waits for the next sentence.
        if !pendingMarks.isEmpty {
            queue += [.run(pendingMarks.removeFirst(), evenIfStopped: false), .pause(Self.pauseAfterPointing)]
        }
        queue.append(.say(spoken))
        // Start making it now, so it's ready by the time it's needed.
        engine.prepare(spoken)
        if !isSpeaking { speakNext() }
    }

    private func speakNext() {
        watchdog?.cancel()
        while !queue.isEmpty {
            switch queue.removeFirst() {
            case .run(let action, _):
                action()
            case .pause(let duration):
                isSpeaking = true
                let generation = generation
                Task {
                    try? await Task.sleep(for: duration)
                    if generation == self.generation { speakNext() }
                }
                return
            case .say(let sentence):
                isSpeaking = true
                onSentence(sentence)
                // First, because a sentence with nothing to say finishes inside speak().
                watch(sentence)
                engine.speak(sentence)
                return
            }
        }
        isSpeaking = false
    }

    /// Well past how long the sentence should take, even with a slow start.
    private func watch(_ sentence: String) {
        let limit = Duration.seconds(8 + Double(sentence.count) * 0.15)
        let generation = generation
        watchdog = Task {
            try? await Task.sleep(for: limit)
            guard !Task.isCancelled, generation == self.generation else { return }
            aman.stop()
            kokoro.stop()
            speakNext()
        }
    }

    /// Where the first full sentence ends: after . ! ? followed by a space, or at a line break.
    private static func sentenceEnd(in text: String) -> String.Index? {
        var previous: Character?
        for index in text.indices {
            let character = text[index]
            if character == "\n" { return text.index(after: index) }
            if character.isWhitespace, let previous, ".!?".contains(previous) { return index }
            previous = character
        }
        return nil
    }

    /// Markdown symbols read badly out loud.
    private static func plainText(_ text: String) -> String {
        var spoken = text
        for symbol in ["**", "__", "`", "#"] {
            spoken = spoken.replacingOccurrences(of: symbol, with: "")
        }
        spoken = spoken.replacingOccurrences(of: #"^\s*[-•*]\s+"#, with: "", options: .regularExpression)
        return spoken.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

protocol SpeechEngine: AnyObject {
    /// Called with true when a sentence finished, false when it was stopped.
    var onFinish: (Bool) -> Void { get set }
    /// A hint that this sentence is coming up, for voices that take a moment to make audio.
    func prepare(_ text: String)
    func speak(_ text: String)
    func stop()
}

extension SpeechEngine {
    func prepare(_ text: String) {}
}

/// Aman (Premium) is only reachable through NSSpeechSynthesizer, which Apple marks deprecated;
/// the newer AVSpeechSynthesizer doesn't list it. Creating it through this protocol keeps
/// the deprecation warning inside this one spot.
private protocol SpeechEngineMaker {
    static func make() -> any SpeechEngine
}

private enum LegacySpeech: SpeechEngineMaker {}

extension LegacySpeech {
    @available(macOS, deprecated: 14.0)
    static func make() -> any SpeechEngine { LegacySpeechEngine() }
}

@available(macOS, deprecated: 14.0)
private final class LegacySpeechEngine: NSObject, SpeechEngine, NSSpeechSynthesizerDelegate {
    var onFinish: (Bool) -> Void = { _ in }
    private let synthesizer: NSSpeechSynthesizer

    override init() {
        let aman = NSSpeechSynthesizer.VoiceName(rawValue: "com.apple.voice.Aman.premium")
        synthesizer = NSSpeechSynthesizer(voice: aman) ?? NSSpeechSynthesizer()
        // A little slower than normal, so explanations are easier to follow.
        synthesizer.rate *= 0.9
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ text: String) {
        synthesizer.startSpeaking(text)
    }

    func stop() {
        synthesizer.stopSpeaking()
    }

    nonisolated func speechSynthesizer(_ sender: NSSpeechSynthesizer, didFinishSpeaking finishedSpeaking: Bool) {
        Task { @MainActor in self.onFinish(finishedSpeaking) }
    }
}
