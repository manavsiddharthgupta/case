import AppKit
import SwiftUI

/// A small panel that drops from the top middle of the screen, out of the notch on Macs that have
/// one: a greeting, how to ask, and what Case can reach. Rest the mouse at the top middle to open it,
/// or choose Home in the menu. It goes away when the mouse leaves, or on a click elsewhere or Esc.
final class HomePanel: NSPanel {
    private static let size = CGSize(width: 540, height: 176)
    /// The strip at the top middle of the screen that opens it.
    private static let zoneWidth: CGFloat = 240
    private static let zoneHeight: CGFloat = 6
    private static let dwell: Duration = .milliseconds(250)
    private static let leaveAfter: Duration = .milliseconds(400)

    private let model: AppModel
    private var monitors: [Any] = []
    private var opening: Task<Void, Never>?
    private var leaving: Task<Void, Never>?
    /// Opened by resting the mouse at the top, so it also closes when the mouse moves away.
    private var openedByHover = false

    init(model: AppModel) {
        self.model = model
        super.init(contentRect: NSRect(origin: .zero, size: Self.size), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        // Over the menu bar, so it reads as coming out of the notch.
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
    }

    override var canBecomeKey: Bool { false }

    /// Starts watching the mouse. Called once at launch.
    func start() {
        let events: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDown, .rightMouseDown, .keyDown]
        // The global monitor misses events in Case's own windows, so both are needed.
        monitors = [
            NSEvent.addGlobalMonitorForEvents(matching: events) { [weak self] event in self?.handle(event, inside: false) },
            NSEvent.addLocalMonitorForEvents(matching: events) { [weak self] event in
                self?.handle(event, inside: event.window === self)
                return event
            },
        ].compactMap { $0 }
    }

    func show(byHover: Bool = false) {
        opening?.cancel()
        leaving?.cancel()
        openedByHover = byHover
        guard !isVisible, let screen = Self.screenUnderMouse else { return }
        contentView = FirstClickHostingView(rootView: HomeView(model: model, close: { [weak self] in self?.hide() }))
        let top = screen.frame.maxY
        let frame = NSRect(x: screen.frame.midX - Self.size.width / 2, y: top - Self.size.height,
                           width: Self.size.width, height: Self.size.height)
        // Slides down from behind the menu bar.
        setFrame(frame.offsetBy(dx: 0, dy: 24), display: true)
        alphaValue = 0
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().setFrame(frame, display: true)
            animator().alphaValue = 1
        }
    }

    func hide() {
        opening?.cancel()
        leaving?.cancel()
        guard isVisible else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                self?.orderOut(nil)
                self?.contentView = nil
            }
        }
    }

    private func handle(_ event: NSEvent, inside: Bool) {
        switch event.type {
        case .mouseMoved:
            mouseMoved()
        case .leftMouseDown, .rightMouseDown:
            if isVisible, !inside, !frame.contains(NSEvent.mouseLocation) { hide() }
        case .keyDown:
            if isVisible, event.keyCode == 53 { hide() }
        default:
            break
        }
    }

    private func mouseMoved() {
        let mouse = NSEvent.mouseLocation
        if isVisible {
            guard openedByHover else { return }
            if frame.insetBy(dx: -16, dy: -16).contains(mouse) || Self.isInZone(mouse) {
                leaving?.cancel()
                leaving = nil
            } else if leaving == nil {
                leaving = Task { [weak self] in
                    try? await Task.sleep(for: Self.leaveAfter)
                    guard !Task.isCancelled else { return }
                    self?.leaving = nil
                    self?.hide()
                }
            }
        } else if Self.isInZone(mouse) {
            guard opening == nil else { return }
            opening = Task { [weak self] in
                try? await Task.sleep(for: Self.dwell)
                self?.opening = nil
                guard !Task.isCancelled, Self.isInZone(NSEvent.mouseLocation) else { return }
                self?.show(byHover: true)
            }
        } else {
            opening?.cancel()
            opening = nil
        }
    }

    private static var screenUnderMouse: NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
    }

    /// The very top of the screen, around the middle: the notch, or where it would be.
    private static func isInZone(_ mouse: CGPoint) -> Bool {
        guard let screen = screenUnderMouse else { return false }
        return mouse.y >= screen.frame.maxY - zoneHeight && abs(mouse.x - screen.frame.midX) <= zoneWidth / 2
    }
}

private struct HomeView: View {
    let model: AppModel
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("⌥⌘")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
                    .padding(.horizontal, 10)
                    .frame(height: 24)
                    .background(.white.opacity(0.1), in: .capsule)
                Spacer()
                IconButton(symbol: "gearshape", help: "Setup") {
                    close()
                    model.openWindow("setup")
                }
            }

            Spacer(minLength: 0)

            Text(greeting)
                .font(Theme.font(24, weight: .medium))
                .tracking(-0.6)
            Text(hint)
                .font(Theme.font(14))
                .foregroundStyle(.white.opacity(0.6))
                .padding(.top, 4)

            Spacer(minLength: 0)

            HStack {
                Button {
                    close()
                    model.page = .chats
                    model.openWindow("main")
                } label: {
                    Label("Open Case", systemImage: "macwindow")
                        .font(Theme.font(12, weight: .medium))
                        .padding(.horizontal, 12)
                        .frame(height: 28)
                        .background(.white.opacity(0.1), in: .capsule)
                        .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                Spacer()
                Reach()
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 18)
        // Clear of the menu bar it drops from.
        .padding(.top, 34)
        .padding(.bottom, 14)
        .frame(width: 540, height: 176)
        .background(.black, in: UnevenRoundedRectangle(bottomLeadingRadius: 26, bottomTrailingRadius: 26))
        .environment(\.colorScheme, .dark)
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: .now)
        let part = switch hour {
        case 5..<12: "Morning"
        case 12..<17: "Afternoon"
        case 17..<23: "Evening"
        default: "Up late"
        }
        let name = NSFullUserName().split(separator: " ").first.map(String.init) ?? ""
        return name.isEmpty ? "\(part)." : "\(part), \(name)."
    }

    /// How to ask, or what's wrong if Case can't answer right now.
    private var hint: String {
        if case .connected = model.claude {
            return model.permissions.allGranted
                ? "Hold ⌥⌘ and tell me what to take off your plate."
                : "Some permissions are missing. Open Setup to finish."
        }
        return model.claude.summary
    }
}

/// What Case can reach on this Mac, as small icons with their names on hover.
private struct Reach: View {
    private static let items = [
        ("message", "iMessage"), ("globe", "Chrome tabs"), ("folder", "Files"), ("waveform", "Meeting notes"), ("brain", "Memory"),
    ]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Self.items, id: \.1) { symbol, name in
                Image(systemName: symbol)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.75))
                    .frame(width: 26, height: 26)
                    .background(.white.opacity(0.1), in: .circle)
                    .help(name)
            }
        }
    }
}

private struct IconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: 26, height: 26)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
