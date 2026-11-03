import AppKit
import SwiftUI

/// A screenshot Case took for you, as a small picture in the bottom right corner, like the Mac's own.
/// Click it to open the file. It stays while the mouse is over it, then slides away.
final class ScreenshotThumbnail: NSPanel {
    private static let width: CGFloat = 220
    private static let edgeGap: CGFloat = 16
    private static let showFor: Duration = .seconds(8)

    private var hiding: Task<Void, Never>?
    private var hovering = false

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 140), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
    }

    override var canBecomeKey: Bool { false }

    func show(_ image: NSImage, file: URL) {
        let height = (Self.width * image.size.height / max(image.size.width, 1)).rounded()
        let card = ThumbnailCard(image: image, name: file.lastPathComponent) { [weak self] in
            NSWorkspace.shared.open(file)
            self?.hide()
        } hover: { [weak self] inside in
            self?.hovering = inside
            if !inside { self?.hideLater() }
        }
        let view = FirstClickHostingView(rootView: card)
        view.sizingOptions = .intrinsicContentSize
        contentView = view
        let size = view.fittingSize
        let visible = (NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main)?.visibleFrame ?? .zero
        let frame = NSRect(x: visible.maxX - Self.edgeGap - size.width, y: visible.minY + Self.edgeGap,
                           width: size.width, height: max(size.height, height))
        // Slides in from the right edge.
        setFrame(frame.offsetBy(dx: size.width + Self.edgeGap, dy: 0), display: true)
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().setFrame(frame, display: true)
        }
        hideLater()
    }

    private func hideLater() {
        hiding?.cancel()
        hiding = Task { [weak self] in
            try? await Task.sleep(for: Self.showFor)
            guard !Task.isCancelled, let self, !hovering else { return }
            hide()
        }
    }

    private func hide() {
        hiding?.cancel()
        guard isVisible else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            animator().setFrame(frame.offsetBy(dx: frame.width + Self.edgeGap, dy: 0), display: true)
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                self?.orderOut(nil)
                self?.contentView = nil
            }
        }
    }
}

private struct ThumbnailCard: View {
    let image: NSImage
    let name: String
    let open: () -> Void
    let hover: (Bool) -> Void

    var body: some View {
        Button(action: open) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 220)
                .clipShape(.rect(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.25)))
        }
        .buttonStyle(.plain)
        .help("Open \(name)")
        .onHover(perform: hover)
    }
}
