import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Case's hands: the tools Claude can use to work the Mac for you (look, open, click, write,
/// press keys, scroll). The safety rules live here, not with Claude: anything that sends, posts,
/// deletes or buys asks you first, passwords are never typed, and only web links can be opened.
final class Hands {
    /// Shows the confirm card and waits for your answer.
    var confirm: (ConfirmCard.Request) async -> Bool = { _ in false }
    /// Flies the buddy to a spot (AppKit coordinates) and taps it; returns once it has landed.
    var tap: (CGRect) async -> Void = { _ in }
    /// Runs something with Case's floating windows out of the way.
    var withOverlaysHidden: (() -> ScreenElements.Target) -> ScreenElements.Target = { $0() }

    /// A short line about the step that's starting, like "Opening WhatsApp", for the caption and voice.
    var onProgress: (String) -> Void = { _ in }
    /// The list of facts about the user that remember and forget change.
    var memory: MemoryStore?
    /// Starts, pauses, resumes or stops meeting notes, and says how that went.
    var meetingNotes: (String) -> String = { _ in "" }

    /// Set by Esc: every further step is refused.
    var isStopped = false
    private(set) var actedThisTurn = false
    private(set) var looksThisTurn = 0
    /// Every step this turn, for the last-question log.
    private(set) var log: [String] = []

    private var screen: ScreenCapture.ScreenGeometry?
    private var elements: [ScreenElement] = []
    /// What the latest look saw this turn, since Claude's numbers now refer to it.
    private(set) var lookedAt: (scan: ScreenElements.Scan, screen: ScreenCapture.ScreenGeometry)?
    /// Numbers and positions only mean something for the screen Claude last saw.
    private var listIsCurrent = false
    private var steps = 0

    private static let maxSteps = 15
    private static let escapeKey: CGKeyCode = 53
    /// When Case last pressed Esc itself.
    private static var pressedEscapeAt = ContinuousClock.now - .seconds(60)
    /// Esc anywhere means stop, but not the one Case just pressed as part of a task.
    static var justPressedEscape: Bool { ContinuousClock.now - pressedEscapeAt < .milliseconds(500) }
    /// These only read, so they don't count toward the limit or as doing something.
    private static let readOnly: Set = ["look", "find_files", "system_info", "read_page", "remember", "forget", "meeting_notes"]
    /// Web addresses and links into apps. Nothing that can run a program or open a file.
    private static let linkSchemes: Set = ["http", "https", "whatsapp", "spotify", "notion", "slack", "zoommtg"]
    /// Opening these runs them, so a page or message can't talk Claude into it.
    private static let runnableFiles: Set = ["app", "command", "tool", "sh", "zsh", "bash", "py", "pkg", "mpkg", "scpt", "scptd",
                                             "applescript", "workflow", "terminal", "jar", "dmg"]

    /// A new question: this is the screen Claude is looking at.
    func newTurn(screen: ScreenCapture.ScreenGeometry, elements: [ScreenElement]) {
        self.screen = screen
        self.elements = elements
        listIsCurrent = true
        steps = 0
        actedThisTurn = false
        looksThisTurn = 0
        isStopped = false
        log = []
        lookedAt = nil
    }

    // MARK: Tools

    static let tools: [ToolServer.Tool] = {
        func schema(_ properties: [String: Any], required: [String] = []) -> [String: Any] {
            ["type": "object", "properties": properties, "required": required]
        }
        let status: [String: Any] = [
            "type": "string",
            "description": "Three to six words said out loud while you do this, like \"Going to your chat with Rahul\". "
                + "Leave it out for small in-between steps.",
        ]
        let irreversible: [String: Any] = [
            "type": "boolean",
            "description": "True if this sends, posts, deletes or buys something. The app asks the user first.",
        ]
        return [
            .init(name: "find_files", description: "Searches the whole Mac instantly, without touching the screen: names, folders and the "
                  + "words inside documents, best match first. It forgives small spelling mistakes. "
                  + "For a type of app, like terminals or browsers, use kind \"app\" with no query, then pick from that full list.",
                  schema: schema([
                      "query": ["type": "string", "description": "Words from the name. Put everything you'd try in one search, separated "
                                + "by commas, like \"aadhaar, aadhar, uidai\"."],
                      "kind": ["type": "string", "enum": ["any", "app", "folder"]],
                  ])),
            .init(name: "open_file", description: "Opens a file or folder in its usual app, using a path from find_files. For apps, use open_app.",
                  schema: schema(["path": ["type": "string"]], required: ["path"])),
            .init(name: "system_info", description: "The date and time, this Mac's chip and memory, battery, free storage, and which apps are open.",
                  schema: schema([:])),
            .init(name: "read_page", description: "Reads all the words in the front window, including parts scrolled out of view, "
                  + "without touching anything. Much cheaper than look. Works best on web pages and documents.", schema: schema([:])),
            .init(name: "browser_tabs", description: "Lists Chrome's tabs in the front window, switches to one, or closes exactly the ones you name. "
                  + "List first, then use those numbers.",
                  schema: schema([
                      "action": ["type": "string", "enum": ["list", "switch", "close"]],
                      "tabs": ["type": "array", "items": ["type": "integer"], "description": "Tab numbers from the list."],
                      "status": status,
                  ], required: ["action"])),
            .init(name: "remember", description: "Saves one fact about the user, with related details together, like \"Sam Lee, 30, birthday 2 June\". "
                  + "The user can see and delete it in Case's window.",
                  schema: schema(["fact": ["type": "string"]], required: ["fact"])),
            .init(name: "forget", description: "Deletes one fact. Use its exact words from the list of what you remember.",
                  schema: schema(["fact": ["type": "string"]], required: ["fact"])),
            .init(name: "meeting_notes", description: "Starts, pauses, resumes or stops transcribing a meeting. Stopping writes up the notes.",
                  schema: schema(["action": ["type": "string", "enum": ["start", "pause", "resume", "stop"]]], required: ["action"])),
            .init(name: "look", description: "Takes a fresh screenshot and lists what's on screen with new numbers. "
                  + "Use it after the screen changes and before clicking anything new.", schema: schema([:])),
            .init(name: "open_app", description: "Opens an app by name, like Spotify or WhatsApp, and brings it to the front.",
                  schema: schema(["name": ["type": "string"]], required: ["name"])),
            .init(name: "close_app", description: "Quits an app by name, the same as choosing Quit from its menu. "
                  + "Most apps just close. An app with unsaved work may show its own save question, which the user answers.",
                  schema: schema(["name": ["type": "string"]], required: ["name"])),
            .init(name: "open_url", description: "Opens a web address in the browser, or a link into an app (spotify, whatsapp, notion, slack, zoommtg). "
                  + "To put a search on screen, open the results page directly.",
                  schema: schema(["url": ["type": "string"]], required: ["url"])),
            .init(name: "click", description: "Clicks something on screen: a number from the latest list, or x,y in the latest screenshot.",
                  schema: schema([
                      "element": ["type": "integer"], "x": ["type": "number"], "y": ["type": "number"],
                      "what": ["type": "string", "description": "What you're clicking, like \"the Send button\"."],
                      "status": status, "irreversible": irreversible,
                  ], required: ["what"])),
            .init(name: "write", description: "Types text into the box that has focus (click the box first). It never presses Enter.",
                  schema: schema(["text": ["type": "string"], "status": status], required: ["text"])),
            .init(name: "press_keys", description: "Presses a key or shortcut, like \"return\", \"tab\", \"escape\", \"down\" or \"cmd+t\".",
                  schema: schema([
                      "keys": ["type": "string"],
                      "what": ["type": "string", "description": "What it does, like \"send the message\"."],
                      "status": status, "irreversible": irreversible,
                  ], required: ["keys"])),
            .init(name: "scroll", description: "Scrolls the screen, or a numbered element from the latest list.",
                  schema: schema([
                      "direction": ["type": "string", "enum": ["up", "down", "left", "right"]],
                      "amount": ["type": "integer", "description": "1 to 30, default 3. Use 30 to go all the way to the top or bottom."],
                      "element": ["type": "integer"], "status": status,
                  ], required: ["direction"])),
        ]
    }()

    /// What to tell the user as a step starts: the app's own words for opening and closing,
    /// otherwise the status Claude gave the step.
    private static func progress(_ name: String, _ arguments: [String: Any]) -> String? {
        let app = (arguments["name"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        switch name {
        case "find_files": return "Searching your Mac."
        case "read_page": return "Reading the page."
        case "open_file": return (arguments["path"] as? String).map { "Opening \(URL(fileURLWithPath: $0).lastPathComponent)." }
        case "open_app" where !app.isEmpty: return "Opening \(app)."
        case "close_app" where !app.isEmpty: return "Closing \(app)."
        case "open_url":
            let host = (arguments["url"] as? String).flatMap { URL(string: $0)?.host() }
            return host.map { "Opening \($0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0)." } ?? "Opening the page."
        default:
            guard let status = (arguments["status"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !status.isEmpty else { return nil }
            return ".!?".contains(status.last!) ? status : status + "."
        }
    }

    func call(_ name: String, _ arguments: [String: Any]) async -> ToolServer.Result {
        guard !isStopped else { return Self.refuse("The user stopped this. Don't continue.") }
        // Looking is free; only actions count toward the limit.
        if !Self.readOnly.contains(name) { steps += 1 }
        guard steps <= Self.maxSteps else {
            return Self.refuse("That's the most steps allowed for one request. Stop and tell the user what's left to do.")
        }

        if let line = Self.progress(name, arguments) { onProgress(line) }
        let result: ToolServer.Result
        switch name {
        case "look": result = await look()
        case "find_files":
            result = ToolServer.Result(text: await MacTools.findFiles(arguments["query"] as? String ?? "", kind: arguments["kind"] as? String ?? "any"))
        case "open_file": result = await openFile(arguments["path"] as? String ?? "")
        case "system_info": result = ToolServer.Result(text: await MacTools.systemInfo())
        case "read_page": result = await readPage()
        case "browser_tabs":
            listIsCurrent = false
            result = await MacTools.chromeTabs(action: arguments["action"] as? String ?? "list", tabs: arguments["tabs"] as? [Int] ?? [])
        case "remember":
            let saved = memory?.add(arguments["fact"] as? String ?? "") ?? false
            result = ToolServer.Result(text: saved ? "Saved." : "Already saved, or there was nothing to save.")
        case "forget":
            let forgotten = memory?.forget(arguments["fact"] as? String ?? "") ?? false
            result = forgotten ? ToolServer.Result(text: "Forgotten.") : Self.refuse("That isn't on the list. Use its exact words.")
        case "meeting_notes": result = ToolServer.Result(text: meetingNotes(arguments["action"] as? String ?? ""))
        case "open_app": result = await openApp(arguments["name"] as? String ?? "")
        case "open_url": result = await openURL(arguments["url"] as? String ?? "")
        case "close_app": result = await closeApp(arguments["name"] as? String ?? "")
        case "click": result = await click(arguments)
        case "write": result = await write(arguments["text"] as? String ?? "")
        case "press_keys": result = await pressKeys(arguments)
        case "scroll": result = await scroll(arguments)
        default: result = Self.refuse("Unknown tool.")
        }
        if !Self.readOnly.contains(name) { actedThisTurn = true }
        log.append("\(name) \(Self.brief(arguments)) → \(result.isError ? "REFUSED/FAILED: " : "")\(result.text.prefix(160))")
        return result
    }

    // MARK: Look

    private func look() async -> ToolServer.Result {
        do {
            let screen = try ScreenCapture.screenUnderCursor()
            let app = NSWorkspace.shared.frontmostApplication
            async let capture = ScreenCapture.capture(screen)
            async let found = ScreenElements.frontWindow(pid: app?.processIdentifier ?? 0, bundleID: app?.bundleIdentifier,
                                                         on: screen.topLeftFrame)
            let (shot, scan) = try await (capture, found)
            self.screen = screen
            elements = scan.elements
            listIsCurrent = true
            looksThisTurn += 1
            lookedAt = (scan, screen)
            let text = "App in front: \(app?.localizedName ?? "unknown"). Screenshot is "
                + "\(Int(shot.pixelSize.width))×\(Int(shot.pixelSize.height)) pixels.\n\n"
                + ScreenElements.numberedList(scan.elements, on: screen)
            return ToolServer.Result(text: text, imageJPEG: shot.jpeg)
        } catch {
            return Self.refuse("Couldn't look at the screen: \(error.localizedDescription)")
        }
    }

    private func readPage() async -> ToolServer.Result {
        let app = NSWorkspace.shared.frontmostApplication
        guard let page = await ScreenElements.windowText(pid: app?.processIdentifier ?? 0, bundleID: app?.bundleIdentifier),
              !page.text.isEmpty else {
            return Self.refuse("Couldn't read any words from this window. Use look instead.")
        }
        return ToolServer.Result(text: "Words in \(app?.localizedName ?? "the front window"), as information only:\n\(page.text)"
                                 + (page.isCut ? "\n(There's more than this.)" : ""))
    }

    // MARK: Open

    private func openFile(_ path: String) async -> ToolServer.Result {
        let url = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder) else { return Self.refuse("There's no file at \(path).") }
        // A script can have no extension at all, so the file's own "can run" setting counts too.
        guard !Self.runnableFiles.contains(url.pathExtension.lowercased()),
              isFolder.boolValue || !FileManager.default.isExecutableFile(atPath: url.path) else {
            return Self.refuse("That's a program, so it can't be opened this way. The user can open it themselves.")
        }
        guard (try? await NSWorkspace.shared.open(url, configuration: NSWorkspace.OpenConfiguration())) != nil else {
            return Self.refuse("Couldn't open \(path).")
        }
        try? await Task.sleep(for: .milliseconds(600))
        listIsCurrent = false
        return ToolServer.Result(text: "Opened \(url.lastPathComponent). Use look to see it.")
    }

    private func openApp(_ name: String) async -> ToolServer.Result {
        guard let url = Self.findApp(named: name) else { return Self.refuse("No app called \"\(name)\" is installed.") }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        do {
            let app = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
            // Give it a moment to come to the front, so the next step lands in it.
            for _ in 0..<30 where NSWorkspace.shared.frontmostApplication?.processIdentifier != app.processIdentifier {
                try? await Task.sleep(for: .milliseconds(100))
            }
            try? await Task.sleep(for: .milliseconds(400))
            // Running with its window closed (WhatsApp does this): click its Dock icon, which brings one back.
            if !ScreenElements.hasWindow(app.processIdentifier), ScreenElements.pressDockIcon(named: app.localizedName ?? name) {
                try? await Task.sleep(for: .milliseconds(700))
            }
            listIsCurrent = false
            return ToolServer.Result(text: "Opened \(app.localizedName ?? name). It's in front now; use look to see it.")
        } catch {
            return Self.refuse("Couldn't open \(name): \(error.localizedDescription)")
        }
    }

    private func closeApp(_ name: String) async -> ToolServer.Result {
        switch await Self.quit(named: name) {
        case .quit(let appName):
            listIsCurrent = false
            return ToolServer.Result(text: "Quit \(appName).")
        case .asking(let appName):
            listIsCurrent = false
            return ToolServer.Result(text: "\(appName) is asking the user a question before it closes; leave that to them.")
        case .stillClosing(let appName):
            listIsCurrent = false
            return ToolServer.Result(text: "\(appName) is still closing.")
        case .notRunning:
            return ToolServer.Result(text: "\(name) isn't open.")
        }
    }

    enum QuitOutcome {
        case quit(String)
        /// It's showing its own question, like "Save changes?".
        case asking(String)
        /// It's taking a while, but hasn't asked anything.
        case stillClosing(String)
        case notRunning
    }

    /// Quits a running app politely, like its Quit menu item. Never force-quits, so apps with
    /// unsaved work get to ask about saving. Most apps have nothing to ask and just close.
    static func quit(named name: String) async -> QuitOutcome {
        guard let app = runningApp(named: name) else { return .notRunning }

        let appName = app.localizedName ?? name
        app.terminate()
        for _ in 0..<25 where !app.isTerminated {
            try? await Task.sleep(for: .milliseconds(200))
            if ScreenElements.isAsking(app.processIdentifier) { return .asking(appName) }
        }
        return app.isTerminated ? .quit(appName) : .stillClosing(appName)
    }

    /// An open app (with a window in the Dock) matching "spotify", "whatsapp", "settings".
    static func runningApp(named name: String) -> NSRunningApplication? {
        func simple(_ text: String) -> String { text.lowercased().filter { $0.isLetter || $0.isNumber } }
        let wanted = simple(name)
        guard !wanted.isEmpty else { return nil }
        let named = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
            .map { (app: $0, name: simple($0.localizedName ?? "")) }
        return named.first { $0.name == wanted }?.app
            ?? named.filter { $0.name.hasPrefix(wanted) }.min { $0.name.count < $1.name.count }?.app
            ?? named.filter { wanted.count >= 4 && $0.name.contains(wanted) }.min { $0.name.count < $1.name.count }?.app
    }

    private func openURL(_ address: String) async -> ToolServer.Result {
        var address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let isAppLink = URL(string: address)?.scheme.map { Self.linkSchemes.contains($0.lowercased()) } == true
        if !address.contains("://"), !isAppLink { address = "https://" + address }
        guard let url = URL(string: address), let scheme = url.scheme?.lowercased(), Self.linkSchemes.contains(scheme) else {
            return Self.refuse("Only web addresses and app links can be opened.")
        }
        NSWorkspace.shared.open(url)
        try? await Task.sleep(for: .seconds(1))
        listIsCurrent = false
        return ToolServer.Result(text: "Opened \(url.absoluteString); use look to see it.")
    }

    /// Matches "spotify", "WhatsApp", "system settings" to an installed app.
    nonisolated static func findApp(named name: String) -> URL? {
        func simple(_ text: String) -> String {
            text.lowercased().replacingOccurrences(of: ".app", with: "").filter { $0.isLetter || $0.isNumber }
        }
        let wanted = simple(name)
        guard !wanted.isEmpty else { return nil }
        let folders = ["/Applications", "/Applications/Utilities", "/System/Applications", "/System/Applications/Utilities",
                       NSHomeDirectory() + "/Applications", "/System/Library/CoreServices"]
        let apps = folders.flatMap { folder in
            ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? [])
                .filter { $0.hasSuffix(".app") }
                .map { URL(fileURLWithPath: folder).appending(path: $0) }
        }
        let named = apps.map { (url: $0, name: simple($0.deletingPathExtension().lastPathComponent)) }
        return named.first { $0.name == wanted }?.url
            ?? named.filter { $0.name.hasPrefix(wanted) }.min { $0.name.count < $1.name.count }?.url
            ?? named.filter { $0.name.contains(wanted) && wanted.count >= 4 }.min { $0.name.count < $1.name.count }?.url
    }

    // MARK: Click

    private func click(_ arguments: [String: Any]) async -> ToolServer.Result {
        let what = arguments["what"] as? String ?? "that"
        guard listIsCurrent, let screen else {
            return Self.refuse("The screen has changed since the last list. Use look first, then use the new numbers.")
        }
        let frame: CGRect
        if let number = arguments["element"] as? Int {
            guard elements.indices.contains(number - 1) else { return Self.refuse("There's no #\(number) in the latest list.") }
            frame = elements[number - 1].frame
        } else if let x = Self.number(arguments["x"]), let y = Self.number(arguments["y"]) {
            let point = screen.topLeftPoint(fromPixel: CGPoint(x: x, y: y))
            frame = CGRect(origin: point, size: .zero)
        } else {
            return Self.refuse("Give an element number or x and y.")
        }
        let point = CGPoint(x: frame.midX, y: frame.midY)

        // Find what's there before the buddy flies over it.
        let target = withOverlaysHidden { ScreenElements.inspect(at: point) }
        log.append("  target: \(ScreenElements.describe(target))")
        guard !target.isOurs else { return Self.refuse("That spot is covered by a Case window; try look again.") }

        if arguments["irreversible"] as? Bool == true || Self.needsOK(click: target, what: what) {
            let request = ConfirmCard.Request(title: "Click \(what)\(target.appName.isEmpty ? "" : " in \(target.appName)")?",
                                              detail: nil, action: Self.verb(for: [what] + target.words))
            guard await confirmKeepingFocus(request) else { return Self.refuse("The user said no, so it wasn't clicked.") }
        }

        await tap(screen.appKitRect(fromTopLeft: target.frame ?? frame))
        guard !isStopped else { return Self.refuse("The user stopped this. Don't continue.") }
        let pressed = target.element.map(ScreenElements.press) ?? false
        if !pressed { Self.realClick(at: point) }
        log.append("  \(pressed ? "pressed through accessibility" : "real mouse click")")
        listIsCurrent = false
        try? await Task.sleep(for: .milliseconds(350))
        return ToolServer.Result(text: "Clicked \(what)\(pressed ? "" : " (with the mouse)"). Use look to see what changed.")
    }

    // MARK: Write

    private func write(_ text: String) async -> ToolServer.Result {
        let focus = ScreenElements.focus()
        guard !focus.isSecure, !IsSecureEventInputEnabled() else {
            return Self.refuse("That's a password box, and Case never types passwords. Ask the user to type it.")
        }
        guard !text.isEmpty else { return Self.refuse("There's nothing to write.") }
        // A new line pasted into a terminal runs the command, so lines are joined there.
        let inTerminal = Self.terminals.contains(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "")
        let joined = inTerminal && text.contains(where: \.isNewline)
        await Self.paste(joined ? text.split(whereSeparator: \.isNewline).joined(separator: " ") : text)
        listIsCurrent = false
        return ToolServer.Result(text: "Wrote it\(focus.isTextBox ? "" : " (no text box seemed focused; check with look)"). "
                                 + (joined ? "It's a terminal, so the lines were joined into one. " : "")
                                 + "Nothing has been sent.")
    }

    /// Pastes in one go (fast, and fine with emoji and Hindi), then puts your clipboard back.
    private static func paste(_ text: String) async {
        let pasteboard = NSPasteboard.general
        let saved = (pasteboard.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        post(key: CGKeyCode(kVK_ANSI_V), flags: .maskCommand)
        try? await Task.sleep(for: .milliseconds(500))
        pasteboard.clearContents()
        let items = saved.map { pairs in
            let item = NSPasteboardItem()
            pairs.forEach { item.setData($0.1, forType: $0.0) }
            return item
        }
        if !items.isEmpty { pasteboard.writeObjects(items) }
    }

    // MARK: Keys

    private func pressKeys(_ arguments: [String: Any]) async -> ToolServer.Result {
        let keys = (arguments["keys"] as? String ?? "").lowercased()
        guard let (key, flags) = Self.parse(keys) else { return Self.refuse("I don't know the key \"\(keys)\".") }
        // ⌘Q quits whatever happens to be in front; close_app quits the app you mean.
        if key == CGKeyCode(kVK_ANSI_Q) && flags.contains(.maskCommand) {
            return Self.refuse("Use close_app with the app's name instead of cmd+q.")
        }

        let focus = ScreenElements.focus()
        let app = NSWorkspace.shared.frontmostApplication
        log.append("  keys in \(app?.localizedName ?? "?") (\(app?.bundleIdentifier ?? "?")), focus \(focus.role) \(focus.subrole)")
        if arguments["irreversible"] as? Bool == true || Self.needsOK(key: key, flags: flags, focus: focus, app: app) {
            let what = arguments["what"] as? String
            let title = "\(what.map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? "Press \(keys)")\(app?.localizedName.map { " in \($0)" } ?? "")?"
            let request = ConfirmCard.Request(title: title, detail: focus.text.isEmpty ? nil : String(focus.text.prefix(200)),
                                              action: Self.verb(for: [what ?? keys]))
            guard await confirmKeepingFocus(request) else { return Self.refuse("The user said no, so nothing was pressed.") }
        }

        Self.post(key: key, flags: flags)
        listIsCurrent = false
        try? await Task.sleep(for: .milliseconds(300))
        return ToolServer.Result(text: "Pressed \(keys). Use look to see what changed.")
    }

    // MARK: Scroll

    private func scroll(_ arguments: [String: Any]) async -> ToolServer.Result {
        let direction = arguments["direction"] as? String ?? "down"
        let amount = min(max(arguments["amount"] as? Int ?? 3, 1), 30)
        var spot: CGPoint?
        if let number = arguments["element"] as? Int {
            guard listIsCurrent, elements.indices.contains(number - 1) else {
                return Self.refuse("Use look first, then scroll using the new numbers.")
            }
            spot = CGPoint(x: elements[number - 1].frame.midX, y: elements[number - 1].frame.midY)
        }
        listIsCurrent = false

        let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
        let area = await ScreenElements.scrollArea(pid: pid, at: spot)
        if let bar = ["up", "down"].contains(direction) ? area?.vertical : area?.horizontal,
           let moved = await ScreenElements.move(bar, forward: ["down", "right"].contains(direction), amount: amount) {
            return ToolServer.Result(text: moved ? "Scrolled \(direction). Use look to see the new view."
                                                 : "It's already as far \(direction) as it goes.")
        }

        // Web pages have no scroll bar to move, so it's the mouse wheel there, aimed at what's in
        // front and not whatever the mouse happens to be over.
        let mouse = CGEvent(source: nil)?.location ?? .zero
        let window = ScreenElements.frontWindowFrame(pid)
        let inFront = spot ?? area.map { CGPoint(x: $0.frame.midX, y: $0.frame.midY) }
            ?? window.flatMap { $0.contains(mouse) ? mouse : CGPoint(x: $0.midX, y: $0.midY) } ?? mouse
        await Self.wheel(direction, amount: amount, at: inFront)
        return ToolServer.Result(text: "Tried to scroll \(direction), but can't tell if it moved. Use look to check.")
    }

    /// Small steps, like a real wheel. The event takes the pointer with it, so it goes back afterwards.
    private static func wheel(_ direction: String, amount: Int, at location: CGPoint) async {
        let original = CGEvent(source: nil)?.location
        let (vertical, horizontal): (Int32, Int32) = switch direction {
        case "up": (3, 0)
        case "left": (0, 3)
        case "right": (0, -3)
        default: (-3, 0)
        }
        for _ in 0..<amount {
            let event = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 2, wheel1: vertical, wheel2: horizontal, wheel3: 0)
            event?.location = location
            event?.post(tap: .cghidEventTap)
            try? await Task.sleep(for: .milliseconds(12))
        }
        try? await Task.sleep(for: .milliseconds(40))
        if let original, original != location { CGWarpMouseCursorPosition(original) }
    }

    // MARK: Safety

    private static let riskyWords = ["send", "post", "publish", "tweet", "reply all", "submit", "delete", "remove", "trash",
                                     "erase", "buy", "pay", "purchase", "order", "checkout", "check out", "subscribe", "place order"]
    /// Apps where an unlabelled button or Enter in a text box usually sends something.
    private static let messagingApps = ["net.whatsapp.WhatsApp", "com.apple.MobileSMS", "com.tinyspeck.slackmacgap",
                                        "ru.keepcoder.Telegram", "com.hnc.Discord", "com.apple.mail", "com.microsoft.teams2",
                                        "org.whispersystems.signal-desktop", "com.microsoft.Outlook", "com.facebook.archon"]
    /// Apps where Enter runs a command, and a pasted new line counts as Enter.
    private static let terminals = ["com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "dev.warp.Warp-Stable",
                                     "net.kovidgoyal.kitty", "org.alacritty", "com.github.wez.wezterm", "co.zeit.hyper"]
    private static let browsers = ["com.google.Chrome", "com.apple.Safari", "company.thebrowser.Browser", "com.brave.Browser",
                                    "com.microsoft.edgemac", "org.mozilla.firefox"]

    private static func needsOK(click target: ScreenElements.Target, what: String) -> Bool {
        if containsRiskyWord([what] + target.words) { return true }
        // An icon-only button in a chat or mail app is often Send.
        return target.role == "AXButton" && target.words.isEmpty && messagingApps.contains(target.bundleID)
    }

    private static func needsOK(key: CGKeyCode, flags: CGEventFlags, focus: ScreenElements.Focus, app: NSRunningApplication?) -> Bool {
        let bundleID = app?.bundleIdentifier ?? ""
        let isEnter = key == CGKeyCode(kVK_Return) || key == CGKeyCode(kVK_ANSI_KeypadEnter)
        if isEnter && flags.contains(.maskCommand) { return true }
        // In chat and mail apps every Enter may send, whatever the message box reports itself as.
        if isEnter && messagingApps.contains(bundleID) { return true }
        // Enter in a terminal runs whatever is typed there, which could delete things.
        if isEnter && terminals.contains(bundleID) { return true }
        if isEnter && focus.isTextBox && browsers.contains(bundleID) { return true }
        if key == CGKeyCode(kVK_Delete) && flags.contains(.maskCommand) && bundleID == "com.apple.finder" { return true }
        return false
    }

    /// Whole words only, so "border" doesn't count as "order" or "Postman" as "post".
    private static func containsRiskyWord(_ texts: [String]) -> Bool {
        let letters = texts.joined(separator: " ").lowercased().map { $0.isLetter ? $0 : " " }
        let text = " " + String(letters).split(separator: " ").joined(separator: " ") + " "
        return riskyWords.contains { text.contains(" \($0) ") }
    }

    private static func verb(for words: [String]) -> String {
        let text = words.joined(separator: " ").lowercased()
        for (word, verb) in [("run", "Run"), ("delete", "Delete"), ("remove", "Remove"), ("trash", "Delete"), ("buy", "Buy"), ("pay", "Pay"),
                             ("order", "Order"), ("post", "Post"), ("publish", "Publish"), ("submit", "Submit")]
        where text.contains(word) {
            return verb
        }
        if text.contains("send") { return "Send" }
        return "Continue"
    }

    /// Shows the card, then puts the app you were in back in front, so the next key lands there.
    private func confirmKeepingFocus(_ request: ConfirmCard.Request) async -> Bool {
        let app = NSWorkspace.shared.frontmostApplication
        let confirmed = await confirm(request)
        log.append("  confirm card \"\(request.title)\" → \(confirmed ? "yes" : "no")")
        guard confirmed, !Task.isCancelled, !isStopped else { return false }
        app?.activate()
        try? await Task.sleep(for: .milliseconds(200))
        return true
    }

    // MARK: Keyboard and mouse events

    private static let keyCodes: [String: Int] = [
        "return": kVK_Return, "enter": kVK_Return, "tab": kVK_Tab, "escape": kVK_Escape, "esc": kVK_Escape,
        "space": kVK_Space, "delete": kVK_Delete, "backspace": kVK_Delete, "forwarddelete": kVK_ForwardDelete,
        "up": kVK_UpArrow, "down": kVK_DownArrow, "left": kVK_LeftArrow, "right": kVK_RightArrow,
        "home": kVK_Home, "end": kVK_End, "pageup": kVK_PageUp, "pagedown": kVK_PageDown,
        "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D, "e": kVK_ANSI_E, "f": kVK_ANSI_F,
        "g": kVK_ANSI_G, "h": kVK_ANSI_H, "i": kVK_ANSI_I, "j": kVK_ANSI_J, "k": kVK_ANSI_K, "l": kVK_ANSI_L,
        "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O, "p": kVK_ANSI_P, "q": kVK_ANSI_Q, "r": kVK_ANSI_R,
        "s": kVK_ANSI_S, "t": kVK_ANSI_T, "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X,
        "y": kVK_ANSI_Y, "z": kVK_ANSI_Z, "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3,
        "4": kVK_ANSI_4, "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7, "8": kVK_ANSI_8, "9": kVK_ANSI_9,
        ",": kVK_ANSI_Comma, ".": kVK_ANSI_Period, "/": kVK_ANSI_Slash, "-": kVK_ANSI_Minus, "=": kVK_ANSI_Equal,
        "[": kVK_ANSI_LeftBracket, "]": kVK_ANSI_RightBracket, ";": kVK_ANSI_Semicolon, "'": kVK_ANSI_Quote,
    ]

    /// "cmd+shift+t" → the T key with Command and Shift.
    private static func parse(_ keys: String) -> (CGKeyCode, CGEventFlags)? {
        var flags: CGEventFlags = []
        var key: CGKeyCode?
        for part in keys.replacingOccurrences(of: " ", with: "").split(separator: "+").map(String.init) {
            switch part {
            case "cmd", "command", "⌘": flags.insert(.maskCommand)
            case "shift", "⇧": flags.insert(.maskShift)
            case "option", "opt", "alt", "⌥": flags.insert(.maskAlternate)
            case "ctrl", "control", "⌃": flags.insert(.maskControl)
            default:
                guard let code = keyCodes[part] else { return nil }
                key = CGKeyCode(code)
            }
        }
        return key.map { ($0, flags) }
    }

    private static func post(key: CGKeyCode, flags: CGEventFlags) {
        if key == escapeKey { pressedEscapeAt = .now }
        let source = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down)
            event?.flags = flags
            event?.post(tap: .cghidEventTap)
        }
    }

    /// A real click, for things accessibility can't press. The mouse is put back where it was.
    private static func realClick(at point: CGPoint) {
        let original = CGEvent(source: nil)?.location
        let source = CGEventSource(stateID: .hidSystemState)
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?
                .post(tap: .cghidEventTap)
            usleep(30_000)
        }
        if let original { CGWarpMouseCursorPosition(original) }
    }

    // MARK: Helpers

    private static func refuse(_ text: String) -> ToolServer.Result {
        ToolServer.Result(text: text, isError: true)
    }

    private static func number(_ value: Any?) -> Double? {
        (value as? Double) ?? (value as? Int).map(Double.init)
    }

    /// Arguments for the log, with long text shortened.
    private static func brief(_ arguments: [String: Any]) -> String {
        arguments.map { key, value in
            let text = "\(value)"
            return "\(key)=\(text.count > 60 ? text.prefix(60) + "…" : text)"
        }.sorted().joined(separator: " ")
    }
}
