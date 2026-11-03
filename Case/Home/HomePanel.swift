import AppKit
import SwiftUI

/// Home dropping out of the notch: the same view as under the ✦ icon, in black so it blends with
/// the notch. Rest the mouse at the top middle of the screen to open it. It goes away when the
/// mouse leaves, or on a click elsewhere, Esc or the hotkey.
final class HomePanel: NSPanel {
    /// The strip at the top middle of the screen that opens it.
    private static let zoneWidth: CGFloat = 240
    private static let zoneHeight: CGFloat = 6
    private static let dwell: Duration = .milliseconds(250)
    private static let leaveAfter: Duration = .milliseconds(400)

    private let model: AppModel
    private var monitors: [Any] = []
    private var opening: Task<Void, Never>?
    private var leaving: Task<Void, Never>?

    init(model: AppModel) {
        self.model = model
        super.init(contentRect: NSRect(x: 0, y: 0, width: HomeView.width, height: 120),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
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

    func hide() {
        opening?.cancel()
        leaving?.cancel()
        leaving = nil
        guard isVisible else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                // Shown again while fading out.
                guard let self, self.alphaValue == 0 else { return }
                self.orderOut(nil)
                self.contentView = nil
            }
        }
    }

    private func show(on screen: NSScreen) {
        // The menu bar's height, which on a Mac with a notch is the notch's.
        let menuBar = max(screen.frame.maxY - screen.visibleFrame.maxY, screen.safeAreaInsets.top, 24)
        let view = FirstClickHostingView(rootView: HomeView(inNotch: true, topInset: menuBar) { [weak self] in self?.hide() }
            .environment(model))
        view.sizingOptions = .intrinsicContentSize
        contentView = view
        let size = view.fittingSize
        let frame = NSRect(x: screen.frame.midX - size.width / 2, y: screen.frame.maxY - size.height,
                           width: size.width, height: size.height)
        // Slides down from behind the menu bar.
        setFrame(frame.offsetBy(dx: 0, dy: 20), display: true)
        alphaValue = 0
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().setFrame(frame, display: true)
            animator().alphaValue = 1
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
        if isVisible, alphaValue > 0 {
            if frame.insetBy(dx: -16, dy: -16).contains(mouse) || Self.zone(containing: mouse) != nil {
                leaving?.cancel()
                leaving = nil
            } else if leaving == nil {
                leaving = Task { [weak self] in
                    try? await Task.sleep(for: Self.leaveAfter)
                    guard !Task.isCancelled else { return }
                    self?.hide()
                }
            }
        } else if Self.zone(containing: mouse) != nil {
            guard opening == nil else { return }
            opening = Task { [weak self] in
                try? await Task.sleep(for: Self.dwell)
                self?.opening = nil
                guard !Task.isCancelled, let screen = Self.zone(containing: NSEvent.mouseLocation) else { return }
                self?.show(on: screen)
            }
        } else {
            opening?.cancel()
            opening = nil
        }
    }

    /// The screen whose top middle, the notch or where it would be, the mouse is resting in.
    private static func zone(containing mouse: CGPoint) -> NSScreen? {
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }),
              mouse.y >= screen.frame.maxY - zoneHeight, abs(mouse.x - screen.frame.midX) <= zoneWidth / 2 else { return nil }
        return screen
    }
}

/// Home: a greeting, how to ask, and the things you do most. Shown under the ✦ icon and out of the notch.
struct HomeView: View {
    static let width: CGFloat = 380

    @Environment(AppModel.self) private var model
    /// In the notch it's always black, to blend in; under the icon it follows light or dark mode.
    var inNotch = false
    /// Room for the menu bar the notch panel drops from behind.
    var topInset: CGFloat = 0
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                MarkView(active: model.assistant.isBusy || model.recorder.isCapturing, size: 30)
                VStack(alignment: .leading, spacing: 3) {
                    Text(greeting)
                        .font(Theme.font(19, weight: .medium))
                        .tracking(-0.4)
                    hint
                }
                Spacer(minLength: 0)
                Menu {
                    MenuView()
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 28, height: 28)
                        .contentShape(.circle)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .foregroundStyle(muted)
                .fixedSize()
                .help("More")
            }

            HStack(spacing: 8) {
                Action(title: "Ask", symbol: "text.cursor", inNotch: inNotch) {
                    close()
                    model.assistant.openTyping()
                }
                meetingAction
                Action(title: "Open Case", symbol: "macwindow", inNotch: inNotch) {
                    close()
                    model.page = .chats
                    model.openWindow("main")
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 16 + topInset)
        .padding(.bottom, 16)
        .frame(width: Self.width)
        .foregroundStyle(inNotch ? Color.white : Theme.foreground)
        .background {
            if inNotch {
                UnevenRoundedRectangle(bottomLeadingRadius: 22, bottomTrailingRadius: 22).fill(.black)
            }
        }
        .environment(\.colorScheme, inNotch ? .dark : colorScheme)
    }

    @Environment(\.colorScheme) private var colorScheme

    private var muted: Color { inNotch ? .white.opacity(0.55) : Theme.muted }

    @ViewBuilder private var meetingAction: some View {
        if model.recorder.isCapturing {
            Action(title: "Stop notes", symbol: "stop.fill", inNotch: inNotch, live: true) {
                Task { await model.recorder.stop() }
            }
        } else {
            Action(title: "Meeting notes", symbol: "waveform", inNotch: inNotch) {
                close()
                Task { await model.recorder.start() }
            }
            .disabled(model.recorder.isActive)
        }
    }

    /// How to ask, or what's wrong if Case can't answer right now.
    @ViewBuilder private var hint: some View {
        if case .connected = model.claude, model.permissions.allGranted {
            HStack(spacing: 4) {
                Text("Hold")
                Keycap("⌥", inNotch: inNotch)
                Keycap("⌘", inNotch: inNotch)
                Text("to talk, tap to type")
            }
            .font(Theme.font(13))
            .foregroundStyle(muted)
        } else {
            Text(model.permissions.allGranted ? model.claude.summary : "Some permissions are missing. Open Setup from •••.")
                .font(Theme.font(13))
                .foregroundStyle(.orange)
        }
    }

    private var greeting: String {
        let part = switch Calendar.current.component(.hour, from: .now) {
        case 5..<12: "Morning"
        case 12..<17: "Afternoon"
        case 17..<23: "Evening"
        default: "Up late"
        }
        let name = NSFullUserName().split(separator: " ").first.map(String.init) ?? ""
        return name.isEmpty ? "\(part)." : "\(part), \(name)."
    }
}

private struct Keycap: View {
    let key: String
    let inNotch: Bool

    init(_ key: String, inNotch: Bool) {
        self.key = key
        self.inNotch = inNotch
    }

    var body: some View {
        Text(key)
            .font(.system(size: 11, weight: .medium))
            .frame(minWidth: 20, minHeight: 18)
            .background(inNotch ? Color.white.opacity(0.12) : Theme.pill, in: .rect(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(inNotch ? Color.white.opacity(0.15) : Theme.border))
    }
}

/// One of the things you do most, as a wide rounded button.
private struct Action: View {
    let title: String
    let symbol: String
    let inNotch: Bool
    var live = false
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                if live {
                    RecordingDot()
                        .frame(height: 16)
                } else {
                    Image(systemName: symbol)
                        .font(.system(size: 14))
                        .frame(height: 16)
                }
                Text(title)
                    .font(Theme.font(12, weight: .medium))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
            .background(background, in: .rect(cornerRadius: 12))
            .contentShape(.rect(cornerRadius: 12))
            .opacity(isEnabled ? 1 : 0.4)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    private var background: Color {
        if inNotch { return .white.opacity(hovering ? 0.16 : 0.09) }
        return hovering ? Theme.ghost.opacity(0.5) : Theme.pill
    }
}
