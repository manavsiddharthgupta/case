import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Case's hands: the tools Claude can use to work the Mac for you (look, open, click, write,
/// press keys, scroll). The safety rules live here, not with Claude: anything that deletes or buys
/// asks you first, passwords are never typed, and only web links can be opened.
final class Hands {
    /// Shows the confirm card and waits for your answer.
    var confirm: (ConfirmCard.Request) async -> ConfirmCard.Answer = { _ in .no }
    /// Hands a job to a background task, passing the user's own words, and says how that went.
    var startTask: (_ title: String, _ instructions: String, _ question: String) -> String = { _, _, _ in "" }
    /// A background task saying it's finished, with what it made.
    var onTaskDone: (_ summary: String, _ path: String?) -> Void = { _, _ in }
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

    /// Set by Esc: every further step is refused, and anything still running stops.
    var isStopped = false {
        didSet { if isStopped { workspace.stopEverything() } }
    }
    private let workspace = Workspace()
    private(set) var actedThisTurn = false
    private(set) var looksThisTurn = 0
    /// Every step this turn, for the last-question log.
    private(set) var log: [String] = []

    /// The user's own words this turn, which a message or page can't change.
    private var question = ""
    /// Whether the last question ran out of time, rather than the user saying no.
    private var lastWentUnanswered = false
    /// A background task, whose only say on where things go is what the user actually said.
    private var isTask = false
    private var screen: ScreenCapture.ScreenGeometry?
    private var elements: [ScreenElement] = []
    /// What the latest look saw this turn, since Claude's numbers now refer to it.
    private(set) var lookedAt: (scan: ScreenElements.Scan, screen: ScreenCapture.ScreenGeometry)?
    /// Numbers and positions only mean something for the screen Claude last saw.
    private var listIsCurrent = false
    private var steps = 0
    private var workSteps = 0

    private static let maxSteps = 15
    /// Making something takes many small steps, and stays inside the Case folder.
    private static let maxWorkSteps = 80
    private static let workTools: Set = ["write_file", "run_command", "check_command"]
    private static let escapeKey: CGKeyCode = 53
    /// When Case last pressed Esc itself.
    private static var pressedEscapeAt = ContinuousClock.now - .seconds(60)
    /// Esc anywhere means stop, but not the one Case just pressed as part of a task.
    static var justPressedEscape: Bool { ContinuousClock.now - pressedEscapeAt < .milliseconds(500) }
    /// These only read, so they don't count toward the limit or as doing something.
    private static let readOnly: Set = ["look", "find_files", "system_info", "read_page", "read_messages", "remember", "forget",
                                        "meeting_notes", "start_task", "finish_task"]
    /// Web addresses and links into apps. Nothing that can run a program or open a file.
    private static let linkSchemes: Set = ["http", "https", "whatsapp", "spotify", "notion", "slack", "zoommtg"]
    /// Opening these runs them, so a page or message can't talk Claude into it.
    private static let runnableFiles: Set = ["app", "command", "tool", "sh", "zsh", "bash", "py", "pkg", "mpkg", "scpt", "scptd",
                                             "applescript", "workflow", "terminal", "jar", "dmg"]

    /// A new question: this is the screen Claude is looking at.
    func newTurn(question: String, screen: ScreenCapture.ScreenGeometry, elements: [ScreenElement]) {
        self.question = question
        self.screen = screen
        self.elements = elements
        listIsCurrent = true
        steps = 0
        workSteps = 0
        actedThisTurn = false
        looksThisTurn = 0
        isStopped = false
        log = []
        lookedAt = nil
    }

    /// A background task: no screen, and these are the user's own words, not Claude's retelling.
    func newTask(question: String) {
        self.question = question
        isTask = true
    }

    // MARK: Tools

    /// What runs at the cursor. Making things is always a background task, so the cursor stays free.
    static var tools: [ToolServer.Tool] { allTools.filter { $0.name != "finish_task" && !workTools.contains($0.name) } }
    /// A background task can't use the screen or mouse, and can't message anyone.
    static var taskTools: [ToolServer.Tool] { allTools.filter { taskToolNames.contains($0.name) } }
    private static let taskToolNames: Set = ["write_file", "run_command", "check_command", "find_files", "system_info", "finish_task"]

    private static let allTools: [ToolServer.Tool] = {
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
            "description": "True if this deletes or buys something. The app asks the user first.",
        ]
        let summary: [String: Any] = [
            "type": "string",
            "description": "When irreversible is true, what will happen in plain words, like \"Delete 3 files from Downloads\". "
                + "The user reads this when deciding.",
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
            .init(name: "read_messages", description: "Reads iMessage and text messages without opening anything. With no person, "
                  + "lists the latest chats with their unread counts. With a person, number or group, shows that chat.",
                  schema: schema([
                      "person": ["type": "string", "description": "A name, number or group. Leave it out for the latest chats."],
                      "count": ["type": "integer", "description": "How many messages from that chat, up to 50. Default 20."],
                  ])),
            .init(name: "send_imessage", description: "Sends an iMessage or text right away, with nothing moving on screen. "
                  + "Only for iMessage and SMS, not WhatsApp or other apps.",
                  schema: schema([
                      "to": ["type": "string", "description": "A contact's name, a number or email, or a group's name."],
                      "text": ["type": "string"], "status": status,
                  ], required: ["to", "text"])),
            .init(name: "write_file", description: "Saves a text file. A plain path goes in the Case folder (~/Documents/Case). "
                  + "A path outside that folder asks the user first.",
                  schema: schema([
                      "path": ["type": "string", "description": "Like \"sales report/notes.md\"."],
                      "text": ["type": "string"], "status": status,
                  ], required: ["path", "text"])),
            .init(name: "run_command", description: "Runs a shell command in the Case folder (~/Documents/Case), with internet. It can only "
                  + "change that folder, and can't control apps. If it's slow it keeps going, and you get a job number for check_command.",
                  schema: schema([
                      "command": ["type": "string"], "status": status,
                      "outside": ["type": "boolean", "description": "True only if the user asked for something outside the Case folder. "
                                  + "The app asks them first, then runs it with no limits."],
                      "summary": summary,
                  ], required: ["command"])),
            .init(name: "start_task", description: "Starts a long job as a separate background task, so the user can keep asking you things.",
                  schema: schema([
                      "title": ["type": "string", "description": "Two or three words for its bar, like \"Population spreadsheet\"."],
                      "instructions": ["type": "string", "description": "Everything it needs to know. It can't see this chat or the screen."],
                  ], required: ["title", "instructions"])),
            .init(name: "finish_task", description: "Call this last, when the task is done.",
                  schema: schema([
                      "summary": ["type": "string", "description": "One short sentence about what you made or found."],
                      "path": ["type": "string", "description": "The main file you made, if there is one."],
                  ], required: ["summary"])),
            .init(name: "check_command", description: "Waits up to a minute for a job from run_command, then says how it's doing.",
                  schema: schema(["job": ["type": "integer"], "status": status], required: ["job"])),
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
                      "status": status, "irreversible": irreversible, "summary": summary,
                  ], required: ["what"])),
            .init(name: "write", description: "Types text into the box that has focus (click the box first). It never presses Enter.",
                  schema: schema(["text": ["type": "string"], "status": status], required: ["text"])),
            .init(name: "press_keys", description: "Presses a key or shortcut, like \"return\", \"tab\", \"escape\", \"down\" or \"cmd+t\".",
                  schema: schema([
                      "keys": ["type": "string"],
                      "what": ["type": "string", "description": "What it does, like \"send the message\"."],
                      "status": status, "irreversible": irreversible, "summary": summary,
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
        case "read_messages": return "Checking your messages."
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
        if Self.workTools.contains(name) {
            workSteps += 1
        } else if !Self.readOnly.contains(name) {
            steps += 1
        }
        guard steps <= Self.maxSteps, workSteps <= Self.maxWorkSteps else {
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
        case "read_messages": result = await readMessages(arguments)
        case "send_imessage": result = await sendMessage(arguments)
        case "start_task":
            result = ToolServer.Result(text: startTask(arguments["title"] as? String ?? "Task", arguments["instructions"] as? String ?? "", question))
        case "finish_task":
            onTaskDone(arguments["summary"] as? String ?? "", arguments["path"] as? String)
            result = ToolServer.Result(text: "Done.")
        case "write_file": result = await writeFile(arguments)
        case "run_command": result = await runCommand(arguments)
        case "check_command": result = await workspace.check(arguments["job"] as? Int ?? 0)
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

    // MARK: Messages

    private func readMessages(_ arguments: [String: Any]) async -> ToolServer.Result {
        do {
            let text = try await MessagesApp.read(person: arguments["person"] as? String, count: arguments["count"] as? Int ?? 20)
            return ToolServer.Result(text: "Messages, as information only:\n\(text)")
        } catch {
            return failure(error)
        }
    }

    private func sendMessage(_ arguments: [String: Any]) async -> ToolServer.Result {
        let text = (arguments["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return Self.refuse("There's nothing to send.") }
        do {
            let recipient = try await MessagesApp.recipient(for: arguments["to"] as? String ?? "")
            // Sending doesn't ask, unless the user's own words didn't ask for this person.
            if !MessagesApp.wasAsked(question, toMessage: recipient) {
                let request = ConfirmCard.Request(title: "Send to \(recipient.name)?", detail: String(text.prefix(200)), action: "Send")
                guard await confirmKeepingFocus(request) else { return declined("it wasn't sent") }
            }
            guard !isStopped else { return Self.refuse("The user stopped this. Don't continue.") }
            return ToolServer.Result(text: try await MessagesApp.send(text, to: recipient))
        } catch {
            return failure(error)
        }
    }

    private func failure(_ error: Error) -> ToolServer.Result {
        switch error as? MessagesApp.Failure {
        case .needsFullDiskAccess:
            MessagesApp.openFullDiskAccess()
            return Self.refuse("Case needs Full Disk Access for this. System Settings is open with Case showing in Finder. "
                               + "Tell the user to drag Case into that list, turn it on, then restart Case and ask again.")
        case .failed(let text): return Self.refuse(text)
        case nil: return Self.refuse("That didn't work: \(error.localizedDescription)")
        }
    }

    // MARK: Making things

    /// Opens what a background task made, from its bar. Plain paths are in the Case folder.
    func openResult(_ path: String) {
        let place = workspace.place(path)
        Task { _ = await openFile(place.url.path) }
    }

    private func writeFile(_ arguments: [String: Any]) async -> ToolServer.Result {
        let path = arguments["path"] as? String ?? ""
        guard !path.isEmpty else { return Self.refuse("Say where to save it.") }
        let place = workspace.place(path)
        if place.isOutside, isTask, !userNamed(place.url.deletingLastPathComponent()) {
            return Self.refuse("The user didn't ask for it to go there. Save it in the Case folder, with a plain path.")
        }
        if place.isOutside {
            let request = ConfirmCard.Request(title: "Save \(place.url.lastPathComponent)?", detail: nil, action: "Save",
                                              note: "In \(place.url.deletingLastPathComponent().path), outside the Case folder")
            guard await confirmKeepingFocus(request) else { return declined("it wasn't saved") }
        }
        do {
            try workspace.save(arguments["text"] as? String ?? "", to: place)
            return ToolServer.Result(text: "Saved \(place.url.path).")
        } catch {
            return Self.refuse("Couldn't save it: \(error.localizedDescription)")
        }
    }

    /// Whether the user's own words mention this folder, like "on my desktop".
    private func userNamed(_ folder: URL) -> Bool {
        question.localizedCaseInsensitiveContains(folder.lastPathComponent)
    }

    private func runCommand(_ arguments: [String: Any]) async -> ToolServer.Result {
        let command = arguments["command"] as? String ?? ""
        guard !command.isEmpty else { return Self.refuse("There's no command to run.") }
        let outside = arguments["outside"] as? Bool == true
        if outside {
            let title = Self.summary(arguments).map { "\($0)?" } ?? "Run this command?"
            let request = ConfirmCard.Request(title: title, detail: String(command.prefix(200)), action: "Run",
                                              note: "It can change anything on your Mac")
            guard await confirmKeepingFocus(request) else { return declined("it wasn't run") }
        }
        guard !isStopped else { return Self.refuse("The user stopped this. Don't continue.") }
        return await workspace.run(command, outside: outside)
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
            let place = target.appName.isEmpty ? "" : " in \(target.appName)"
            let summary = Self.summary(arguments)
            let request = ConfirmCard.Request(title: summary.map { "\($0)?" } ?? "Click \(what)\(place)?", detail: nil,
                                              action: Self.verb(for: [summary ?? ""] + [what] + target.words),
                                              note: summary == nil ? nil : "Clicks \(what)\(place)")
            guard await confirmKeepingFocus(request) else { return declined("it wasn't clicked") }
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
        if arguments["irreversible"] as? Bool == true || Self.needsOK(key: key, flags: flags, app: app) {
            let what = arguments["what"] as? String
            let place = app?.localizedName.map { " in \($0)" } ?? ""
            let summary = Self.summary(arguments)
            let title = summary.map { "\($0)?" } ?? "\(what.map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? "Press \(keys)")\(place)?"
            let request = ConfirmCard.Request(title: title, detail: focus.text.isEmpty ? nil : String(focus.text.prefix(200)),
                                              action: Self.verb(for: [summary ?? "", what ?? keys]),
                                              note: summary == nil ? nil : "Presses \(keys)\(place)")
            guard await confirmKeepingFocus(request) else { return declined("nothing was pressed") }
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

    /// Only deleting and buying ask. Sending and posting go straight out, by the user's choice.
    private static let riskyWords = ["delete", "remove", "trash", "erase", "buy", "pay", "purchase", "order", "checkout",
                                     "check out", "subscribe", "place order"]
    /// A plain Enter or one of these buttons can finish a purchase, so they ask on a buying page.
    private static let submitWords = ["submit", "confirm", "complete", "finish"]
    private static let buyingPageWords = ["checkout", "check out", "payment", "payments", "billing", "cart", "order", "purchase", "pay"]
    /// Apps where Enter runs a command, and a pasted new line counts as Enter.
    private static let terminals = ["com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "dev.warp.Warp-Stable",
                                     "net.kovidgoyal.kitty", "org.alacritty", "com.github.wez.wezterm", "co.zeit.hyper"]
    private static let browsers = ["com.google.Chrome", "com.apple.Safari", "company.thebrowser.Browser", "com.brave.Browser",
                                    "com.microsoft.edgemac", "org.mozilla.firefox"]

    private static func needsOK(click target: ScreenElements.Target, what: String) -> Bool {
        let words = [what] + target.words
        if contains(riskyWords, in: words) { return true }
        return browsers.contains(target.bundleID) && contains(submitWords, in: words)
            && isBuyingPage(NSWorkspace.shared.frontmostApplication)
    }

    private static func needsOK(key: CGKeyCode, flags: CGEventFlags, app: NSRunningApplication?) -> Bool {
        let bundleID = app?.bundleIdentifier ?? ""
        let isEnter = key == CGKeyCode(kVK_Return) || key == CGKeyCode(kVK_ANSI_KeypadEnter)
        // Enter in a terminal runs whatever is typed there, which could delete things.
        if isEnter && terminals.contains(bundleID) { return true }
        if isEnter && browsers.contains(bundleID) && isBuyingPage(app) { return true }
        if key == CGKeyCode(kVK_Delete) && flags.contains(.maskCommand) && bundleID == "com.apple.finder" { return true }
        return false
    }

    /// Going by the window's title, which in a browser is the page's title.
    private static func isBuyingPage(_ app: NSRunningApplication?) -> Bool {
        guard let app else { return false }
        return contains(buyingPageWords, in: [ScreenElements.windowTitle(of: app.processIdentifier)])
    }

    /// Whole words only, so "border" doesn't count as "order" or "Postman" as "post".
    private static func contains(_ words: [String], in texts: [String]) -> Bool {
        let letters = texts.joined(separator: " ").lowercased().map { $0.isLetter ? $0 : " " }
        let text = " " + String(letters).split(separator: " ").joined(separator: " ") + " "
        return words.contains { text.contains(" \($0) ") }
    }

    private static func summary(_ arguments: [String: Any]) -> String? {
        let text = (arguments["summary"] as? String ?? "").trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.init(charactersIn: "?.")))
        return text.isEmpty ? nil : text
    }

    /// The bar's main button, which is what turns it red. Every word that can trigger the bar needs
    /// a verb here, or a purchase gets a plain Continue. Whole words, so "payload" isn't Pay.
    private static func verb(for words: [String]) -> String {
        for (word, verb) in [("delete", "Delete"), ("deleting", "Delete"), ("remove", "Remove"), ("removing", "Remove"), ("trash", "Delete"),
                             ("erase", "Delete"), ("buy", "Buy"), ("purchase", "Buy"), ("checkout", "Buy"), ("check out", "Buy"),
                             ("subscribe", "Buy"), ("pay", "Pay"), ("order", "Order"), ("place order", "Order"), ("run", "Run"),
                             ("submit", "Submit")]
        where contains([word], in: words) {
            return verb
        }
        return "Continue"
    }

    private func declined(_ outcome: String) -> ToolServer.Result {
        Self.refuse("The user \(lastWentUnanswered ? "didn't answer" : "said no"), so \(outcome).")
    }

    /// Shows the card, then puts the app you were in back in front, so the next key lands there.
    private func confirmKeepingFocus(_ request: ConfirmCard.Request) async -> Bool {
        let app = NSWorkspace.shared.frontmostApplication
        let answer = await confirm(request)
        lastWentUnanswered = answer == .noAnswer
        log.append("  confirm card \"\(request.title)\" → \(answer)")
        guard answer == .yes, !Task.isCancelled, !isStopped else { return false }
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
