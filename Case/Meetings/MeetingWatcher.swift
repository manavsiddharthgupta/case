import AppKit
import CoreAudio
import SwiftUI

/// Notices a video call opening and offers to take notes, once per call, by reading the names of
/// open windows. While recording, it keeps a bar on screen with Pause and Stop, and the bar says
/// so if the call seems to have ended. A window's name can't show that, since it also changes when
/// you switch tabs, so it asks macOS which apps are still using the mic. A wrong guess only changes
/// the bar's words; nothing stops by itself.
final class MeetingWatcher {
    nonisolated struct Window: Sendable {
        let owner: String
        let title: String
    }

    nonisolated struct Call: Equatable, Sendable {
        /// Tells one call from another.
        let id: String
        /// "Google Meet"
        let name: String
    }

    var phase: () -> MeetingRecorder.Phase = { .idle }
    var startedAt: () -> Date? = { nil }
    /// Adds a line to the meeting log.
    var note: (String) -> Void = { _ in }
    var onStart: () -> Void = {}
    var onPause: () -> Void = {}
    var onResume: () -> Void = {}
    var onStop: () -> Void = {}

    private let bar = MeetingBar()
    private var seen: [String: Date] = [:]
    /// A call app has used the mic during this recording. Without that, as when you start notes
    /// for a meeting in the room, there's no call to end.
    private var heardCall = false
    private var quietSince: Date?
    private var callEnded = false
    private var task: Task<Void, Never>?

    private static let checkEvery: Duration = .seconds(3)
    /// A call that's been gone this long counts as new if it comes back.
    private static let forgetAfter: TimeInterval = 10 * 60
    private static let offerFor: Duration = .seconds(15)
    /// Long enough to ride out headphones reconnecting.
    private static let endedAfter: TimeInterval = 9
    /// Apps that hold the mic during a call. Browsers do it through helpers with longer names.
    private nonisolated static let callApps = [
        "com.google.Chrome", "com.apple.WebKit.GPU", "com.apple.Safari", "company.thebrowser", "com.brave.Browser",
        "com.microsoft.edgemac", "org.mozilla.firefox", "us.zoom.xos", "com.microsoft.teams", "com.tinyspeck.slackmacgap",
        "com.hnc.Discord", "com.apple.FaceTime", "com.apple.avconferenced", "com.cisco.webex",
    ]
    private nonisolated static let browsers: Set = ["Google Chrome", "Safari", "Arc", "Brave Browser", "Microsoft Edge", "Dia", "Firefox"]

    func start() {
        task = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.checkEvery)
                offer(for: await Self.openWindows())
                await watchForEnd()
            }
        }
    }

    /// The bar follows the recording: it's up from Start until the notes are written.
    func updateBar() {
        let pause = MeetingBar.Choice(title: "Pause") { [weak self] in self?.onPause() }
        let resume = MeetingBar.Choice(title: "Resume") { [weak self] in self?.onResume() }
        let stop = MeetingBar.Choice(title: "Stop") { [weak self] in self?.onStop() }
        if phase() != .recording { callEnded = false }
        switch phase() {
        case .idle:
            bar.hide()
        case .starting:
            bar.show(.init(text: "Starting…"))
        case .recording:
            bar.show(.init(text: callEnded ? "Call ended" : "", dot: .recording, timerFrom: callEnded ? nil : startedAt(),
                           quiet: pause, main: stop))
        case .paused:
            bar.show(.init(text: "Paused", dot: .paused, quiet: resume, main: stop))
        case .stopping:
            bar.show(.init(text: "Writing your notes…"))
        }
    }

    private func offer(for windows: [Window]) {
        let now = Date.now
        seen = seen.filter { now.timeIntervalSince($0.value) < Self.forgetAfter }
        for call in windows.compactMap(Self.call(in:)) {
            let isNew = seen[call.id] == nil
            seen[call.id] = now
            if isNew, phase() == .idle {
                bar.show(.init(text: "Transcribe \(call.name)?", width: MeetingBar.offerWidth,
                               quiet: .init(title: "Not now") { [weak self] in self?.bar.hide() },
                               main: .init(title: "Start") { [weak self] in self?.onStart() },
                               hidesAfter: Self.offerFor))
            }
        }
    }

    private func watchForEnd() async {
        guard phase() == .recording else {
            heardCall = false
            quietSince = nil
            return
        }
        let apps = await Self.callAppsOnMic()
        if !apps.isEmpty {
            if !heardCall { note("On the mic: \(apps.joined(separator: ", "))") }
            heardCall = true
            quietSince = nil
            // Back in the call.
            if callEnded {
                callEnded = false
                updateBar()
            }
            return
        }
        guard heardCall else { return }
        let since = quietSince ?? .now
        quietSince = since
        guard Date.now.timeIntervalSince(since) >= Self.endedAfter else { return }
        note("Call ended: no call app on the mic")
        heardCall = false
        quietSince = nil
        callEnded = true
        updateBar()
    }

    /// The call in a window, if it is one. Home pages and chat windows don't count.
    nonisolated static func call(in window: Window) -> Call? {
        let title = window.title.replacing("–", with: "-").replacing("—", with: "-")
        if browsers.contains(window.owner) || window.owner == "Google Meet", title.hasPrefix("Meet - ") {
            // Chrome adds to the title once the mic is on, so only the part with the call's name counts.
            let code = title.components(separatedBy: " - ")[1]
            return Call(id: "meet \(code)", name: "Google Meet")
        }
        if window.owner == "zoom.us", title.hasPrefix("Zoom Meeting") || title.hasPrefix("Zoom Webinar") {
            return Call(id: "zoom", name: "Zoom")
        }
        if window.owner == "Microsoft Teams", title.hasPrefix("Meeting") {
            return Call(id: "teams \(title)", name: "Teams")
        }
        return nil
    }

    @concurrent
    private nonisolated static func openWindows() async -> [Window] {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return list.compactMap { info in
            guard info[kCGWindowLayer as String] as? Int == 0,
                  let owner = info[kCGWindowOwnerName as String] as? String,
                  let title = info[kCGWindowName as String] as? String
            else { return nil }
            return Window(owner: owner, title: title)
        }
    }

    /// The call apps macOS says are taking sound from a mic right now.
    @concurrent
    private nonisolated static func callAppsOnMic() async -> [String] {
        func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
            AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                       mElement: kAudioObjectPropertyElementMain)
        }
        let system = AudioObjectID(kAudioObjectSystemObject)
        var list = address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &list, 0, nil, &size) == noErr else { return [] }
        var processes = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &list, 0, nil, &size, &processes) == noErr else { return [] }

        return processes.compactMap { process -> String? in
            var isRunning = address(kAudioProcessPropertyIsRunningInput)
            var running: UInt32 = 0
            var runningSize = UInt32(MemoryLayout<UInt32>.size)
            guard AudioObjectGetPropertyData(process, &isRunning, 0, nil, &runningSize, &running) == noErr, running != 0
            else { return nil }
            var bundleID = address(kAudioProcessPropertyBundleID)
            var bundle: Unmanaged<CFString>?
            var bundleSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            guard AudioObjectGetPropertyData(process, &bundleID, 0, nil, &bundleSize, &bundle) == noErr else { return nil }
            return bundle?.takeRetainedValue() as String?
        }
        .filter { app in callApps.contains { app.hasPrefix($0) } }
    }
}

/// The small bar for meeting notes: the offer to start, then Pause and Stop for as long as it's
/// recording. It never takes the keyboard, so typing in the call carries on. It starts in the bottom
/// left corner, clear of the Mute and Leave buttons calls keep in the middle, and you can drag it.
private final class MeetingBar: NSPanel, NSWindowDelegate {
    enum Dot {
        case recording, paused
    }

    struct Choice {
        var title: String
        var action: () -> Void
    }

    struct Content {
        var text = ""
        var width = MeetingBar.liveWidth
        var dot: Dot?
        var timerFrom: Date?
        var quiet: Choice?
        var main: Choice?
        var hidesAfter: Duration?
    }

    static let offerWidth: CGFloat = 340
    private static let liveWidth: CGFloat = 260
    private static let height: CGFloat = 46
    private static let edgeGap: CGFloat = 20
    private static let placeKey = "meetingBar.origin"

    private let model = BarModel()
    private var hideTask: Task<Void, Never>?

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: Self.liveWidth, height: Self.height),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        // Asks macOS to keep it out of screen sharing.
        sharingType = .none
        delegate = self

        let hosting = NSHostingView(rootView: BarView(model: model))
        hosting.sizingOptions = []
        contentView = hosting
    }

    func show(_ content: Content) {
        model.content = content
        // While it's up it stays put, so it doesn't jump between screens as the words change.
        let origin = isVisible ? frame.origin : Self.savedOrigin ?? Self.cornerOrigin
        setFrame(NSRect(origin: origin, size: CGSize(width: content.width, height: Self.height)), display: true)
        orderFrontRegardless()
        hideTask?.cancel()
        guard let delay = content.hidesAfter else { return }
        hideTask = Task {
            try? await Task.sleep(for: delay)
            if !Task.isCancelled { orderOut(nil) }
        }
    }

    func hide() {
        hideTask?.cancel()
        orderOut(nil)
    }

    func windowDidMove(_ notification: Notification) {
        UserDefaults.standard.set(NSStringFromPoint(frame.origin), forKey: Self.placeKey)
    }

    /// Where you last left it, if that screen is still here.
    private static var savedOrigin: CGPoint? {
        guard let saved = UserDefaults.standard.string(forKey: placeKey) else { return nil }
        let origin = NSPointFromString(saved)
        return NSScreen.screens.contains { $0.visibleFrame.contains(origin) } ? origin : nil
    }

    /// The bottom left of the screen you're on, above the Dock.
    private static var cornerOrigin: CGPoint {
        let mouse = NSEvent.mouseLocation
        let visible = (NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main)?.visibleFrame ?? .zero
        return CGPoint(x: visible.minX + edgeGap, y: visible.minY + edgeGap)
    }
}

@Observable
private final class BarModel {
    var content: MeetingBar.Content?
}

private struct BarView: View {
    let model: BarModel

    var body: some View {
        HStack(spacing: 6) {
            if let content = model.content {
                if content.dot != nil {
                    Color.clear
                        .frame(width: 8, height: 8)
                        .padding(.trailing, 2)
                }
                if let start = content.timerFrom {
                    Text(start, style: .timer)
                        .monospacedDigit()
                }
                if !content.text.isEmpty {
                    Text(content.text)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                if let quiet = content.quiet {
                    Button(quiet.title, action: quiet.action)
                        .buttonStyle(PillButtonStyle())
                }
                if let main = content.main {
                    Button(main.title, action: main.action)
                        .buttonStyle(PillButtonStyle(filled: true))
                }
            }
        }
        .font(Theme.font(14, weight: .medium))
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The words stay readable on any background because they're in the glass.
        .glassEffect(.regular, in: .capsule)
        // The dot sits on top, because glass drains the colour from what it holds and it must stay red.
        .overlay(alignment: .leading) {
            if let dot = model.content?.dot {
                RecordingDot(paused: dot == .paused)
                    .padding(.leading, 16)
            }
        }
        .contentShape(.capsule)
        .gesture(WindowDragGesture())
        // One click on a button is enough, even though this window never takes the keyboard.
        .allowsWindowActivationEvents()
    }
}
