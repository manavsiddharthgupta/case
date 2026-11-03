import Sparkle
import SwiftUI

@main
struct CaseApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @State private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuView()
                .environment(model)
        } label: {
            MenuBarLabel(model: model, appDelegate: appDelegate)
        }

        Window("Case", id: "main") {
            MainWindow()
                .environment(model)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1040, height: 680)
        .defaultLaunchBehavior(model.needsSetup ? .suppressed : .presented)
        .restorationBehavior(.disabled)

        Window("Set up Case", id: "setup") {
            SetupView()
                .environment(model)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        // Open setup on launch until it's been finished, or if a permission has gone missing since.
        .defaultLaunchBehavior(model.needsSetup ? .presented : .suppressed)
    }
}

/// Clicking Case's icon while it's running goes to `onReopen`, not to whichever window macOS picks.
final class AppDelegate: NSObject, NSApplicationDelegate {
    var onReopen: () -> Void = {}

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        onReopen()
        return false
    }
}

/// The menu bar icon. It's the one view that's always there, so it opens windows for the app icon too.
private struct MenuBarLabel: View {
    let model: AppModel
    let appDelegate: AppDelegate
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            if model.recorder.phase == .recording {
                Image(systemName: "record.circle")
            } else if model.recorder.phase == .paused {
                Image(systemName: "pause.circle")
            } else if model.collector.isOn {
                Image(systemName: "text.viewfinder")
            } else {
                Image(nsImage: .menuBarMark)
            }
        }
        .task {
            appDelegate.onReopen = { [model, openWindow] in
                NSApp.activate()
                openWindow(id: model.needsSetup ? "setup" : "main")
            }
        }
    }
}

/// Shared app state: Claude Code's connection, the Mac permissions, the assistant, and what's saved.
@Observable
final class AppModel {
    enum Page: CaseIterable {
        case chats, meetings, memory
    }

    let permissions = Permissions()
    let chats = ChatStore()
    let memory = MemoryStore()
    let meetings = MeetingStore()
    let collections = CollectionStore()
    let assistant: Assistant
    let collector: Collector
    let recorder: MeetingRecorder
    let watcher = MeetingWatcher()
    /// Looks for a new version once a day, and asks before installing it.
    @ObservationIgnored private let updates = SPUStandardUpdaterController(
        startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    private(set) var claude: ClaudeCLI.Status = .checking
    /// What the window is showing.
    var page = Page.chats

    @ObservationIgnored private let hotkey = Hotkey()

    var needsSetup: Bool {
        !permissions.allGranted || !UserDefaults.standard.bool(forKey: "setup.finished")
    }

    /// How many chats left over from last time memory reads at launch, so it never holds things up.
    private static let chatsToCatchUp = 3

    init() {
        assistant = Assistant(chats: chats, memory: memory)
        recorder = MeetingRecorder(meetings: meetings)
        collector = Collector(store: collections)
        Theme.registerFont()
        // Writing to a claude that just exited should be an error, not a crash.
        signal(SIGPIPE, SIG_IGN)
        permissions.refresh()
        // Opens on press so the box feels instant; holding it means talk.
        hotkey.onPress = { [assistant] in assistant.hotkeyPressed() }
        hotkey.onRelease = { [assistant] in assistant.hotkeyReleased() }
        hotkey.onCancel = { [assistant] in assistant.hotkeyCancelled() }
        assistant.pointer.start()
        recorder.onPhase = { [watcher] _ in watcher.updateBar() }
        watcher.phase = { [recorder] in recorder.phase }
        watcher.startedAt = { [recorder] in recorder.startedAt }
        watcher.note = { [recorder] in recorder.note($0) }
        watcher.onStart = { [weak self] in self?.startMeeting() }
        watcher.onPause = { [recorder] in Task { await recorder.pause() } }
        watcher.onResume = { [recorder] in Task { await recorder.resume() } }
        watcher.onStop = { [recorder] in Task { await recorder.stop() } }
        watcher.start()
        assistant.onMeetingCommand = { [weak self] in self?.meetingCommand($0) ?? "" }
        assistant.collected = { [collections, collector] in (collections.latest, collector.isOn) }
        Task {
            await refreshClaude()
            guard case .connected = claude else { return }
            assistant.prepare()
            // A chat only ends when the next one starts, so the last one before quitting is read here.
            for chat in chats.chats.filter({ $0.learnedTurns < $0.turns.count }).prefix(Self.chatsToCatchUp) {
                await MemoryLearner.learn(from: chat, chats: chats, memory: memory)
            }
        }
    }

    /// You're in the call, so nothing else opens. If it can't start, say so at the cursor.
    private func startMeeting() {
        Task {
            await recorder.start()
            guard let problem = recorder.problem else { return }
            assistant.pointer.setCaption(.init(text: problem, kind: .problem))
            assistant.pointer.fadeCaption(after: .seconds(6))
        }
    }

    /// "Pause the notes" and the like, said or typed. Returns what to tell you.
    private func meetingCommand(_ action: String) -> String {
        let nothing = "There are no meeting notes running."
        switch action {
        case "start", "begin":
            if recorder.phase == .paused { return meetingCommand("resume") }
            guard !recorder.isActive else { return "Already taking notes." }
            startMeeting()
            return "Taking meeting notes."
        case "pause":
            guard recorder.phase == .recording else { return recorder.phase == .paused ? "Already paused." : nothing }
            Task { await recorder.pause() }
            return "Notes paused."
        case "resume", "continue":
            guard recorder.phase == .paused else { return recorder.phase == .recording ? "Already taking notes." : nothing }
            Task { await recorder.resume() }
            return "Notes back on."
        default:
            guard recorder.isCapturing else { return nothing }
            Task { await recorder.stop() }
            return "Stopped. I'll write up your notes."
        }
    }

    func refreshClaude() async {
        claude = .checking
        claude = await ClaudeCLI.checkStatus()
    }

    func refreshPermissions() {
        let hadAccessibility = permissions.granted[.accessibility] == true
        permissions.refresh()
        if !hadAccessibility, permissions.granted[.accessibility] == true {
            hotkey.start()
        }
    }

    func checkForUpdates() {
        NSApp.activate()
        updates.checkForUpdates(nil)
    }

    func finishSetup() {
        UserDefaults.standard.set(true, forKey: "setup.finished")
    }
}
