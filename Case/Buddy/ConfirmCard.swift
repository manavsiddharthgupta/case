import AppKit
import SwiftUI

/// The "are you sure?" bar for anything that deletes or buys, and for a message to someone you
/// didn't name. It sits at the bottom middle of the screen, always in the same place, and nothing
/// happens unless you answer yes: by button, by Enter, or by holding the hotkey and saying so.
/// Enter only works after a moment, so a key you were already pressing can't answer it.
final class ConfirmCard: NSPanel {
    nonisolated struct Request: Sendable {
        /// "Delete 3 files from Downloads?"
        var title: String
        /// The message or thing it's about, when there is one.
        var detail: String?
        /// "Send", "Delete", "Click"
        var action: String
        /// What Case will actually do, like "Clicks Delete in Finder".
        var note: String?

        var isDangerous: Bool { ["Delete", "Remove", "Buy", "Pay", "Order"].contains(action) }

        var symbol: String {
            switch action {
            case "Delete", "Remove": "trash"
            case "Buy", "Pay", "Order": "cart"
            case "Send": "paperplane"
            case "Run": "terminal"
            default: "exclamationmark.circle"
            }
        }
    }

    private static let width: CGFloat = 560
    private static let gapAboveDock: CGFloat = 16
    private static let smallestHeight: CGFloat = 80
    private static let enterDelay = Duration.seconds(1)

    private let model = CardModel()
    private var answer: CheckedContinuation<Bool, Never>?
    private var timeout: Task<Void, Never>?
    private var arming: Task<Void, Never>?

    var isAsking: Bool { answer != nil }
    /// Whether the last question ran out of time, rather than being answered.
    private(set) var wentUnanswered = false

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 96), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
    }

    override var canBecomeKey: Bool { true }

    /// Esc
    override func cancelOperation(_ sender: Any?) {
        finish(false)
    }

    /// Shows the bar on the screen holding `anchor` and waits for your answer. Cancelled (say,
    /// Claude stopped waiting), it counts as no.
    func ask(_ request: Request, near anchor: CGPoint) async -> Bool {
        finish(false)
        wentUnanswered = false
        model.request = request
        model.status = .waiting
        model.enterWorks = false
        place(onScreenWith: anchor)
        // Not key yet, so whatever you're typing stays in your app for now.
        orderFrontRegardless()
        arming = Task {
            try? await Task.sleep(for: Self.enterDelay)
            guard !Task.isCancelled else { return }
            model.enterWorks = true
            makeKey()
        }
        // Nobody answered for two minutes: treat it as no.
        timeout = Task {
            try? await Task.sleep(for: .seconds(120))
            guard !Task.isCancelled else { return }
            wentUnanswered = true
            finish(false)
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { answer = $0 }
        } onCancel: {
            Task { @MainActor in self.finish(false) }
        }
    }

    func cancel() {
        finish(false)
    }

    func showListening() {
        model.status = .listening
    }

    /// What you said while holding the hotkey. Anything that isn't clearly yes or no leaves the question up.
    func answer(heard said: String) {
        guard isAsking else { return }
        if let meaning = Self.meaning(of: said) {
            finish(meaning)
        } else {
            model.status = .didNotCatch
        }
    }

    /// No wins over yes, so "no, don't do it" and "yes, wait, no" both stop.
    nonisolated static func meaning(of said: String) -> Bool? {
        let text = " " + said.lowercased().split { !$0.isLetter && $0 != "'" }.joined(separator: " ") + " "
        func has(_ words: [String]) -> Bool { words.contains { text.contains(" \($0) ") } }
        if has(["no", "nope", "nah", "not", "don't", "dont", "cancel", "stop", "wait", "nahi", "mat"]) { return false }
        return has(["yes", "yeah", "yep", "yup", "sure", "ok", "okay", "confirm", "go ahead", "do it", "haan"]) ? true : nil
    }

    private func finish(_ confirmed: Bool) {
        timeout?.cancel()
        arming?.cancel()
        orderOut(nil)
        answer?.resume(returning: confirmed)
        answer = nil
    }

    private func place(onScreenWith anchor: CGPoint) {
        // A new view each time: an existing one can't measure content it hasn't drawn yet,
        // and a bar with no height is a question nobody can see.
        let view = FirstClickHostingView(rootView: CardView(model: model) { [weak self] in self?.finish($0) })
        view.sizingOptions = .intrinsicContentSize
        contentView = view
        let height = max(view.fittingSize.height, Self.smallestHeight)
        let visible = (NSScreen.screens.first { $0.frame.contains(anchor) } ?? NSScreen.main)?.visibleFrame ?? .zero
        setFrame(NSRect(x: visible.midX - Self.width / 2, y: visible.minY + Self.gapAboveDock, width: Self.width, height: height),
                 display: true)
    }
}

/// So the first click on a button counts, even though the bar isn't the active window.
private final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@Observable
private final class CardModel {
    enum Status { case waiting, listening, didNotCatch }

    var request: ConfirmCard.Request?
    var status = Status.waiting
    var enterWorks = false

    var hint: String {
        switch status {
        case .waiting: "Or hold ⌥⌘ and say yes or no"
        case .listening: "Listening…"
        case .didNotCatch: "I didn't catch that. Hold ⌥⌘ and say yes or no"
        }
    }
}

private struct CardView: View {
    let model: CardModel
    let onAnswer: (Bool) -> Void

    var body: some View {
        Group {
            if let request = model.request {
                HStack(spacing: 14) {
                    Image(systemName: request.symbol)
                        .font(.system(size: 20))
                        .foregroundStyle(request.isDangerous ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                        .frame(width: 26)
                    VStack(alignment: .leading, spacing: 3) {
                        // Never cut short: this is what you're agreeing to.
                        Text(request.title)
                            .font(.system(size: 14, weight: .semibold))
                        if let note = request.note {
                            Text(note)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        if let detail = request.detail, !detail.isEmpty {
                            Text("“\(detail)”")
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        Text(model.hint)
                            .font(.system(size: 11))
                            .foregroundStyle(model.status == .waiting ? .tertiary : .secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    Button("Cancel") { onAnswer(false) }
                        .keyboardShortcut(.cancelAction)
                    Button(model.enterWorks ? "\(request.action)  ⏎" : request.action) { onAnswer(true) }
                        .keyboardShortcut(model.enterWorks ? .defaultAction : nil)
                        .buttonStyle(AnswerButtonStyle(isDangerous: request.isDangerous))
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
                .frame(width: 560)
                // Behind the content, not around it: glass drains the red out of what it holds.
                .background { Color.clear.glassEffect(.regular, in: .rect(cornerRadius: 18)) }
            }
        }
    }
}

/// Drawn by hand, because macOS turns the standard prominent button grey while the bar isn't
/// the active window, and it stays that way for the first moment on purpose.
private struct AnswerButtonStyle: ButtonStyle {
    let isDangerous: Bool
    @Environment(\.colorScheme) private var colorScheme

    func makeBody(configuration: Configuration) -> some View {
        let plain = colorScheme == .dark ? Color.white : Color.black
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(isDangerous || colorScheme == .light ? Color.white : Color.black)
            .padding(.horizontal, 14)
            .frame(height: 28)
            .background(isDangerous ? Color.red : plain, in: .rect(cornerRadius: 8))
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}
