import AppKit

/// Collecting mode: while it's on, every scroll or page key reads the front window again and keeps
/// any line it hasn't seen yet, so a feed that forgets what scrolled away is still all there after.
/// It reads the app's own words first, and falls back to reading a screenshot for apps that draw
/// their own text. Password boxes and password managers are skipped, and screenshots aren't kept.
@Observable
final class Collector {
    private(set) var isOn = false
    /// Stopped taking more because it reached the limit.
    private(set) var isFull = false
    private(set) var current: UUID?

    private let store: CollectionStore

    @ObservationIgnored private var monitor: Any?
    @ObservationIgnored private var appObserver: NSObjectProtocol?
    @ObservationIgnored private var settle: Task<Void, Never>?
    @ObservationIgnored private var lastRead = ContinuousClock.now
    @ObservationIgnored private var isReading = false
    @ObservationIgnored private var readAgain = false
    /// Every line kept so far, so scrolling back adds nothing and repeated bits like "Reply" show once.
    @ObservationIgnored private var seen: Set<String> = []
    /// The app and window the newest part came from.
    @ObservationIgnored private var partKey: String?

    /// Long enough for a scroll to come to rest.
    private static let settleAfter: Duration = .milliseconds(350)
    /// During a long scroll, still read this often, so a fast fling doesn't skip anything.
    private static let readEvery: Duration = .seconds(1)
    private static let windowLimit = 40_000
    private static let maxCharacters = 500_000
    /// Fewer lines than this means the app doesn't share its words, so the screenshot is read instead.
    private static let fewLines = 3
    /// Space, Page Up, Page Down, Home, End and the arrows.
    private static let pageKeys: Set<UInt16> = [49, 116, 121, 115, 119, 123, 124, 125, 126]
    private static let passwordApps: Set = [
        "com.1password.1password", "com.agilebits.onepassword7", "com.bitwarden.desktop", "com.apple.keychainaccess",
        "com.apple.Passwords", "com.lastpass.LastPass", "com.dashlane.dashlanephonefinal",
    ]

    init(store: CollectionStore) {
        self.store = store
    }

    var lineCount: Int { store.collection(current)?.lineCount ?? 0 }

    func start() {
        guard !isOn else { return }
        isOn = true
        isFull = false
        seen = []
        partKey = nil
        current = store.start()
        // Only other apps' events reach a global monitor, which is what we want: Case's own windows aren't read.
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.scrollWheel, .keyDown]) { [weak self] event in
            self?.handle(event)
        }
        appObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.readSoon() }
        }
        Task { await read() }
    }

    func stop() {
        guard isOn else { return }
        isOn = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        if let appObserver { NSWorkspace.shared.notificationCenter.removeObserver(appObserver) }
        monitor = nil
        appObserver = nil
        settle?.cancel()
        if let current { store.finish(current) }
        current = nil
        seen = []
    }

    private func handle(_ event: NSEvent) {
        if event.type == .keyDown, !Self.pageKeys.contains(event.keyCode) { return }
        if ContinuousClock.now - lastRead >= Self.readEvery { Task { await read() } }
        readSoon()
    }

    /// Once things stop moving.
    private func readSoon() {
        settle?.cancel()
        settle = Task {
            try? await Task.sleep(for: Self.settleAfter)
            guard !Task.isCancelled else { return }
            await read()
        }
    }

    private func read() async {
        guard isOn, !isFull else { return }
        // One read at a time; anything that arrives meanwhile gets one more read after.
        guard !isReading else { return readAgain = true }
        isReading = true
        defer { isReading = false }
        repeat {
            readAgain = false
            lastRead = .now
            await readFrontWindow()
        } while readAgain && isOn
    }

    private func readFrontWindow() async {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              !Self.passwordApps.contains(app.bundleIdentifier ?? "") else { return }
        let pid = app.processIdentifier
        var lines = await ScreenElements.windowText(pid: pid, bundleID: app.bundleIdentifier, limit: Self.windowLimit)
            .map { Self.lines(in: $0.text) } ?? []
        if lines.count < Self.fewLines {
            lines = await readScreenshot(of: pid)
        }
        // Stopped while reading.
        guard isOn, let current else { return }

        let fresh = lines.filter { seen.insert($0).inserted }
        guard !fresh.isEmpty else { return }
        let name = app.localizedName ?? "Unknown app"
        let window = ScreenElements.windowTitle(of: pid)
        let key = "\(app.bundleIdentifier ?? name)|\(window)"
        store.update(current) { collection in
            if key != partKey || collection.parts.isEmpty {
                collection.parts.append(.init(app: name, window: window))
            }
            collection.parts[collection.parts.count - 1].lines += fresh
            if collection.characterCount >= Self.maxCharacters { isFull = true }
        }
        partKey = key
    }

    /// For apps that draw their own text, like some PDF viewers and design tools: only the front window's part.
    private func readScreenshot(of pid: pid_t) async -> [String] {
        guard let screen = try? ScreenCapture.screenUnderCursor(maxSide: 2560),
              let shot = try? await ScreenCapture.capture(screen) else { return [] }
        return await ScreenCapture.recognizeText(in: shot, within: ScreenElements.frontWindowFrame(pid))
    }

    private static func lines(in text: String) -> [String] {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
