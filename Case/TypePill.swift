import AppKit
import SwiftUI

/// The slim one-line box for typing a question, next to the buddy. It takes typing without
/// making Case the active app, so the app you're asking about stays in front for the screenshot.
final class TypePill: NSPanel {
    var onSubmit: (String) -> Void = { _ in }

    private let model = PillModel()
    private static let size = CGSize(width: 320, height: 40)

    init() {
        super.init(contentRect: NSRect(origin: .zero, size: Self.size), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false

        let hosting = NSHostingView(rootView: PillView(model: model) { [weak self] text in
            self?.orderOut(nil)
            self?.onSubmit(text)
        })
        hosting.sizingOptions = []
        contentView = hosting
    }

    override var canBecomeKey: Bool { true }

    /// Esc
    override func cancelOperation(_ sender: Any?) {
        orderOut(nil)
    }

    /// Clicking somewhere else puts it away.
    override func resignKey() {
        super.resignKey()
        orderOut(nil)
    }

    /// Opens to the right of `anchor` (the buddy), or to its left near the screen's right edge.
    func show(near anchor: CGPoint) {
        let visible = (NSScreen.screens.first { $0.frame.contains(anchor) } ?? NSScreen.main)?.visibleFrame ?? .zero
        var x = anchor.x + 22
        if x + Self.size.width > visible.maxX - 8 { x = anchor.x - 22 - Self.size.width }
        let top = min(anchor.y + 20, visible.maxY - 8)
        setFrame(NSRect(x: x, y: max(top - Self.size.height, visible.minY + 8), width: Self.size.width, height: Self.size.height),
                 display: true)
        model.text = ""
        makeKeyAndOrderFront(nil)
        model.focusRequest += 1
    }
}

@Observable
private final class PillModel {
    var text = ""
    var focusRequest = 0
}

private struct PillView: View {
    @Bindable var model: PillModel
    let onSubmit: (String) -> Void

    @FocusState private var focused: Bool

    var body: some View {
        TextField("Ask about your screen…", text: $model.text)
            .textFieldStyle(.plain)
            .font(.system(size: 14, weight: .medium))
            .focused($focused)
            .onSubmit {
                let text = model.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { onSubmit(text) }
            }
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .glassEffect(.regular, in: .capsule)
            .onChange(of: model.focusRequest) { focused = true }
    }
}
