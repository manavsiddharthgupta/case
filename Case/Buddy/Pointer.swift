import AppKit
import SwiftUI

/// Somewhere to point: the real size of what's there (`exact`), or just a spot Claude estimated.
nonisolated struct Spot: Sendable {
    let rect: CGRect
    let exact: Bool
    /// What's there, to check again just before it's marked.
    var item: ScreenElement?
    /// How it was found, for the log.
    var why = ""
}

/// The buddy: a small arrow that trails your cursor, shows when it's listening, thinking or talking,
/// and flies to whatever Claude points at. It stays there while that's being explained, even if
/// you move the mouse, and flies back to the cursor once the explanation is over.
@Observable
final class Pointer {
    enum Activity {
        case idle, listening, thinking, speaking
    }

    var isEnabled = UserDefaults.standard.object(forKey: "pointer.enabled") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: "pointer.enabled")
            updateVisibility()
        }
    }

    /// The small bubble beside the buddy: your words while you talk, then the answer.
    struct Caption: Equatable {
        enum Kind {
            /// `status` is a quiet note like "Working on it…".
            case heard, answer, problem, status
        }

        var text: String
        var kind: Kind
    }

    /// What the assistant is doing. Read by the buddy's view, so it redraws when that changes.
    @ObservationIgnored var activity: () -> Activity = { .idle }
    private(set) var caption: Caption?
    /// How loud you are while talking, 0…1, for the voice wave.
    var level: Double = 0
    /// Where the buddy is, for placing the typing pill beside it.
    var anchor: CGPoint { position }
    private(set) var isFlying = false
    /// A quick press when Case clicks something.
    private(set) var isPressing = false
    /// Which way the arrow points, in degrees clockwise from straight up.
    private(set) var heading = Pointer.restingHeading

    /// Up and to the left, like the cursor it sits beside.
    private static let restingHeading: Double = -45
    private static let cursorOffset = CGVector(dx: 20, dy: -20)

    @ObservationIgnored private lazy var buddy = OverlayPanel(size: CGSize(width: 56, height: 56), content: BuddyView(pointer: self))
    @ObservationIgnored private lazy var highlight = OverlayPanel(size: .zero, content: EmptyView())
    @ObservationIgnored private lazy var captionPanel = OverlayPanel(size: CGSize(width: 324, height: 40), content: CaptionView(pointer: self))
    @ObservationIgnored private var captionSize = CGSize.zero
    @ObservationIgnored private var captionFade: Task<Void, Never>?
    @ObservationIgnored private var monitors: [Any] = []
    /// Where it waits beside the target while that's being explained.
    @ObservationIgnored private var parkedAt: CGPoint?
    @ObservationIgnored private var returnTask: Task<Void, Never>?
    @ObservationIgnored private var ignoreClicksUntil = ContinuousClock.now
    @ObservationIgnored private var landing: CheckedContinuation<Void, Never>?
    @ObservationIgnored private var position = NSEvent.mouseLocation
    @ObservationIgnored private var glide: Task<Void, Never>?
    @ObservationIgnored private var flight: Task<Void, Never>?

    func start() {
        let moves: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged]
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: moves, handler: { [weak self] _ in self?.mouseMoved() }) {
            monitors.append(monitor)
        }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: moves, handler: { [weak self] event in
            self?.mouseMoved()
            return event
        }) {
            monitors.append(monitor)
        }
        // A click anywhere means you've found it (but not Case's own clicks).
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown, handler: { [weak self] _ in
            guard let self, ContinuousClock.now > ignoreClicksUntil else { return }
            hideHighlight()
        }) {
            monitors.append(monitor)
        }
        position = goal
        buddy.setCenter(position)
        updateVisibility()
    }

    /// Flies to the target and marks it. `exact` means we know the element's real frame;
    /// otherwise it's Claude's estimate from the screenshot, so we mark a spot instead of a box.
    func point(at target: CGRect, exact: Bool) {
        showHighlight(exact ? .outline(target) : .spot(CGPoint(x: target.midX, y: target.midY)))
        fly(beside: target, exact: exact)
    }

    private func fly(beside target: CGRect, exact: Bool) {
        guard isEnabled else { return }
        let center = CGPoint(x: target.midX, y: target.midY)

        // Land just below and to the right, aiming at the middle of the target.
        let reach = exact ? CGPoint(x: target.maxX, y: target.minY) : center
        let visible = (NSScreen.screens.first { $0.frame.contains(center) } ?? NSScreen.main)?.visibleFrame ?? target
        let landing = CGPoint(x: min(reach.x + 16, visible.maxX - 20), y: max(reach.y - 16, visible.minY + 20))

        parkedAt = nil
        fly(to: { landing }) { [weak self] in
            self?.parkedAt = landing
            self?.turn(to: Self.angle(of: CGVector(dx: center.x - landing.x, dy: center.y - landing.y)))
            self?.landing?.resume()
            self?.landing = nil
        }
        // A safety net, in case the end of the explanation never arrives.
        scheduleReturn(after: .seconds(45))
    }

    /// Takes Case's floating windows off the screen for a moment, so looking up what's under
    /// a spot finds the app below, not the buddy or the outline.
    func withOverlaysHidden<T>(_ body: () -> T) -> T {
        let shown = [buddy, captionPanel, highlight].filter(\.isVisible)
        shown.forEach { $0.orderOut(nil) }
        defer { shown.forEach { $0.orderFrontRegardless() } }
        return body()
    }

    /// For Case's own clicks: flies to the spot, lands, and presses. Returns once it has landed.
    /// Marks are for explaining, so a click gets none; what it clicks may change the screen anyway.
    func tap(at target: CGRect) async {
        ignoreClicksUntil = .now + .seconds(2)
        hideHighlight()
        fly(beside: target, exact: target.width > 0 && target.width <= 360 && target.height <= 120)
        if isEnabled {
            await withCheckedContinuation { continuation in
                landing?.resume()
                landing = continuation
            }
        }
        withAnimation(.easeOut(duration: 0.1)) { isPressing = true }
        try? await Task.sleep(for: .milliseconds(140))
        withAnimation(.spring(duration: 0.25, bounce: 0.4)) { isPressing = false }
    }

    /// The explanation is over: after a short pause, fly back to the cursor.
    func finishPointing(after pause: Duration = .seconds(1.2)) {
        scheduleReturn(after: pause)
    }

    private func scheduleReturn(after pause: Duration) {
        returnTask?.cancel()
        returnTask = Task {
            try? await Task.sleep(for: pause)
            // Let a flight that's still on its way land first.
            while isFlying, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
            }
            guard !Task.isCancelled else { return }
            hideHighlight()
            guard parkedAt != nil else { return }
            parkedAt = nil
            fly(to: { self.goal }) {
                self.turn(to: Self.restingHeading)
                self.moveToGoal()
            }
        }
    }

    /// Flies along a curve that lifts in the middle, like a thrown ball, turning to face where it's going.
    /// `destination` is asked every frame, so flying back can follow a cursor that's moving.
    private func fly(to destination: @escaping () -> CGPoint, landed: @escaping () -> Void) {
        glide?.cancel()
        flight?.cancel()
        // A tap waiting on a flight that's being replaced shouldn't wait forever.
        landing?.resume()
        landing = nil
        isFlying = true
        let start = position
        let first = destination()
        let distance = hypot(first.x - start.x, first.y - start.y)
        let duration = 0.5 + min(0.35, distance / 3000)

        flight = Task {
            let began = ContinuousClock.now
            while !Task.isCancelled {
                let end = destination()
                let control = CGPoint(x: (start.x + end.x) / 2, y: max(start.y, end.y) + min(140, distance * 0.3))
                let progress = min(1, (ContinuousClock.now - began) / .seconds(duration))
                let eased = progress < 0.5 ? 4 * pow(progress, 3) : 1 - pow(-2 * progress + 2, 3) / 2
                let direction = Self.tangent(start, control, end, eased)
                if hypot(direction.dx, direction.dy) > 1 { setHeading(Self.angle(of: direction)) }
                place(at: Self.curve(start, control, end, eased))
                if progress >= 1 { break }
                try? await Task.sleep(for: .milliseconds(8))
            }
            guard !Task.isCancelled else { return }
            isFlying = false
            landed()
        }
    }

    // MARK: Caption

    func setCaption(_ caption: Caption?) {
        captionFade?.cancel()
        self.caption = caption
        if caption == nil {
            captionPanel.orderOut(nil)
        } else {
            placeCaption()
            captionPanel.orderFrontRegardless()
            if isEnabled { buddy.orderFrontRegardless() }
        }
    }

    /// Lets the caption stay up long enough to finish reading, then removes it.
    func fadeCaption(after delay: Duration) {
        captionFade?.cancel()
        captionFade = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            caption = nil
            captionPanel.orderOut(nil)
        }
    }

    fileprivate func captionResized(_ size: CGSize) {
        captionSize = size
        placeCaption()
    }

    /// To the right of the buddy, or to its left near the screen's right edge.
    private func placeCaption() {
        guard caption != nil, captionSize.width > 0 else { return }
        let visible = (NSScreen.screens.first { $0.frame.contains(position) } ?? NSScreen.main)?.visibleFrame ?? .zero
        var x = position.x + 22
        if x + captionSize.width > visible.maxX - 8 { x = position.x - 22 - captionSize.width }
        let top = min(position.y + 12, visible.maxY - 8)
        let y = max(top - captionSize.height, visible.minY + 8)
        captionPanel.setFrame(NSRect(x: x.rounded(), y: y.rounded(), width: captionSize.width, height: captionSize.height), display: true)
    }

    func hideHighlight() {
        highlight.orderOut(nil)
    }

    // MARK: Following

    private var goal: CGPoint {
        if let parkedAt { return parkedAt }
        let mouse = NSEvent.mouseLocation
        return CGPoint(x: mouse.x + Self.cursorOffset.dx, y: mouse.y + Self.cursorOffset.dy)
    }

    /// While it's pointing at something, moving the mouse doesn't pull it away.
    private func mouseMoved() {
        guard parkedAt == nil else { return }
        moveToGoal()
    }

    /// Eases toward the goal each frame, so it trails the cursor smoothly instead of jumping.
    private func moveToGoal() {
        guard !isFlying, glide == nil else { return }
        glide = Task {
            defer { glide = nil }
            var last = ContinuousClock.now
            while !Task.isCancelled, !isFlying {
                let now = ContinuousClock.now
                let frames = min((now - last) / .milliseconds(16), 6)
                last = now
                let target = goal
                let ease = 1 - pow(1 - 0.32, frames)
                place(at: CGPoint(x: position.x + (target.x - position.x) * ease,
                                  y: position.y + (target.y - position.y) * ease))
                if hypot(target.x - position.x, target.y - position.y) < 0.3 {
                    place(at: target)
                    return
                }
                try? await Task.sleep(for: .milliseconds(8))
            }
        }
    }

    private func place(at point: CGPoint) {
        position = point
        buddy.setCenter(point)
        placeCaption()
    }

    private func updateVisibility() {
        if isEnabled {
            place(at: goal)
            buddy.orderFrontRegardless()
        } else {
            buddy.orderOut(nil)
        }
    }

    /// Turns smoothly, the short way round.
    private func turn(to degrees: Double) {
        withAnimation(.spring(duration: 0.4, bounce: 0.25)) { setHeading(degrees) }
    }

    private func setHeading(_ degrees: Double) {
        var target = degrees
        while target - heading > 180 { target -= 360 }
        while target - heading < -180 { target += 360 }
        heading = target
    }

    // MARK: Highlight

    private func showHighlight(_ style: HighlightView.Style) {
        let margin: CGFloat = 16
        let frame: CGRect = switch style {
        case .outline(let rect): rect.insetBy(dx: -4 - margin, dy: -4 - margin)
        case .spot(let center): CGRect(x: center.x - 44, y: center.y - 44, width: 88, height: 88)
        }
        highlight.setContent(HighlightView(style: style, margin: margin), frame: frame)
        highlight.orderFrontRegardless()
    }

    // MARK: Geometry

    private static func curve(_ a: CGPoint, _ control: CGPoint, _ b: CGPoint, _ t: Double) -> CGPoint {
        let u = 1 - t
        return CGPoint(x: u * u * a.x + 2 * u * t * control.x + t * t * b.x,
                       y: u * u * a.y + 2 * u * t * control.y + t * t * b.y)
    }

    private static func tangent(_ a: CGPoint, _ control: CGPoint, _ b: CGPoint, _ t: Double) -> CGVector {
        CGVector(dx: 2 * (1 - t) * (control.x - a.x) + 2 * t * (b.x - control.x),
                 dy: 2 * (1 - t) * (control.y - a.y) + 2 * t * (b.y - control.y))
    }

    /// Degrees clockwise from straight up, for a direction in AppKit coordinates (y up).
    private static func angle(of direction: CGVector) -> Double {
        atan2(direction.dx, direction.dy) * 180 / .pi
    }
}

/// A see-through window that floats above everything and lets clicks pass through.
private final class OverlayPanel: NSPanel {
    init(size: CGSize, content: some View) {
        super.init(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        contentView = Self.hosting(content)
    }

    /// The window decides its own size; the SwiftUI content doesn't resize it.
    private static func hosting(_ content: some View) -> NSView {
        let hosting = NSHostingView(rootView: content)
        hosting.sizingOptions = []
        return hosting
    }

    func setCenter(_ point: CGPoint) {
        setFrameOrigin(CGPoint(x: (point.x - frame.width / 2).rounded(), y: (point.y - frame.height / 2).rounded()))
    }

    /// Fresh content restarts its animation.
    func setContent(_ content: some View, frame: CGRect) {
        contentView = Self.hosting(content)
        setFrame(frame, display: true)
    }
}

/// The arrow itself: a soft, rounded pointer in Case's black-and-white ceramic.
struct BuddyArrow: View {
    var size: CGFloat = 18
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let dark = colorScheme == .dark
        ArrowShape()
            .fill(LinearGradient(colors: dark ? [Color(white: 1), Color(white: 0.78)] : [Color(white: 0.3), Color(white: 0.02)],
                                 startPoint: .top, endPoint: .bottom))
            .overlay(ArrowShape().stroke(dark ? Color.black.opacity(0.55) : Color.white, lineWidth: 1.5))
            .frame(width: size, height: size)
    }
}

/// Points straight up; rotate it to aim.
private nonisolated struct ArrowShape: Shape {
    func path(in rect: CGRect) -> Path {
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height) }
        let tip = p(0.5, 0.02), right = p(0.92, 0.94), notch = p(0.5, 0.72), left = p(0.08, 0.94)
        var path = Path()
        // Start partway along an edge, so every corner gets rounded.
        path.move(to: CGPoint(x: (right.x + notch.x) / 2, y: (right.y + notch.y) / 2))
        path.addArc(tangent1End: notch, tangent2End: left, radius: rect.width * 0.05)
        path.addArc(tangent1End: left, tangent2End: tip, radius: rect.width * 0.1)
        path.addArc(tangent1End: tip, tangent2End: right, radius: rect.width * 0.07)
        path.addArc(tangent1End: right, tangent2End: notch, radius: rect.width * 0.1)
        path.closeSubpath()
        return path
    }
}

private struct BuddyView: View {
    let pointer: Pointer

    var body: some View {
        let activity = pointer.isFlying ? .idle : pointer.activity()
        TimelineView(.animation(paused: activity == .idle)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            ZStack {
                // Talking: the arrow becomes a wave that moves with your voice.
                VoiceWave(level: pointer.level, t: t)
                    .opacity(activity == .listening ? 1 : 0)
                    .scaleEffect(activity == .listening ? 1 : 0.6)

                // Thinking: a ring spins around the arrow on a small glass disc.
                ThinkingRing(t: t)
                    .opacity(activity == .thinking ? 1 : 0)
                    .scaleEffect(activity == .thinking ? 1 : 0.6)

                // The arrow, with soft rings while Aman talks. It steps aside for the voice wave.
                ZStack {
                    if activity == .speaking { ripples(t: t) }
                    BuddyArrow()
                        .rotationEffect(.degrees(pointer.heading))
                        .scaleEffect(pointer.isPressing ? 0.75 : 1)
                        .scaleEffect(activity == .speaking ? 1.04 + 0.05 * sin(t * 9) : activity == .thinking ? 0.8 : 1)
                        .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                }
                .opacity(activity == .listening ? 0 : 1)
                .scaleEffect(activity == .listening ? 0.6 : 1)
            }
            .animation(.spring(duration: 0.3, bounce: 0.2), value: activity)
        }
        .frame(width: 56, height: 56)
    }

    private func ripples(t: Double) -> some View {
        ForEach(0..<2) { ring in
            let phase = (t / 1.6 + Double(ring) / 2).truncatingRemainder(dividingBy: 1)
            Circle()
                .stroke(Color.primary.opacity(0.45 * (1 - phase)), lineWidth: 1.5)
                .frame(width: 18 + 30 * phase, height: 18 + 30 * phase)
        }
    }
}

/// A thin arc with a fading tail, turning about once a second.
private struct ThinkingRing: View {
    let t: Double

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.72)
            .stroke(
                AngularGradient(colors: [Color.primary.opacity(0), Color.primary], center: .center,
                                startAngle: .degrees(0), endAngle: .degrees(260)),
                style: StrokeStyle(lineWidth: 2.5, lineCap: .round)
            )
            .rotationEffect(.degrees((t * 400).truncatingRemainder(dividingBy: 360)))
            .frame(width: 26, height: 26)
            .frame(width: 34, height: 34)
            .glassEffect(.regular, in: .circle)
    }
}

/// Five bars on a glass chip that rise and fall with your voice.
private struct VoiceWave: View {
    let level: Double
    let t: Double

    var body: some View {
        HStack(spacing: 2.5) {
            ForEach(0..<5) { bar in
                // A little movement even when quiet, so it's clearly listening.
                let wobble = 0.55 + 0.45 * sin(t * 9 + Double(bar) * 1.3)
                Capsule()
                    .frame(width: 3, height: 4 + 14 * max(level, 0.12) * wobble)
            }
        }
        .foregroundStyle(.primary)
        .animation(.easeOut(duration: 0.12), value: level)
        .frame(width: 40, height: 26)
        .glassEffect(.regular, in: .capsule)
    }
}

/// The bubble beside the buddy. Short lines stay snug; longer ones wrap at 300 points,
/// and a long answer keeps showing its newest lines.
private struct CaptionView: View {
    let pointer: Pointer
    @State private var answerHeight: CGFloat = 0
    @State private var heardWidth: CGFloat = 80

    private static let width: CGFloat = 300

    var body: some View {
        content
            .font(.system(size: 13, weight: .medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .glassEffect(.regular, in: .rect(cornerRadius: 14))
            .fixedSize()
            .onGeometryChange(for: CGSize.self) { $0.size } action: { pointer.captionResized($0) }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var content: some View {
        if let caption = pointer.caption {
            switch caption.kind {
            case .heard, .status:
                let text = caption.text.isEmpty ? "Listening…" : caption.text
                Text(text)
                    .lineLimit(3)
                    .foregroundStyle(caption.text.isEmpty || caption.kind == .status ? .secondary : .primary)
                    .frame(width: min(heardWidth, Self.width), alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    // Measures the text on one line, so short phrases get a snug bubble.
                    .background {
                        Text(text).fixedSize().hidden()
                            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { heardWidth = $0 }
                    }
            case .answer:
                ScrollView {
                    Text(caption.text)
                        .frame(width: Self.width, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { answerHeight = $0 }
                }
                .scrollIndicators(.never)
                .defaultScrollAnchor(.bottom, for: .sizeChanges)
                .frame(width: Self.width, height: min(max(answerHeight, 16), 170))
            case .problem:
                Label(caption.text, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .frame(width: Self.width, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// The mark around what Claude pointed at, fitted to the real thing with an even gap: a circle
/// around a small icon, a rounded box around anything else from a button to a whole panel.
/// A fixed-size target ring is only for when we know nothing but the spot.
private struct HighlightView: View {
    enum Style {
        case outline(CGRect)
        case spot(CGPoint)
    }

    let style: Style
    let margin: CGFloat

    @State private var appeared = false
    @State private var glowing = false

    var body: some View {
        content
            .scaleEffect(appeared ? 1 : 1.2)
            .opacity(appeared ? 1 : 0)
            .onAppear {
                withAnimation(.spring(duration: 0.35, bounce: 0.3)) { appeared = true }
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true).delay(0.35)) { glowing = true }
            }
    }

    @ViewBuilder
    private var content: some View {
        switch style {
        case .outline(let rect):
            let large = rect.width > 360 || rect.height > 120
            let shape = RoundedRectangle(cornerRadius: Self.cornerRadius(for: rect), style: .continuous)
            shape.fill(.white.opacity(large ? 0.04 : 0.1))
                .overlay(shape.strokeBorder(.white, lineWidth: 2.5))
                .overlay(shape.inset(by: -1).stroke(.black.opacity(0.4), lineWidth: 1))
                .shadow(color: .white.opacity(glowing ? 0.9 : 0.35), radius: glowing ? 7 : 3)
                .shadow(color: .black.opacity(0.25), radius: 4)
                .padding(margin)
        case .spot:
            ZStack {
                Circle().stroke(.white.opacity(glowing ? 0 : 0.6), lineWidth: 2)
                    .frame(width: glowing ? 64 : 34, height: glowing ? 64 : 34)
                Circle().strokeBorder(.white, lineWidth: 2.5)
                    .overlay(Circle().inset(by: -1).stroke(.black.opacity(0.4), lineWidth: 1))
                    .frame(width: 34, height: 34)
                Circle().fill(.white).frame(width: 6, height: 6)
                    .overlay(Circle().stroke(.black.opacity(0.4), lineWidth: 1))
            }
            .shadow(color: .black.opacity(0.3), radius: 4)
            .frame(width: 88, height: 88)
        }
    }

    /// Half the size makes a circle, for something small and nearly square.
    private static func cornerRadius(for rect: CGRect) -> CGFloat {
        let width = rect.width + 8, height = rect.height + 8
        if max(width, height) <= 52, abs(width - height) <= 6 { return max(width, height) / 2 }
        return min(rect.height > 120 ? 14 : 8, height / 2)
    }
}
