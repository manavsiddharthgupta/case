import Foundation

/// Finds the user's installed `claude` command and reads whether it's logged in.
/// Case only ever runs the official CLI; it never reads Claude's login details.
enum ClaudeCLI {
    enum Status: Equatable {
        case checking
        case notInstalled
        case signedOut
        case connected(plan: String?)
        case failed(String)
    }

    /// The parts of `claude auth status` we use.
    nonisolated struct AuthStatus: Decodable {
        let loggedIn: Bool
        let subscriptionType: String?
    }

    nonisolated struct RunResult: Sendable {
        let status: Int32
        let output: String
    }

    static func checkStatus() async -> Status {
        guard let claude = await locate() else { return .notInstalled }
        do {
            // A signed-out CLI may exit non-zero but still prints JSON, so decode either way.
            let result = try await run(claude, ["auth", "status"])
            guard let auth = try? JSONDecoder().decode(AuthStatus.self, from: Data(result.output.utf8)) else {
                return .failed("Couldn't read `claude auth status`.")
            }
            return auth.loggedIn ? .connected(plan: auth.subscriptionType) : .signedOut
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// Apps opened from Finder don't get the Terminal's PATH, so check the usual install spots first.
    static func locate() async -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/.local/bin/claude",
            "\(home)/.claude/local/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
        ]
        if let path = candidates.first(where: FileManager.default.isExecutableFile(atPath:)) {
            return URL(fileURLWithPath: path)
        }

        // Fall back to asking the user's login shell.
        guard let result = try? await run(URL(fileURLWithPath: "/bin/zsh"), ["-lc", "command -v claude"]),
              result.status == 0
        else { return nil }
        let path = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return FileManager.default.isExecutableFile(atPath: path) ? URL(fileURLWithPath: path) : nil
    }

    /// One question and one text answer, apart from the conversation at the cursor. It has no tools,
    /// and the user's own Claude Code settings and connectors stay out, like the kept-running session.
    static func oneShot(_ prompt: String, instructions: String, model: String) async throws -> String {
        guard let claude = await locate() else { throw ClaudeSession.SessionError.notInstalled }
        try FileManager.default.createDirectory(at: Storage.folder, withIntermediateDirectories: true)
        let result = try await run(claude, [
            "-p",
            "--output-format", "text",
            "--model", model,
            "--setting-sources", "",
            "--disable-slash-commands",
            "--strict-mcp-config",
            "--tools", "",
            "--no-session-persistence",
            "--system-prompt", instructions,
        ], input: Data(prompt.utf8), folder: Storage.folder)
        guard result.status == 0 else { throw ClaudeSession.SessionError.claude("Claude couldn't finish that. Try again.") }
        return result.output
    }

    /// Reads the JSON out of a reply, which may have words or code fences around it.
    static func decodeJSON<Value: Decodable>(_ reply: String) -> Value? {
        guard let start = reply.firstIndex(of: "{"), let end = reply.lastIndex(of: "}"), start < end else { return nil }
        return try? JSONDecoder().decode(Value.self, from: Data(reply[start...end].utf8))
    }

    /// Runs a command off the main thread and returns its exit code and stdout.
    @concurrent
    nonisolated static func run(_ executable: URL, _ arguments: [String], input: Data? = nil, folder: URL? = nil) async throws -> RunResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = folder
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        let stdin = Pipe()
        if input != nil { process.standardInput = stdin }
        try process.run()
        // A long transcript fills the pipe, so write it while reading the answer.
        if let input {
            Thread.detachNewThread {
                try? stdin.fileHandleForWriting.write(contentsOf: input)
                try? stdin.fileHandleForWriting.close()
            }
        }
        let data = try stdout.fileHandleForReading.readToEnd() ?? Data()
        process.waitUntilExit()
        return RunResult(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
    }
}
