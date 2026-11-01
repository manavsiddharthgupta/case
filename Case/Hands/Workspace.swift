import Foundation

/// The folder where Case makes things: files it writes and commands it runs. macOS itself holds
/// commands to this folder through a sandbox, so a page or file can't talk Claude past the limit.
/// Going outside it takes your yes on the confirm bar, which Hands asks for.
final class Workspace {
    nonisolated struct Saved: Sendable {
        var url: URL
        var isOutside: Bool
    }

    private static let firstWait = Duration.seconds(45)
    private static let laterWait = Duration.seconds(60)
    private static let longestReply = 8_000

    /// Secrets and private data that no command needs, even though Case itself can read them.
    private static let privateFolders = [
        ".ssh", ".aws", ".gnupg", ".netrc", ".claude", ".config/gh", "Library/Keychains", "Library/Messages", "Library/Mail",
        "Library/Cookies", "Library/Safari", "Library/Application Support/Case", "Library/Application Support/Google/Chrome",
    ]
    /// These reach outside the sandbox by asking another app or macOS to do the work.
    private static let blockedPrograms = ["/usr/bin/open", "/usr/bin/osascript", "/bin/launchctl", "/usr/bin/crontab"]

    let folder: URL
    private let home: URL
    private var jobs: [Int: Job] = [:]
    private var lastJob = 0

    init(folder: URL = .documentsDirectory.appending(path: "Case", directoryHint: .isDirectory), home: URL = .homeDirectory) {
        self.folder = folder
        self.home = home
    }

    // MARK: Files

    /// Works out where a path really leads, so "../" or a link can't pass for being inside.
    func place(_ path: String) -> Saved {
        let expanded = NSString(string: path.trimmingCharacters(in: .whitespacesAndNewlines)).expandingTildeInPath
        let url = expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded) : folder.appending(path: expanded)
        let real = realPath(url)
        return Saved(url: real, isOutside: !real.path.hasPrefix(realPath(folder).path + "/"))
    }

    func save(_ text: String, to place: Saved) throws {
        try FileManager.default.createDirectory(at: place.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: place.url, atomically: true, encoding: .utf8)
    }

    /// A file that doesn't exist yet can't resolve its links, so this finds the part that does.
    private func realPath(_ url: URL) -> URL {
        var existing = url.standardizedFileURL
        var rest: [String] = []
        while !FileManager.default.fileExists(atPath: existing.path), existing.path != "/" {
            rest.insert(existing.lastPathComponent, at: 0)
            existing = existing.deletingLastPathComponent()
        }
        return rest.reduce(existing.resolvingSymlinksInPath()) { $0.appending(path: $1) }
    }

    // MARK: Commands

    /// Starts a command and waits a while. One that takes longer keeps going as a numbered job.
    func run(_ command: String, outside: Bool = false) async -> ToolServer.Result {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let job = try Job(arguments: outside ? ["/bin/zsh", "-c", command]
                                  : ["/usr/bin/sandbox-exec", "-p", sandboxRules, "/bin/zsh", "-c", command],
                              folder: folder, path: toolPath)
            lastJob += 1
            jobs[lastJob] = job
            return await report(lastJob, job, waiting: Self.firstWait)
        } catch {
            return ToolServer.Result(text: "Couldn't start that: \(error.localizedDescription)", isError: true)
        }
    }

    func check(_ id: Int) async -> ToolServer.Result {
        guard let job = jobs[id] else { return ToolServer.Result(text: "There's no job \(id).", isError: true) }
        return await report(id, job, waiting: Self.laterWait)
    }

    func stopEverything() {
        jobs.values.forEach { $0.stop() }
    }

    private func report(_ id: Int, _ job: Job, waiting: Duration) async -> ToolServer.Result {
        let deadline = ContinuousClock.now + waiting
        while job.isRunning, !Task.isCancelled, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(200))
        }
        let output = String(job.output.suffix(Self.longestReply))
        if job.isRunning {
            return ToolServer.Result(text: "Still running as job \(id). Use check_command to see how it's doing.\n\(output)")
        }
        jobs[id] = nil
        let code = job.exitCode
        return ToolServer.Result(text: "Finished\(code == 0 ? "" : " with error code \(code)").\n\(output)", isError: code != 0)
    }

    private var toolPath: String {
        let extras = ["/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin", home.appending(path: ".local/bin").path]
        return (extras + [ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"]).joined(separator: ":")
    }

    /// The last rule that matches wins.
    private var sandboxRules: String {
        func quoted(_ path: String) -> String {
            "\"" + path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        func paths(_ keyword: String, _ list: [String]) -> String {
            list.map { "(\(keyword) \(quoted($0)))" }.joined(separator: " ")
        }
        let realHome = home.resolvingSymlinksInPath()
        let writable = [folder.resolvingSymlinksInPath().path, "/private/tmp", "/private/var/folders", "/dev",
                        realHome.appending(path: ".cache").path, realHome.appending(path: "Library/Caches").path]
        return """
            (version 1)
            (allow default)
            (deny file-write*)
            (allow file-write* \(paths("subpath", writable)))
            (deny file-read* \(paths("subpath", Self.privateFolders.map { realHome.appending(path: $0).path })))
            (deny appleevent-send)
            (deny process-exec \(paths("literal", Self.blockedPrograms)))
            """
    }
}

/// One running command and everything it has printed.
private nonisolated final class Job: @unchecked Sendable {
    private static let keptOutput = 200_000

    private let process = Process()
    private let lock = NSLock()
    private var buffer = Data()

    var isRunning: Bool { process.isRunning }
    var exitCode: Int32 { process.terminationStatus }

    var output: String {
        lock.withLock { String(decoding: buffer, as: UTF8.self) }
    }

    init(arguments: [String], folder: URL, path: String) throws {
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: arguments[0])
        process.arguments = Array(arguments.dropFirst())
        process.currentDirectoryURL = folder
        process.environment = ProcessInfo.processInfo.environment.merging(["PATH": path]) { $1 }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil } else { self?.keep(data) }
        }
        try process.run()
    }

    private func keep(_ data: Data) {
        lock.withLock {
            buffer.append(data)
            if buffer.count > Self.keptOutput { buffer.removeFirst(buffer.count - Self.keptOutput) }
        }
    }

    /// The whole process group, so a download a script started stops too.
    func stop() {
        guard process.isRunning else { return }
        kill(-process.processIdentifier, SIGTERM)
        process.terminate()
    }
}
