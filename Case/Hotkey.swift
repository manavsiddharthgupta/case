import AppKit

/// The system-wide hotkey: ⌥⌘ held together, with no other key. It reports press and release,
/// so we can tell a tap (type) from a hold (talk). Modifier keys alone can't be registered as a
/// hotkey, so this watches them directly. Any other key or a click while they're down means
/// they're part of something else, like the shortcut ⌥⌘D, and cancels instead.
final class Hotkey {
    var onPress: () -> Void = {}
    var onRelease: () -> Void = {}
    var onCancel: () -> Void = {}

    private static let keys: NSEvent.ModifierFlags = [.option, .command]
    private static let allModifiers: NSEvent.ModifierFlags = [.option, .command, .shift, .control]

    private var isDown = false
    private var isCancelled = false
    private var monitors: [Any] = []

    init() {
        start()
    }

    /// Starts listening. Called again once Accessibility is allowed, because a monitor added
    /// before that may never hear anything.
    func start() {
        monitors.forEach(NSEvent.removeMonitor)
        let events: NSEvent.EventTypeMask = [.flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown]
        // The global monitor misses events sent to our own windows, like the typing pill.
        monitors = [
            NSEvent.addGlobalMonitorForEvents(matching: events) { [weak self] event in self?.handle(event) },
            NSEvent.addLocalMonitorForEvents(matching: events) { [weak self] event in
                self?.handle(event)
                return event
            },
        ].compactMap { $0 }
    }

    private func handle(_ event: NSEvent) {
        guard event.type == .flagsChanged else {
            if isDown, !isCancelled {
                isCancelled = true
                onCancel()
            }
            return
        }
        let held = event.modifierFlags.intersection(Self.allModifiers) == Self.keys
        guard held != isDown else { return }
        isDown = held
        if held {
            onPress()
        } else if isCancelled {
            isCancelled = false
        } else {
            onRelease()
        }
    }

    isolated deinit {
        monitors.forEach(NSEvent.removeMonitor)
    }
}
