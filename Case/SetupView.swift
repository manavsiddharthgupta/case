import AppKit
import SwiftUI

/// First-run setup, one step at a time: Claude Code, the Mac permissions, the voice, then how to
/// use Case. It opens at the first thing still to do, and from the menu that's the accent.
struct SetupView: View {
    enum Step: Int, CaseIterable {
        case claude, permissions, voice, ready
    }

    /// Where Apple's speech model has got to.
    enum Hearing: Equatable {
        case checking
        case downloading
        case ready
        case failed(String)
    }

    @Environment(AppModel.self) private var model
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openWindow) private var openWindow
    @State var step = Step.claude
    @State var hearing = Hearing.checking
    @State private var isPlaced = false

    /// Where to open. Once Claude Code and the permissions are done, only the voice step is left.
    static func firstStep(claude: ClaudeCLI.Status, allGranted: Bool) -> Step {
        guard case .connected = claude else { return .claude }
        return allGranted ? .voice : .permissions
    }

    var body: some View {
        HStack(spacing: 0) {
            StepList(step: step)
            Rule(vertical: true)

            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 8) {
                    PageTitle(step.title)
                    Text(step.detail)
                        .foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.bottom, 24)

                Group {
                    switch step {
                    case .claude: ClaudeStep()
                    case .permissions: PermissionsStep()
                    case .voice: VoiceStep(hearing: $hearing)
                    case .ready: ReadyStep()
                    }
                }
                .id(step)
                .transition(.opacity)

                Spacer(minLength: 16)
                footer
            }
            .padding(.horizontal, 36)
            .padding(.top, 52)
            .padding(.bottom, 28)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Theme.background)
            .animation(.easeOut(duration: 0.2), value: step)
        }
        .font(Theme.font(14))
        .foregroundStyle(Theme.foreground)
        .frame(width: 780, height: 560)
        .background(Theme.background)
        .ignoresSafeArea()
        .onAppear { NSApp.activate() }
        // Only once: after that the steps are yours to move through.
        .onChange(of: model.claude, initial: true) {
            guard !isPlaced, model.claude != .checking else { return }
            isPlaced = true
            step = Self.firstStep(claude: model.claude, allGranted: model.permissions.allGranted)
        }
        // Permissions are switched on in System Settings, so keep checking while this window is open.
        .task {
            while !Task.isCancelled {
                model.refreshPermissions()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private var footer: some View {
        HStack {
            if let back = Step(rawValue: step.rawValue - 1) {
                Button("Back") { step = back }
                    .buttonStyle(PillButtonStyle())
            }
            Spacer()
            if step == .voice, case .failed = hearing {
                Button("Skip for now") { step = .ready }
                    .buttonStyle(PillButtonStyle())
            }
            Button(step == .ready ? "Start using Case" : "Continue", action: moveOn)
                .buttonStyle(PillButtonStyle(filled: true))
                .keyboardShortcut(.defaultAction)
                .disabled(!canMoveOn)
                .opacity(canMoveOn ? 1 : 0.3)
        }
    }

    private var canMoveOn: Bool {
        switch step {
        case .claude:
            if case .connected = model.claude { true } else { false }
        case .permissions: model.permissions.allGranted
        case .voice: hearing == .ready
        case .ready: true
        }
    }

    private func moveOn() {
        if let next = Step(rawValue: step.rawValue + 1) {
            step = next
        } else {
            model.finishSetup()
            openWindow(id: "main")
            dismissWindow(id: "setup")
        }
    }
}

private extension SetupView.Step {
    var name: String {
        switch self {
        case .claude: "Claude Code"
        case .permissions: "Permissions"
        case .voice: "Voice"
        case .ready: "Ready"
        }
    }

    var title: String {
        switch self {
        case .claude: "Connect Claude Code"
        case .permissions: "Allow Mac permissions"
        case .voice: "Choose your accent"
        case .ready: "You're all set"
        }
    }

    var detail: String {
        switch self {
        case .claude: "Case runs on Claude Code, using your own Claude plan. Codex is coming soon."
        case .permissions: "Case needs these to see your screen, hear you, and work on your Mac."
        case .voice: "Pick the closest one, so Case hears you better. Your voice stays on your Mac."
        case .ready: "Case lives in your menu bar, and it learns about you as you talk."
        }
    }
}

/// The left side: the same look as the main window's sidebar.
private struct StepList: View {
    let step: SetupView.Step

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                MarkGlyph(size: 18, color: Theme.foreground)
                Text("Case")
                    .font(Theme.font(16, weight: .medium))
                    .tracking(-0.3)
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 24)

            ForEach(SetupView.Step.allCases, id: \.self) { item in
                StepRow(item: item, current: step)
            }

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.top, 52)
        .frame(width: 210)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.card)
    }
}

private struct StepRow: View {
    let item: SetupView.Step
    let current: SetupView.Step

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                if item.rawValue < current.rawValue {
                    StatusCheck(size: 18)
                } else {
                    Circle()
                        .strokeBorder(item.rawValue > current.rawValue ? Theme.ghost : Theme.foreground, lineWidth: 1)
                    Text("\(item.rawValue + 1)")
                        .font(Theme.font(11, weight: .medium))
                }
            }
            .frame(width: 20, height: 20)

            Text(item.name)
                .font(Theme.font(14, weight: item == current ? .medium : .regular))
            Spacer()
        }
        .foregroundStyle(item.rawValue > current.rawValue ? Theme.muted : Theme.foreground)
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(item == current ? Theme.pill : .clear, in: .rect(cornerRadius: 8))
    }
}

/// A rounded panel with a thin edge, for what each step asks.
private struct SetupCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .background(Theme.card, in: .rect(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border))
    }
}

private struct ClaudeStep: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        SetupCard {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "terminal")
                    .font(.system(size: 16))
                    .frame(width: 24, height: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.claude.summary)
                        .font(Theme.font(14, weight: .medium))
                    if let hint = model.claude.hint {
                        Text(hint)
                            .font(Theme.font(12))
                            .foregroundStyle(Theme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(minHeight: 30)
                Spacer()
                switch model.claude {
                case .checking:
                    ProgressView().controlSize(.small).frame(height: 30)
                case .connected:
                    StatusCheck().frame(height: 30)
                case .notInstalled, .signedOut, .failed:
                    Button("Check again") { Task { await model.refreshClaude() } }
                        .buttonStyle(PillButtonStyle())
                }
            }
            .padding(14)

            if model.claude == .signedOut {
                Rule()
                CommandRow(command: "claude auth login")
            }
            if model.claude == .notInstalled {
                Rule()
                HStack {
                    Text("Needs a paid Claude plan.")
                        .font(Theme.font(12))
                        .foregroundStyle(Theme.muted)
                    Spacer()
                    Link("Get Claude Code", destination: URL(string: "https://claude.com/claude-code")!)
                        .buttonStyle(PillButtonStyle())
                }
                .padding(14)
            }
        }
    }
}

/// Something to paste into Terminal.
private struct CommandRow: View {
    let command: String
    @State private var copied = false

    var body: some View {
        HStack {
            Text(command)
                .font(.system(size: 13, design: .monospaced))
                .textSelection(.enabled)
            Spacer()
            Button(copied ? "Copied" : "Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
                copied = true
            }
            .buttonStyle(PillButtonStyle())
        }
        .padding(14)
    }
}

private struct PermissionsStep: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SetupCard {
                ForEach(Permissions.Kind.allCases) { kind in
                    PermissionRow(kind: kind)
                    if kind != Permissions.Kind.allCases.last {
                        Rule()
                    }
                }
            }

            Text("macOS may ask you to reopen Case after Screen Recording. If it stays unticked, quit Case from the menu bar and open it again.")
                .font(Theme.font(12))
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct PermissionRow: View {
    @Environment(AppModel.self) private var model
    let kind: Permissions.Kind

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: kind.symbol)
                .font(.system(size: 16))
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(kind.title)
                    .font(Theme.font(14, weight: .medium))
                Text(kind.reason)
                    .font(Theme.font(12))
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if model.permissions.granted[kind] == true {
                StatusCheck().frame(height: 30)
            } else {
                Button("Allow") { Task { await model.permissions.request(kind) } }
                    .buttonStyle(PillButtonStyle())
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }
}

/// The accent, and Apple's speech model, which Case can't hear you without.
private struct VoiceStep: View {
    @Binding var hearing: SetupView.Hearing
    @State private var accent = VoiceInput.accent
    @State private var attempt = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                ForEach(VoiceInput.accents, id: \.id) { option in
                    Button { accent = option.id } label: {
                        Text(option.name).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(PillButtonStyle(filled: option.id == accent))
                }
            }

            SetupCard {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(status)
                            .font(Theme.font(14, weight: .medium))
                        if hearing == .downloading {
                            Text("This usually takes a minute or two.")
                                .font(Theme.font(12))
                                .foregroundStyle(Theme.muted)
                        }
                        if case .failed(let problem) = hearing {
                            Text("\(problem) This step needs the internet.")
                                .font(Theme.font(12))
                                .foregroundStyle(Theme.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer()
                    switch hearing {
                    case .checking, .downloading:
                        ProgressView().controlSize(.small)
                    case .ready:
                        StatusCheck()
                    case .failed:
                        Button("Try again") { attempt += 1 }
                            .buttonStyle(PillButtonStyle())
                    }
                }
                .padding(14)
            }
        }
        .task(id: "\(accent) \(attempt)") { await install() }
    }

    private var status: String {
        switch hearing {
        case .checking: "Checking Apple's speech model…"
        case .downloading: "Downloading Apple's speech model…"
        case .ready: "Ready to hear you"
        case .failed: "Couldn't download Apple's speech model"
        }
    }

    private func install() async {
        VoiceInput.accent = accent
        hearing = .checking
        do {
            try await VoiceInput.installModel { hearing = .downloading }
            if !Task.isCancelled { hearing = .ready }
        } catch {
            if !Task.isCancelled { hearing = .failed(error.localizedDescription) }
        }
    }
}

private struct ReadyStep: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SetupCard {
                HowToRow(action: "Hold", keys: ["⌥", "⌘"], detail: "Talk to Case, then let go.")
                Rule()
                HowToRow(action: "Tap", keys: ["⌥", "⌘"], detail: "Type a question instead.")
                Rule()
                HowToRow(action: "Press", keys: ["esc"], detail: "Stop what Case is doing.")
            }

            // Kokoro carries on downloading by itself, and Case switches to it when it's ready.
            let voice = model.assistant.speaker.voiceStatus
            if !voice.isEmpty {
                Text(voice.hasPrefix("Getting") ? "\(voice). Case uses Apple's voice until then, so you can start now." : "\(voice).")
                    .font(Theme.font(12))
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct HowToRow: View {
    let action: String
    let keys: [String]
    let detail: String

    var body: some View {
        HStack(spacing: 6) {
            Text(action)
                .font(Theme.font(14, weight: .medium))
                .frame(width: 46, alignment: .leading)
            ForEach(keys, id: \.self) { key in
                Text(key)
                    .font(Theme.font(12, weight: .medium))
                    .frame(minWidth: 24, minHeight: 24)
                    .padding(.horizontal, key.count > 1 ? 4 : 0)
                    .background(Theme.pill, in: .rect(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.border))
            }
            Spacer()
            Text(detail)
                .foregroundStyle(Theme.muted)
        }
        .padding(14)
    }
}

private struct StatusCheck: View {
    var size: CGFloat = 19

    var body: some View {
        Image(systemName: "checkmark.seal.fill")
            .font(.system(size: size))
            .foregroundStyle(Theme.foreground)
    }
}
