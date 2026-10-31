import AppKit

/// Answers that come straight from macOS, so nothing on screen has to change.
nonisolated enum MacTools {
    private static let chrome = "com.google.Chrome"

    // MARK: Files

    /// `kind` is "app", "folder" or "any". Apps come from Spotlight, which already knows every one.
    static func findFiles(_ query: String, kind: String) async -> String {
        guard kind == "app" else { return await FileSearch.find(query, foldersOnly: kind == "folder") }

        let words = query.split(whereSeparator: \.isWhitespace).map { $0.filter { !"\"*\\".contains($0) } }.filter { !$0.isEmpty }
        let terms = words.map { "kMDItemDisplayName == \"*\($0)*\"cd" } + ["kMDItemContentType == \"com.apple.application-bundle\""]
        let found = await output("/usr/bin/mdfind", terms.joined(separator: " && "))
        let places = ["/Applications/", "/System/Applications/", NSHomeDirectory() + "/Applications/"]
        let names = found.split(separator: "\n").map(String.init).filter { path in places.contains { path.hasPrefix($0) } }
            .map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent }
        let apps = Array(Set(names)).sorted()
        return apps.isEmpty ? "No apps found." : "\(apps.count) installed: " + apps.joined(separator: ", ")
    }

    // MARK: This Mac

    static func systemInfo() async -> String {
        let info = ProcessInfo.processInfo
        var lines = ["Now: \(Date.now.formatted(date: .complete, time: .shortened))"]
        let chip = await output("/usr/sbin/sysctl", "-n", "machdep.cpu.brand_string")
        lines.append("Mac: \(chip), \(info.physicalMemory >> 30) GB of memory, \(info.operatingSystemVersionString)")

        let power = await output("/usr/bin/pmset", "-g", "batt")
        if let battery = power.split(separator: "\n").last?.split(separator: "\t").last {
            lines.append("Battery: " + battery.replacingOccurrences(of: " present: true", with: ""))
        }
        let disk = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey])
        if let free = disk?.volumeAvailableCapacityForImportantUsage, let total = disk?.volumeTotalCapacity {
            lines.append("Storage: \(free >> 30) GB free of \(total >> 30) GB")
        }
        let memory = await output("/usr/bin/memory_pressure")
        if let free = memory.split(separator: "\n").last { lines.append(String(free)) }
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.compactMap(\.localizedName)
        lines.append("Apps open: " + apps.joined(separator: ", "))
        return lines.joined(separator: "\n")
    }

    // MARK: Chrome

    /// `action` is "list", "switch" or "close"; `tabs` are numbers from the list, starting at 1.
    static func chromeTabs(action: String, tabs: [Int]) async -> ToolServer.Result {
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: chrome).isEmpty else {
            return ToolServer.Result(text: "Chrome isn't open.", isError: true)
        }
        let window = "front window"
        var change = ""
        if action == "switch", let tab = tabs.first {
            change = "set active tab index of \(window) to \(tab)\n"
        } else if action == "close" {
            // Highest first, so closing one doesn't renumber the rest.
            change = Set(tabs).sorted(by: >).map { "close tab \($0) of \(window)\n" }.joined()
        }
        let script = """
            tell application "Google Chrome"
            \(change)set listing to ""
            set counter to 1
            repeat with item_ in tabs of \(window)
            set listing to listing & counter & ". " & (title of item_) & " - " & (URL of item_) & linefeed
            set counter to counter + 1
            end repeat
            return listing & "Showing tab " & (active tab index of \(window))
            end tell
            """
        guard let result = try? await ClaudeCLI.run(URL(fileURLWithPath: "/usr/bin/osascript"), ["-e", script]), result.status == 0 else {
            return ToolServer.Result(text: "Couldn't reach Chrome. That tab may not exist, or Case may need permission to control Chrome.", isError: true)
        }
        return ToolServer.Result(text: result.output.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func output(_ path: String, _ arguments: String...) async -> String {
        let result = try? await ClaudeCLI.run(URL(fileURLWithPath: path), arguments)
        return result?.output.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}
