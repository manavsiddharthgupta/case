import AppKit
import SwiftUI

/// The "are you sure?" card for anything that sends, posts, deletes or buys. It appears beside
/// the cursor; Enter confirms and Esc cancels. Nothing happens unless you confirm.
final class ConfirmCard: NSPanel {
    nonisolated struct Request: Sendable {
        /// "Send in WhatsApp?"
        var title: String
        /// The message or thing it's about, when there is one.
        var detail: String?
        /// "Send", "Delete", "Click"
        var action: String
    }

    private let model = CardModel()
    private var answer: CheckedContinuation<Bool, Never>?
    private var timeout: Task<Void, Never>?

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 340, height: 120), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false

        let hosting = NSHostingView(rootView: CardView(model: model) { [weak self] confirmed in self?.finish(confirmed) })
        hosting.sizingOptions = []
        contentView = hosting
    }

    override var canBecomeKey: Bool { true }

    /// Esc
    override func cancelOperation(_ sender: Any?) {
        finish(false)
    }

    /// Shows the card near `anchor` and waits for your answer. Cancelled (say, Claude stopped waiting),
    /// it counts as no.
    func ask(_ request: Request, near anchor: CGPoint) async -> Bool {
        finish(false)
        model.request = request
        place(near: anchor)
        makeKeyAndOrderFront(nil)
        // Nobody answered for two minutes: treat it as no.
        timeout = Task {
            try? await Task.sleep(for: .seconds(120))
            if !Task.isCancelled { finish(false) }
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

    private func finish(_ confirmed: Bool) {
        timeout?.cancel()
        orderOut(nil)
        answer?.resume(returning: confirmed)
        answer = nil
    }

    private func place(near anchor: CGPoint) {
        let size = CGSize(width: 340, height: model.request?.detail == nil ? 92 : 132)
        let visible = (NSScreen.screens.first { $0.frame.contains(anchor) } ?? NSScreen.main)?.visibleFrame ?? .zero
        var x = anchor.x + 22
        if x + size.width > visible.maxX - 8 { x = anchor.x - 22 - size.width }
        let top = min(anchor.y + 20, visible.maxY - 8)
        setFrame(NSRect(x: x, y: max(top - size.height, visible.minY + 8), width: size.width, height: size.height), display: true)
    }
}

@Observable
private final class CardModel {
    var request: ConfirmCard.Request?
}

private struct CardView: View {
    let model: CardModel
    let onAnswer: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let request = model.request {
                Text(request.title)
                    .font(.system(size: 14, weight: .semibold))
                if let detail = request.detail, !detail.isEmpty {
                    Text("“\(detail)”")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                HStack {
                    Spacer()
                    Button("Cancel") { onAnswer(false) }
                        .keyboardShortcut(.cancelAction)
                    Button("\(request.action)  ⏎") { onAnswer(true) }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
    }
}
