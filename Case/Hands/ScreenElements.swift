import AppKit
import ApplicationServices

/// A thing on screen, read from macOS's accessibility info (the same info VoiceOver uses).
nonisolated struct ScreenElement: @unchecked Sendable {
    let kind: String
    let label: String
    /// The part you can actually see, in global screen coordinates with the origin at the top
    /// left of the main display.
    let frame: CGRect
    /// The live item and the scrolling area it sits in, to look again just before marking it.
    var element: AXUIElement?
    var clip: AXUIElement?
}

/// Maps the front window: buttons, links and fields, plus the bigger things around them (panels,
/// lists, headings, text, images), each with exactly where it shows. Claude says "#7" and we
/// know exactly what #7 is and how big it is.
enum ScreenElements {
    private nonisolated static let kinds: [String: String] = [
        "AXButton": "button", "AXLink": "link", "AXTextField": "text field", "AXTextArea": "text area",
        "AXCheckBox": "checkbox", "AXRadioButton": "option", "AXPopUpButton": "pop-up menu",
        "AXMenuButton": "menu button", "AXComboBox": "combo box", "AXSlider": "slider",
        "AXDisclosureTriangle": "disclosure", "AXMenuBarItem": "menu", "AXIncrementor": "stepper",
    ]

    /// Things to explain rather than press. `kinds` is what's only useful when it's a real control.
    private nonisolated static let areas: [String: String] = [
        "AXScrollArea": "panel", "AXOutline": "list", "AXTable": "list", "AXList": "list", "AXBrowser": "list",
        "AXTabGroup": "tab group", "AXToolbar": "toolbar", "AXWebArea": "web page", "AXGroup": "section",
        "AXImage": "image", "AXHeading": "heading", "AXStaticText": "text",
    ]

    private nonisolated static let chromiumBrowsers: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.canary", "com.brave.Browser", "com.microsoft.edgemac",
        "company.thebrowser.Browser", "com.vivaldi.Vivaldi", "com.operasoftware.Opera",
    ]

    /// What was found, plus how the read went (shown in the last-question log).
    nonisolated struct Scan: Sendable {
        /// The numbered list.
        var elements: [ScreenElement] = []
        /// What didn't fit on the list, still useful for fitting a box Claude drew.
        var extras: [ScreenElement] = []
        var visited = 0
        var slowReads = 0
        var ranOutOfTime = false
        var roles: [String: Int] = [:]

        var summary: String {
            let common = roles.sorted { $0.value > $1.value }.prefix(10).map { "\($0.key)×\($0.value)" }.joined(separator: " ")
            return "\(elements.count) elements from \(visited) nodes, \(slowReads) slow reads"
                + (ranOutOfTime ? ", ran out of time" : "") + "\n  Kinds seen: \(common)"
        }
    }

    /// Case can only read its own windows on the main thread, or macOS stops the app, and the reads
    /// marked @concurrent run in the background. So those skip Case's windows.
    private nonisolated static let ourPID = ProcessInfo.processInfo.processIdentifier
    private nonisolated static var isOursInFront: Bool {
        NSWorkspace.shared.frontmostApplication?.processIdentifier == ourPID
    }

    /// Reads the front app's window. Stops early on huge pages, so it never holds up the question.
    @concurrent
    nonisolated static func frontWindow(pid: pid_t, bundleID: String?, on screen: CGRect, limit: Int = 150) async -> Scan {
        guard pid != ourPID else { return Scan() }
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, 0.25)
        revealTree(of: element, bundleID: bundleID)

        var scan = Scan()
        let icons = menuBarIcons(on: screen)
        let deadline = Date.now.addingTimeInterval(0.6)

        /// One thing to read, what limits how much of it shows, and whether it's inside a control.
        typealias Node = (element: AXUIElement, depth: Int, clip: CGRect, scroller: AXUIElement?, inControl: Bool)

        // The menu bar first (File, Edit, …), then the window's own controls (toolbar, tabs, sidebar),
        // and web pages last, so a big page can't crowd out the app's buttons.
        var queue: [Node] = []
        var webPages: [Node] = []
        if let menuBar = copy(element, kAXMenuBarAttribute) as AXUIElement? {
            queue += children(of: menuBar).map { ($0, 1, screen, nil, false) }
        }
        let window = copy(element, kAXFocusedWindowAttribute) as AXUIElement? ?? copy(element, kAXMainWindowAttribute)
        guard let window else {
            scan.elements = icons
            return scan
        }
        queue.append((window, 0, (frame(of: window) ?? screen).intersection(screen), nil, false))

        // Twice the list's size, so plain text can't push out what's found after it.
        var found: [ScreenElement] = []
        var index = 0
        while found.count < limit * 2, scan.visited < 4000 {
            if index == queue.count {
                guard !webPages.isEmpty else { break }
                queue += webPages
                webPages = []
            }
            guard Date.now < deadline else {
                scan.ranOutOfTime = true
                break
            }
            let node = queue[index]
            index += 1
            scan.visited += 1

            let info = attributes(of: node.element, slowReads: &scan.slowReads)
            scan.roles[info.role ?? "?", default: 0] += 1
            let visible = info.frame?.intersection(node.clip)
            if let visible, visible.width > 2, visible.height > 2,
               let kind = listKind(of: info, size: visible.size, inControl: node.inControl) {
                found.append(ScreenElement(kind: kind, label: listLabel(of: info, element: node.element), frame: visible,
                                           element: node.element, clip: node.scroller))
            }
            // Menu bar items' menus are only interesting once they're open.
            guard node.depth < 40, info.role != "AXMenuBarItem" else { continue }
            // Scrolled out of view, or hidden behind the edge of the window: nothing in there shows.
            if let frame = info.frame, frame.width > 0, frame.height > 0, visible?.isNull == true { continue }

            // A long page inside a scrolling area reports its full height, so only what's inside
            // the scrolling area shows.
            let scrolls = info.role == "AXScrollArea" || info.role == "AXWebArea"
            let next: [Node] = info.children.map {
                ($0, node.depth + 1, scrolls ? (visible ?? node.clip) : node.clip, scrolls ? node.element : node.scroller,
                 node.inControl || info.role.flatMap { kinds[$0] } != nil)
            }
            if info.role == "AXWebArea" {
                webPages += next
            } else {
                queue += next
            }
        }

        let items = withoutRepeats(found)
        let important = items.filter { $0.kind != "text" }
        let room = limit - min(limit, important.count)
        let listed = important.prefix(limit) + items.filter { $0.kind == "text" }.prefix(room)
        scan.elements = icons + listed
        scan.extras = Array(important.dropFirst(limit)) + items.filter { $0.kind == "text" }.dropFirst(room)
        return scan
    }

    /// What to call this on the list, or nil to leave it off.
    private nonisolated static func listKind(of info: Info, size: CGSize, inControl: Bool) -> String? {
        guard let role = info.role else { return nil }
        if let kind = kinds[role] {
            // A name-less folder arrow only adds noise; an icon-only button may be what's needed.
            if role == "AXDisclosureTriangle", info.label.isEmpty { return nil }
            return info.subrole == "AXSearchField" ? "search field" : kind
        }
        // Words inside a button are already that button's name.
        guard !inControl, let kind = areas[role] else { return nil }
        switch kind {
        case "text", "heading": return info.label.isEmpty ? nil : kind
        case "image": return size.width >= 24 && size.height >= 24 ? kind : nil
        case "section": return !info.label.isEmpty && size.width >= 80 && size.height >= 30 ? kind : nil
        case "panel", "list": return size.width >= 80 && size.height >= 50 ? kind : nil
        default: return kind
        }
    }

    /// Its name, and for a list how many rows it has, so one entry can stand for all of them.
    private nonisolated static func listLabel(of info: Info, element: AXUIElement) -> String {
        guard info.role.flatMap({ areas[$0] }) == "list" else { return info.label }
        var rows: CFIndex = 0
        guard AXUIElementGetAttributeValueCount(element, kAXRowsAttribute as CFString, &rows) == .success, rows > 0
        else { return info.label }
        return info.label.isEmpty ? "\(rows) rows" : "\(info.label), \(rows) rows"
    }

    /// A panel and the list filling it are one thing to you: keep one, preferring the one with a name.
    private nonisolated static func withoutRepeats(_ items: [ScreenElement]) -> [ScreenElement] {
        var kept: [ScreenElement] = []
        var areaAt: [String: Int] = [:]
        for item in items {
            guard !kinds.values.contains(item.kind), !["text", "heading", "image"].contains(item.kind) else {
                kept.append(item)
                continue
            }
            let place = "\(Int(item.frame.minX)),\(Int(item.frame.minY)),\(Int(item.frame.width)),\(Int(item.frame.height))"
            if let index = areaAt[place] {
                if kept[index].label.isEmpty { kept[index] = item }
            } else {
                areaAt[place] = kept.count
                kept.append(item)
            }
        }
        return kept
    }

    /// Finds the real thing Claude drew a rough box around: the item matching the box, or the tight
    /// edge around what's inside it, like the lines of a paragraph. Nil when nothing fits well.
    nonisolated static func fit(_ box: CGRect, in items: [ScreenElement]) -> ScreenElement? {
        func area(_ rect: CGRect) -> CGFloat { rect.width * rect.height }
        func overlap(_ item: ScreenElement) -> CGFloat {
            let shared = area(item.frame.intersection(box))
            return shared / (area(item.frame) + area(box) - shared)
        }
        if let best = items.max(by: { overlap($0) < overlap($1) }), overlap(best) >= 0.6 { return best }

        let inside = items.filter { box.insetBy(dx: -12, dy: -12).contains($0.frame) }
        guard let first = inside.first else { return nil }
        let edge = inside.dropFirst().reduce(first.frame) { $0.union($1.frame) }
        return area(edge) >= area(box) * 0.35 ? ScreenElement(kind: "group", label: "\(inside.count) items", frame: edge) : nil
    }

    /// Where an item is now, since it may have moved after the question. Nil when it's gone or
    /// scrolled out of view; if the app is just slow to answer, where it was last seen.
    @concurrent
    nonisolated static func liveFrame(of item: ScreenElement) async -> CGRect? {
        guard let element = item.element else { return item.frame }
        AXUIElementSetMessagingTimeout(element, 0.2)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &value) != .invalidUIElement else { return nil }
        guard var now = frame(of: element) else { return item.frame }
        if let clip = item.clip, let edge = frame(of: clip) { now = now.intersection(edge) }
        return now.width > 2 && now.height > 2 ? now : nil
    }

    private nonisolated static let containers: Set<String> = [
        "AXGroup", "AXWebArea", "AXScrollArea", "AXWindow", "AXApplication", "AXSplitGroup", "AXLayoutArea",
        "AXList", "AXOutline", "AXTable", "AXTabGroup", "AXToolbar", "AXBrowser", "AXUnknown",
    ]

    /// Asks macOS what's at a spot Claude picked from the screenshot (works for any app, including
    /// browser tabs and menu bar icons), so we can outline the real control instead of a rough spot.
    /// The point is in accessibility coordinates (origin top left of the main display).
    @concurrent
    nonisolated static func control(at point: CGPoint) async -> CGRect? {
        guard !isOursInFront else { return nil }
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, 0.2)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &hit) == .success,
              var element = hit
        else { return nil }

        // Our own windows (the box, the outline) don't count.
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        guard pid != ProcessInfo.processInfo.processIdentifier else { return nil }

        // A label inside a button: use the button.
        for _ in 0..<3 {
            let role: String? = copy(element, kAXRoleAttribute)
            if let role, kinds[role] != nil || !containers.contains(role) && role != "AXStaticText" && role != "AXImage" { break }
            guard let parent: AXUIElement = copy(element, kAXParentAttribute) else { break }
            let parentRole: String? = copy(parent, kAXRoleAttribute)
            guard let parentRole, !containers.contains(parentRole) else { break }
            element = parent
        }

        let role: String? = copy(element, kAXRoleAttribute)
        guard let frame = frame(of: element), let role, !containers.contains(role),
              frame.width >= 6, frame.height >= 6, frame.width <= 360, frame.height <= 120,
              frame.insetBy(dx: -4, dy: -4).contains(point)
        else { return nil }
        return frame
    }

    // MARK: For the hands

    /// What's at a spot on screen, to decide whether clicking it needs your OK.
    nonisolated struct Target {
        /// What to press later, found before anything flew over it.
        var element: AXUIElement?
        var role = ""
        var words: [String] = []
        var appName = ""
        var bundleID = ""
        var frame: CGRect?
        var isOurs = false
    }

    nonisolated static func inspect(at point: CGPoint) -> Target {
        var target = Target()
        guard var element = hit(point) else { return target }
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        target.isOurs = pid == ProcessInfo.processInfo.processIdentifier
        let app = NSRunningApplication(processIdentifier: pid)
        target.appName = app?.localizedName ?? ""
        target.bundleID = app?.bundleIdentifier ?? ""
        // A label or icon inside a button: describe the button.
        if let pressable = pressable(from: element) { element = pressable }
        target.role = copy(element, kAXRoleAttribute) ?? ""
        target.words = [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute, kAXIdentifierAttribute, kAXValueAttribute]
            .compactMap { copy(element, $0) as String? }
            .filter { !$0.isEmpty }
        target.frame = frame(of: element)
        target.element = element
        return target
    }

    /// What the log says about a target.
    nonisolated static func describe(_ target: Target) -> String {
        "\(target.appName) (\(target.bundleID)) \(target.role) \(target.words.prefix(3).map { "\"\($0.prefix(30))\"" }.joined(separator: " "))"
            + (target.isOurs ? " [Case's own window]" : "")
    }

    /// Presses a control through accessibility, without moving the mouse. Text boxes get focus instead.
    /// Returns false when it can't be pressed this way, so a real click is needed.
    nonisolated static func press(_ element: AXUIElement) -> Bool {

        let role: String? = copy(element, kAXRoleAttribute)
        if let role, ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"].contains(role) {
            return AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success
        }
        guard let pressable = pressable(from: element) else { return false }
        return AXUIElementPerformAction(pressable, kAXPressAction as CFString) == .success
    }

    /// Whether the app has any window open.
    nonisolated static func hasWindow(_ pid: pid_t) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        return !((copy(app, kAXWindowsAttribute) as [AXUIElement]?) ?? []).isEmpty
    }

    /// Whether the app is showing a question over its work, like a "Save changes?" sheet.
    nonisolated static func isAsking(_ pid: pid_t) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        let windows: [AXUIElement] = copy(app, kAXWindowsAttribute) ?? []
        return windows.contains { window in
            let subrole: String? = copy(window, kAXSubroleAttribute)
            if subrole == "AXDialog" || subrole == "AXSystemDialog" { return true }
            return children(of: window).contains { child in
                let role: String? = copy(child, kAXRoleAttribute)
                return role == "AXSheet"
            }
        }
    }

    /// The app's front window, in top-left coordinates.
    nonisolated static func frontWindowFrame(_ pid: pid_t) -> CGRect? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        guard let window = copy(app, kAXFocusedWindowAttribute) as AXUIElement? ?? copy(app, kAXMainWindowAttribute) else { return nil }
        return frame(of: window)
    }

    /// A scrolling area and its real scroll bars.
    nonisolated struct ScrollArea: @unchecked Sendable {
        let frame: CGRect
        let vertical: AXUIElement?
        let horizontal: AXUIElement?
    }

    /// The scrolling area at `point`, or the biggest in the front window, which is usually the main content.
    @concurrent
    nonisolated static func scrollArea(pid: pid_t, at point: CGPoint?) async -> ScrollArea? {
        guard pid != ourPID else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        guard let window = copy(app, kAXFocusedWindowAttribute) as AXUIElement? ?? copy(app, kAXMainWindowAttribute) else { return nil }

        var areas: [ScrollArea] = []
        var queue = [window]
        var index = 0
        while index < queue.count, index < 600 {
            let node = queue[index]
            index += 1
            let role: String? = copy(node, kAXRoleAttribute)
            if role == "AXScrollArea", let rect = frame(of: node) {
                let vertical: AXUIElement? = copy(node, kAXVerticalScrollBarAttribute)
                let horizontal: AXUIElement? = copy(node, kAXHorizontalScrollBarAttribute)
                if vertical != nil || horizontal != nil {
                    areas.append(ScrollArea(frame: rect, vertical: vertical, horizontal: horizontal))
                }
            }
            queue += children(of: node)
        }
        func size(_ area: ScrollArea) -> CGFloat { area.frame.width * area.frame.height }
        if let point, let inside = areas.filter({ $0.frame.contains(point) }).min(by: { size($0) < size($1) }) { return inside }
        return areas.max { size($0) < size($1) }
    }

    /// Moves a scroll bar itself, which needs no mouse and shows whether it really moved. `amount`
    /// is 1 to 30: 10 is about one screenful, and 30 goes all the way. Returns false if it's already
    /// at the end, and nil if this app doesn't allow it.
    @concurrent
    nonisolated static func move(_ bar: AXUIElement, forward: Bool, amount: Int) async -> Bool? {
        AXUIElementSetMessagingTimeout(bar, 0.25)
        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(bar, kAXValueAttribute as CFString, &settable) == .success, settable.boolValue,
              let before: Double = (copy(bar, kAXValueAttribute) as NSNumber?)?.doubleValue
        else { return nil }

        let step = amount >= 30 ? 1 : Double(amount) / 10 * screenful(of: bar)
        let target = min(max(before + (forward ? step : -step), 0), 1)
        guard abs(target - before) > 0.0001 else { return false }
        guard AXUIElementSetAttributeValue(bar, kAXValueAttribute as CFString, target as CFNumber) == .success else { return nil }
        try? await Task.sleep(for: .milliseconds(120))
        guard let after: Double = (copy(bar, kAXValueAttribute) as NSNumber?)?.doubleValue, abs(after - before) > 0.0001 else { return nil }
        return true
    }

    /// One screenful as a share of the scroll bar's 0 to 1, from the size of its handle.
    private nonisolated static func screenful(of bar: AXUIElement) -> Double {
        guard let track = frame(of: bar),
              let handle = children(of: bar).first(where: { (copy($0, kAXRoleAttribute) as String?) == "AXValueIndicator" }),
              let knob = frame(of: handle)
        else { return 0.2 }
        let share = Double(track.height > track.width ? knob.height / track.height : knob.width / track.width)
        return share > 0 && share < 0.95 ? share / (1 - share) : 0.2
    }

    /// Clicks an app's Dock icon through accessibility, the way to bring back a closed window.
    nonisolated static func pressDockIcon(named name: String) -> Bool {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return false }
        let element = AXUIElementCreateApplication(dock.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.25)
        let icons = children(of: element).flatMap(children(of:))
        let wanted = name.filter { $0.isLetter || $0.isNumber }.lowercased()
        guard let icon = icons.first(where: { icon in
            let title: String = copy(icon, kAXTitleAttribute) ?? ""
            return title.filter { $0.isLetter || $0.isNumber }.lowercased() == wanted
        }) else { return false }
        return AXUIElementPerformAction(icon, kAXPressAction as CFString) == .success
    }

    /// The icons at the right of the menu bar (battery, Wi-Fi, sound, clock) with what they show,
    /// like "Battery, 70%", so questions about them can be answered and pointed at.
    private nonisolated static func menuBarIcons(on screen: CGRect) -> [ScreenElement] {
        ["com.apple.controlcenter", "com.apple.systemuiserver"]
            .flatMap(NSRunningApplication.runningApplications(withBundleIdentifier:))
            .flatMap { app -> [ScreenElement] in
                let element = AXUIElementCreateApplication(app.processIdentifier)
                AXUIElementSetMessagingTimeout(element, 0.1)
                guard let bar: AXUIElement = copy(element, "AXExtrasMenuBar") else { return [] }
                return children(of: bar).compactMap { icon in
                    guard let frame = frame(of: icon), frame.width > 2, frame.intersects(screen) else { return nil }
                    var words: [String] = []
                    for attribute in [kAXDescriptionAttribute, kAXTitleAttribute, kAXValueAttribute] {
                        if let word: String = copy(icon, attribute), !word.isEmpty, !words.contains(word) { words.append(word) }
                    }
                    return ScreenElement(kind: "menu bar icon", label: String(words.joined(separator: ", ").prefix(60)), frame: frame)
                }
            }
    }

    /// The words you've highlighted right now, if any. Never from a password box.
    @concurrent
    nonisolated static func selectedText() async -> String {
        guard !isOursInFront else { return "" }
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, 0.25)
        guard let element: AXUIElement = copy(systemWide, kAXFocusedUIElementAttribute),
              (copy(element, kAXSubroleAttribute) as String?) != "AXSecureTextField" else { return "" }
        return copy(element, kAXSelectedTextAttribute) ?? ""
    }

    /// All the words in the front window, in reading order, including what's scrolled out of view.
    /// Far cheaper than screenshots for reading a page. Nil when the window can't be read.
    @concurrent
    nonisolated static func windowText(pid: pid_t, bundleID: String?, limit: Int = 12_000) async -> (text: String, isCut: Bool)? {
        guard pid != ourPID else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        revealTree(of: app, bundleID: bundleID)
        guard let window = copy(app, kAXFocusedWindowAttribute) as AXUIElement? ?? copy(app, kAXMainWindowAttribute) else { return nil }

        let deadline = Date.now.addingTimeInterval(1.5)
        var lines: [String] = []
        var length = 0
        var visited = 0
        var pending = [window]
        while let node = pending.popLast() {
            visited += 1
            guard visited < 8000, length < limit, Date.now < deadline else { return (lines.joined(separator: "\n"), true) }
            let role: String? = copy(node, kAXRoleAttribute)
            if ["AXStaticText", "AXTextArea", "AXTextField"].contains(role ?? ""),
               (copy(node, kAXSubroleAttribute) as String?) != "AXSecureTextField",
               let words: String = copy(node, kAXValueAttribute) {
                let line = words.trimmingCharacters(in: .whitespacesAndNewlines)
                if !line.isEmpty, line != lines.last {
                    lines.append(String(line.prefix(limit - length)))
                    length += line.count
                }
            }
            pending += children(of: node).reversed()
        }
        return (lines.joined(separator: "\n"), false)
    }

    /// The box you're typing in right now.
    nonisolated struct Focus: Sendable {
        var role = ""
        var subrole = ""
        var text = ""
        var isSecure: Bool { subrole == "AXSecureTextField" || role == "AXSecureTextField" }
        var isTextBox: Bool { ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"].contains(role) || subrole == "AXSearchField" }
    }

    nonisolated static func focus() -> Focus {
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, 0.25)
        guard let element: AXUIElement = copy(systemWide, kAXFocusedUIElementAttribute) else { return Focus() }
        return Focus(role: copy(element, kAXRoleAttribute) ?? "", subrole: copy(element, kAXSubroleAttribute) ?? "",
                     text: copy(element, kAXValueAttribute) ?? "")
    }

    private nonisolated static func hit(_ point: CGPoint) -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, 0.25)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &hit) == .success else { return nil }
        return hit
    }

    /// The element itself or a nearby parent that can be pressed.
    private nonisolated static func pressable(from element: AXUIElement) -> AXUIElement? {
        var current: AXUIElement? = element
        for _ in 0..<4 {
            guard let candidate = current else { return nil }
            var names: CFArray?
            if AXUIElementCopyActionNames(candidate, &names) == .success,
               let names = names as? [String], names.contains(kAXPressAction) {
                return candidate
            }
            let role: String? = copy(candidate, kAXRoleAttribute)
            if let role, containers.contains(role) { return nil }
            current = copy(candidate, kAXParentAttribute)
        }
        return nil
    }

    /// The numbered list Claude picks from.
    nonisolated static func numberedList(_ elements: [ScreenElement], on screen: ScreenCapture.ScreenGeometry) -> String {
        guard !elements.isEmpty else {
            return "No list of what's on screen is available for this window; use x,y positions from the screenshot."
        }
        let lines = elements.enumerated().map { index, element in
            let centre = screen.pixel(fromTopLeft: CGPoint(x: element.frame.midX, y: element.frame.midY))
            let label = element.label.isEmpty ? "" : " \"\(element.label.replacingOccurrences(of: "\n", with: " "))\""
            let size = "\(Int(element.frame.width * screen.scale))×\(Int(element.frame.height * screen.scale))"
            return "#\(index + 1) \(element.kind)\(label) (\(Int(centre.x)), \(Int(centre.y))) \(size)"
        }
        return "Things on screen (number, kind, label, centre, then size, in screenshot pixels):\n" + lines.joined(separator: "\n")
    }

    /// Chrome and Electron apps (Notion, Slack, VS Code) only fill in this info once asked to.
    private nonisolated static func revealTree(of app: AXUIElement, bundleID: String?) {
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        if let bundleID, chromiumBrowsers.contains(bundleID) {
            AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        }
    }

    private nonisolated struct Info {
        var role: String?
        var subrole: String?
        var label = ""
        var frame: CGRect?
        var children: [AXUIElement] = []
    }

    /// One round trip for all the attributes we need, which matters on big pages. Some apps
    /// (like Chrome's own toolbar and tabs) refuse that, so ask one attribute at a time instead.
    private nonisolated static func attributes(of element: AXUIElement, slowReads: inout Int) -> Info {
        let names = [kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute, kAXDescriptionAttribute,
                     "AXPlaceholderValue", kAXPositionAttribute, kAXSizeAttribute, kAXChildrenAttribute]
        var values: [AnyObject?]
        var batch: CFArray?
        if AXUIElementCopyMultipleAttributeValues(element, names as CFArray, [], &batch) == .success,
           let batch = batch as? [AnyObject], batch.count == names.count {
            values = batch
        } else {
            slowReads += 1
            values = names.map { copy(element, $0) as AnyObject? }
        }

        var info = Info()
        info.role = values[0] as? String
        info.subrole = values[1] as? String
        var label = [values[2], values[3], values[4]].compactMap { $0 as? String }.first { !$0.isEmpty } ?? ""
        // Words on screen and file names live in the value. Asked for separately, because a big
        // document's value is huge, and never for a password box.
        if label.isEmpty, info.subrole != "AXSecureTextField",
           ["AXStaticText", "AXTextField", "AXHeading"].contains(info.role ?? "") {
            label = copy(element, kAXValueAttribute) ?? ""
        }
        info.label = String(label.prefix(60))
        if let position = point(values[5]), let size = size(values[6]) {
            info.frame = CGRect(origin: position, size: size)
        }
        info.children = (values[7] as? [AXUIElement]) ?? []
        return info
    }

    private nonisolated static func copy<T>(_ element: AXUIElement, _ attribute: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? T
    }

    private nonisolated static func children(of element: AXUIElement) -> [AXUIElement] {
        copy(element, kAXChildrenAttribute) ?? []
    }

    private nonisolated static func frame(of element: AXUIElement) -> CGRect? {
        guard let position = point(copy(element, kAXPositionAttribute)),
              let size = size(copy(element, kAXSizeAttribute)) else { return nil }
        return CGRect(origin: position, size: size)
    }

    private nonisolated static func point(_ value: AnyObject?) -> CGPoint? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(value as! AXValue, .cgPoint, &point) ? point : nil
    }

    private nonisolated static func size(_ value: AnyObject?) -> CGSize? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(value as! AXValue, .cgSize, &size) ? size : nil
    }
}
