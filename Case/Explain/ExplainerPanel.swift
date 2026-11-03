import AppKit
import SceneKit
import SwiftUI

/// The floating panel for a 3D explanation: the scene turns slowly, labels sit at the sides with lines
/// to what they name, and you can drag to turn it yourself. It stays until Esc, its close button,
/// or the next question.
final class ExplainerPanel: NSPanel {
    private static let size = CGSize(width: 600, height: 430)
    private static let gap: CGFloat = 28
    private static let edgeGap: CGFloat = 12

    init() {
        super.init(contentRect: NSRect(origin: .zero, size: Self.size), styleMask: [.borderless, .nonactivatingPanel],
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

    /// Beside `anchor` (AppKit coordinates), on whichever side has room.
    func show(_ description: Scene3D, near anchor: CGPoint) {
        let view = FirstClickHostingView(rootView: ExplainerView(builder: SceneBuilder(description), title: description.title,
                                                                 labels: description.labels ?? [],
                                                                 close: { [weak self] in self?.hide() }))
        contentView = view
        let visible = (NSScreen.screens.first { $0.frame.contains(anchor) } ?? NSScreen.main)?.visibleFrame ?? .zero
        let size = Self.size
        let x = anchor.x + Self.gap + size.width <= visible.maxX - Self.edgeGap
            ? anchor.x + Self.gap
            : max(anchor.x - Self.gap - size.width, visible.minX + Self.edgeGap)
        let y = min(max(anchor.y - size.height / 2, visible.minY + Self.edgeGap), visible.maxY - Self.edgeGap - size.height)
        setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
        alphaValue = 0
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.2; animator().alphaValue = 1 }
    }

    func hide() {
        guard isVisible else { return }
        orderOut(nil)
        // Nothing keeps rendering once it's gone.
        contentView = nil
    }
}

private struct ExplainerView: View {
    let builder: SceneBuilder
    let title: String?
    let labels: [Scene3D.Label]
    let close: () -> Void

    @State private var tracker = AnchorTracker()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title ?? "")
                    .font(Theme.font(16, weight: .medium))
                    .tracking(-0.3)
                    .lineLimit(1)
                Spacer()
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 24, height: 24)
                        .background(.white.opacity(0.1), in: .circle)
                }
                .buttonStyle(.plain)
                .help("Close")
            }
            .padding(.horizontal, 18)
            .padding(.top, 14)

            GeometryReader { proxy in
                ZStack {
                    SceneView(builder: builder, tracker: tracker)
                    TimelineView(.animation) { _ in
                        Callouts(points: tracker.points(for: labels.map(\.part), in: proxy.size), labels: labels, size: proxy.size)
                    }
                    .allowsHitTesting(false)
                }
            }

            Text("Drag to turn · Esc to close")
                .font(Theme.font(11))
                .foregroundStyle(.white.opacity(0.45))
                .padding(.bottom, 10)
        }
        .foregroundStyle(.white)
        .frame(width: 600, height: 430)
        .background(Color(white: 0.09), in: .rect(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(.white.opacity(0.1)))
        .environment(\.colorScheme, .dark)
    }
}

/// Finds where each part shows in the 3D view, every frame, so the label lines follow it as it turns.
@MainActor
private final class AnchorTracker {
    weak var view: SCNView?
    var anchors: [String: SCNNode] = [:]
    /// Which side each label sits on, chosen the first time it's seen, so labels don't jump across as it turns.
    private var onLeft: [String: Bool] = [:]

    /// Positions in the view, top-left origin, and the label's side. Nil until the scene has been drawn.
    func points(for parts: [String], in size: CGSize) -> [(point: CGPoint, onLeft: Bool)?] {
        guard let view else { return parts.map { _ in nil } }
        return parts.map { id in
            guard let node = anchors[id] else { return nil }
            let projected = view.projectPoint(node.presentation.worldPosition)
            guard projected.z > 0, projected.z < 1 else { return nil }
            let point = CGPoint(x: projected.x, y: size.height - projected.y)
            let left = onLeft[id] ?? (point.x < size.width / 2)
            onLeft[id] = left
            return (point, left)
        }
    }
}

private struct SceneView: NSViewRepresentable {
    let builder: SceneBuilder
    let tracker: AnchorTracker

    func makeNSView(context: Context) -> SCNView {
        let view = SCNView(frame: .zero)
        view.backgroundColor = .clear
        view.antialiasingMode = .multisampling4X
        view.scene = builder.scene
        view.pointOfView = builder.camera
        view.allowsCameraControl = true
        view.defaultCameraController.interactionMode = .orbitTurntable
        view.defaultCameraController.inertiaEnabled = true
        view.isPlaying = true
        tracker.view = view
        tracker.anchors = builder.anchors
        return view
    }

    func updateNSView(_ view: SCNView, context: Context) {}
}

/// The labels down each side, with a line and a dot on what each one names.
private struct Callouts: View {
    let points: [(point: CGPoint, onLeft: Bool)?]
    let labels: [Scene3D.Label]
    let size: CGSize

    private static let column: CGFloat = 132
    private static let margin: CGFloat = 16
    private static let spacing: CGFloat = 34

    var body: some View {
        let placed = layout()
        ZStack(alignment: .topLeading) {
            Canvas { context, _ in
                for item in placed {
                    var line = Path()
                    line.move(to: item.lineStart)
                    line.addLine(to: item.anchor)
                    context.stroke(line, with: .color(.white.opacity(0.75)), lineWidth: 1.5)
                    let dot = CGRect(x: item.anchor.x - 4, y: item.anchor.y - 4, width: 8, height: 8)
                    context.fill(Path(ellipseIn: dot), with: .color(.white))
                    context.stroke(Path(ellipseIn: dot), with: .color(.black.opacity(0.5)), lineWidth: 1)
                }
            }
            ForEach(placed.indices, id: \.self) { index in
                let item = placed[index]
                Text(item.text)
                    .font(Theme.font(14, weight: .medium))
                    .multilineTextAlignment(item.onLeft ? .trailing : .leading)
                    .lineLimit(2)
                    .shadow(color: .black.opacity(0.6), radius: 3)
                    .frame(width: Self.column, alignment: item.onLeft ? .trailing : .leading)
                    .position(x: item.onLeft ? Self.margin + Self.column / 2 : size.width - Self.margin - Self.column / 2, y: item.y)
            }
        }
        .frame(width: size.width, height: size.height)
    }

    private struct Placed {
        let text: String
        let anchor: CGPoint
        let onLeft: Bool
        var y: CGFloat
        /// Where the line leaves the label, just past its edge.
        let lineX: CGFloat
        var lineStart: CGPoint { CGPoint(x: lineX, y: y) }
    }

    /// Each label goes on the side its part is on, level with it, pushed apart so none overlap.
    private func layout() -> [Placed] {
        var placed: [Placed] = []
        let inner = Self.margin + Self.column + 6
        for (label, found) in zip(labels, points) {
            guard let found else { continue }
            placed.append(Placed(text: label.text, anchor: found.point, onLeft: found.onLeft, y: found.point.y,
                                 lineX: found.onLeft ? inner : size.width - inner))
        }
        for onLeft in [true, false] {
            let side = placed.indices.filter { placed[$0].onLeft == onLeft }.sorted { placed[$0].anchor.y < placed[$1].anchor.y }
            var next = Self.spacing / 2
            for index in side {
                placed[index].y = max(placed[index].y, next)
                next = placed[index].y + Self.spacing
            }
            // If that ran off the bottom, slide the whole side back up.
            if let last = side.last, placed[last].y > size.height - Self.spacing / 2 {
                let overflow = placed[last].y - (size.height - Self.spacing / 2)
                for index in side { placed[index].y = max(placed[index].y - overflow, Self.spacing / 2) }
            }
        }
        return placed
    }
}
