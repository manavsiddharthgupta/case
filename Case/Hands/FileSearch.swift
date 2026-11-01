import Foundation

/// Finds files the way people expect: forgiving about spelling and spaces, your own folders first,
/// and looking inside documents when the name doesn't help. Spotlight covers the whole Mac, but it
/// quietly returns nothing from Downloads, Documents and Desktop unless the app has been allowed in,
/// so those three are also read directly. That read is what makes macOS ask for permission.
nonisolated enum FileSearch {
    private struct Match {
        let path: String
        let score: Int
        var inside = false
    }

    private static let personal = ["Downloads", "Documents", "Desktop"]
    private static let skipped: Set = ["node_modules", "dist", "build", "DerivedData", "vendor", "Pods", "target", "__pycache__"]
    private static let documents: Set = ["pdf", "doc", "docx", "pages", "rtf", "txt", "md", "xls", "xlsx", "csv", "numbers", "ppt", "pptx",
                                         "key", "jpg", "jpeg", "png", "heic"]
    /// Images have no words for Spotlight to search, so they're left out of looking inside.
    private static let readable = documents.subtracting(["jpg", "jpeg", "png", "heic"])
    private static let noise = ["/Library/", "/node_modules/", "/.build/", "/.git/", "/DerivedData/", "/.Trash/"]
    private static let maxShown = 30
    private static let maxDepth = 8
    private static let maxVisited = 40_000
    /// Anything this far below the best match is only getting in the way.
    private static let worstGap = 50
    /// A match on the name itself, not on words inside the file.
    private static let clearScore = 100

    /// The file whose name clearly matches, if there is one, and how many others also came up.
    static func clearMatch(_ query: String) async -> (path: String, others: Int)? {
        let spellings = [tokens(query)].filter { !$0.isEmpty }
        guard !spellings.isEmpty else { return nil }
        let (useful, _) = await search(spellings, foldersOnly: false, home: NSHomeDirectory())
        guard let best = useful.first, best.score >= clearScore, !best.inside else { return nil }
        return (best.path, useful.count - 1)
    }

    private static func search(_ spellings: [[String]], foldersOnly: Bool, home: String) async -> (useful: [Match], blocked: [String]) {
        async let read = walk(foldersOnly: foldersOnly, home: home)
        let found = await spotlight(spellings, foldersOnly: foldersOnly)
        let (walked, blocked) = await read

        var matches = Set(found + walked).compactMap { path -> Match? in
            guard !isNoise(path) else { return nil }
            let best = spellings.compactMap { score(path, words: $0, home: home) }.max()
            return best.map { Match(path: path, score: $0) }
        }
        if !foldersOnly, matches.count(where: { $0.score >= 100 }) < 3 {
            let known = Set(matches.map(\.path))
            let inside = await spotlightInside(spellings, home: home)
            matches += inside.filter { !known.contains($0) && !isNoise($0) }.map { Match(path: $0, score: 60, inside: true) }
        }

        let best = matches.map(\.score).max() ?? 0
        let useful = matches.filter { $0.score >= best - worstGap }.sorted { ($0.score, $1.path) > ($1.score, $0.path) }
        return (useful, blocked)
    }

    /// `query` can hold several spellings or names, separated by commas.
    static func find(_ query: String, foldersOnly: Bool) async -> String {
        let spellings = query.split(separator: ",").map { tokens(String($0)) }.filter { !$0.isEmpty }
        guard !spellings.isEmpty else { return "Give some words from the name to search for." }

        let home = NSHomeDirectory()
        let (useful, blocked) = await search(spellings, foldersOnly: foldersOnly, home: home)
        let shown = useful.prefix(maxShown).map { match in
            let path = match.path.hasPrefix(home) ? "~" + match.path.dropFirst(home.count) : match.path
            return match.inside ? "\(path) (the words are inside it)" : path
        }
        var lines = [shown.isEmpty ? "Nothing found in names or inside documents." : "Found \(useful.count)\(useful.count > maxShown ? ", showing \(maxShown)" : ""), best first:"]
        lines += shown
        if !blocked.isEmpty {
            lines.append("Not allowed to look in \(blocked.joined(separator: ", ")), so that wasn't searched. The user can allow it in "
                         + "System Settings, Privacy & Security, Files & Folders.")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Scoring

    /// How well a file matches all the words of one spelling, or nil if it doesn't. Exact words in the
    /// name come first, then the words spread across the name and its folders, then just one of them.
    static func score(_ path: String, words: [String], home: String) -> Int? {
        let url = URL(fileURLWithPath: path)
        let name = tokens(url.deletingPathExtension().lastPathComponent)
        let squeezed = name.joined()
        let folders = tokens(url.deletingLastPathComponent().path.replacingOccurrences(of: home, with: ""))

        let qualities = words.map { quality(of: $0, in: name) }
        var score: Int
        if words.joined().count > 4, squeezed.contains(words.joined()) {
            score = 130  // "pan card" and "pancard" both find pan-card.pdf
        } else if qualities.allSatisfy({ $0 > 0 }) {
            score = 100 + 10 * qualities.reduce(0, +) / words.count
        } else if zip(words, qualities).allSatisfy({ $1 > 0 || quality(of: $0, in: folders) > 0 }) {
            score = 90
        } else if qualities.contains(3) {
            score = 60
        } else {
            return nil
        }

        let inside = url.path.replacingOccurrences(of: home + "/", with: "")
        if personal.contains(where: { inside.hasPrefix($0 + "/") }) { score += 15 }
        if documents.contains(url.pathExtension.lowercased()) { score += 10 }
        if inside.hasPrefix("Developer/") { score -= 30 }
        return score >= 50 ? score : nil
    }

    /// 3 for the exact word, 2 for a close spelling or a word starting with it, 1 for a weak match.
    private static func quality(of word: String, in tokens: [String]) -> Int {
        if tokens.contains(word) { return 3 }
        if word.count >= 5, tokens.contains(where: { isCloseSpelling(word, $0) }) { return 2 }
        if tokens.contains(where: { $0.hasPrefix(word) }) { return word.count > 3 ? 2 : 1 }
        return word.count > 3 && tokens.contains { $0.contains(word) } ? 1 : 0
    }

    /// "aadhar" and "aadhaar": one wrong letter, or two in a long word.
    private static func isCloseSpelling(_ a: String, _ b: String) -> Bool {
        let limit = max(a.count, b.count) >= 7 ? 2 : 1
        guard abs(a.count - b.count) <= limit else { return false }
        let a = Array(a), b = Array(b)
        var row = Array(0...b.count)
        for i in 1...a.count {
            var previous = row[0]
            row[0] = i
            for j in stride(from: 1, through: b.count, by: 1) {
                let above = row[j]
                row[j] = min(row[j] + 1, row[j - 1] + 1, previous + (a[i - 1] == b[j - 1] ? 0 : 1))
                previous = above
            }
        }
        return row[b.count] <= limit
    }

    /// "PAN-card_2024" becomes pan, card, 2024.
    static func tokens(_ text: String) -> [String] {
        var spaced = ""
        var previous: Character?
        for character in text {
            if character.isUppercase, previous?.isLowercase == true { spaced.append(" ") }
            spaced.append(character)
            previous = character
        }
        return spaced.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    private static func isNoise(_ path: String) -> Bool {
        path.hasPrefix("/usr/") || path.hasPrefix("/System/") || path.hasPrefix("/private/") || noise.contains { path.contains($0) }
    }

    // MARK: Looking

    private static func spotlight(_ spellings: [[String]], foldersOnly: Bool) async -> [String] {
        let words = Set(spellings.flatMap { $0 }).map(clean).filter { !$0.isEmpty }
        guard !words.isEmpty else { return [] }
        var query = "(" + words.map { "kMDItemDisplayName == \"*\($0)*\"cd" }.joined(separator: " || ") + ")"
        if foldersOnly { query += " && kMDItemContentType == \"public.folder\"" }
        return await paths(query)
    }

    private static func spotlightInside(_ spellings: [[String]], home: String) async -> [String] {
        var found: [String] = []
        for words in spellings {
            let query = words.map(clean).filter { !$0.isEmpty }.map { "kMDItemTextContent == \"\($0)*\"cdw" }.joined(separator: " && ")
            if !query.isEmpty { found += await paths(query) }
        }
        return found.filter { $0.hasPrefix(home) && !$0.hasPrefix(home + "/Developer/")
            && readable.contains(URL(fileURLWithPath: $0).pathExtension.lowercased()) }
    }

    private static func paths(_ query: String) async -> [String] {
        let result = try? await ClaudeCLI.run(URL(fileURLWithPath: "/usr/bin/mdfind"), [query])
        return result?.output.split(separator: "\n").map(String.init) ?? []
    }

    private static func clean(_ word: String) -> String {
        word.filter { !"\"*\\".contains($0) }
    }

    /// Every name in your own folders, and which of them macOS wouldn't let us into.
    @concurrent
    private static func walk(foldersOnly: Bool, home: String) async -> (paths: [String], blocked: [String]) {
        var paths: [String] = []
        var blocked: [String] = []
        for folder in personal {
            let root = URL(fileURLWithPath: home).appending(path: folder, directoryHint: .isDirectory)
            // The first touch shows macOS's permission question, and this waits for your answer.
            guard (try? FileManager.default.contentsOfDirectory(atPath: root.path)) != nil else {
                blocked.append(folder)
                continue
            }
            paths += names(under: root, foldersOnly: foldersOnly)
        }
        return (paths, blocked)
    }

    private static func names(under root: URL, foldersOnly: Bool) -> [String] {
        guard let items = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                                         options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { return [] }
        var paths: [String] = []
        var visited = 0
        for case let url as URL in items {
            visited += 1
            if visited > maxVisited { break }
            let isFolder = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            if isFolder, items.level >= maxDepth || skipped.contains(url.lastPathComponent) { items.skipDescendants() }
            if isFolder || !foldersOnly { paths.append(url.path) }
        }
        return paths
    }
}
