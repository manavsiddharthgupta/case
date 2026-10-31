import SwiftUI

/// The menu under the ✦ icon in the menu bar.
struct MenuView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(model.claude.summary)

        if !model.permissions.allGranted {
            Text("Some permissions are missing")
        }

        Divider()

        Button("Open Case") { open(.chats) }
        if model.recorder.isCapturing {
            if model.recorder.phase == .paused {
                Button("Resume meeting notes") { Task { await model.recorder.resume() } }
            } else {
                Button("Pause meeting notes") { Task { await model.recorder.pause() } }
            }
            Button("Stop meeting notes") { Task { await model.recorder.stop() } }
        } else {
            Button("Start meeting notes") {
                open(.meetings)
                Task { await model.recorder.start() }
            }
            .disabled(model.recorder.isActive)
        }

        Divider()

        Button("Type a question   ⌥⌘") { model.assistant.openTyping() }
        Button("Copy last answer") { model.assistant.copyLastAnswer() }
            .disabled(model.assistant.answer.isEmpty)
        Button("New chat") { model.assistant.newChat() }
        Toggle("Show buddy", isOn: Binding(
            get: { model.assistant.pointer.isEnabled },
            set: { model.assistant.pointer.isEnabled = $0 }
        ))
        Picker("Voice", selection: Binding(
            get: { model.assistant.speaker.voice },
            set: { model.assistant.speaker.voice = $0 }
        )) {
            if KokoroEngine.isAvailable {
                ForEach(KokoroEngine.voices, id: \.id) { Text($0.name).tag($0.id) }
                Divider()
            }
            Text("Apple voice").tag("aman")
        }
        if !model.assistant.speaker.voiceStatus.isEmpty {
            Text(model.assistant.speaker.voiceStatus)
        }
        Toggle("Speak answers", isOn: Binding(
            get: { !model.assistant.speaker.isMuted },
            set: { model.assistant.speaker.isMuted = !$0 }
        ))

        Divider()

        Button("Setup…") {
            NSApp.activate()
            openWindow(id: "setup")
        }

        Divider()

        Button("Quit Case") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func open(_ page: AppModel.Page) {
        model.page = page
        NSApp.activate()
        openWindow(id: "main")
    }
}

extension ClaudeCLI.Status {
    var summary: String {
        switch self {
        case .checking: "Checking Claude Code…"
        case .notInstalled: "Claude Code not found"
        case .signedOut: "Claude Code is signed out"
        case .connected(let plan): ["Claude Code connected", plan?.capitalized].compactMap { $0 }.joined(separator: " · ")
        case .failed: "Couldn't check Claude Code"
        }
    }

    /// What to do next, when something is wrong.
    var hint: String? {
        switch self {
        case .notInstalled: "Install Claude Code from claude.com/claude-code, then check again."
        case .signedOut: "Run this in Terminal, then check again."
        case .failed(let message): message
        case .checking, .connected: nil
        }
    }
}
