import Foundation

/// Kokoro only knows how to say words. Digits, symbols and invisible characters come out as
/// noise, so this turns them into words first: "82%" → "eighty-two percent", "⌘W" → "command W".
nonisolated enum SpokenText {
    static func forSpeech(_ text: String) -> String {
        var text = String(String.UnicodeScalarView(text.unicodeScalars.filter { !isInvisible($0) }))
        text = keys(text)
        text = replace(#"[“”"«»*_~|<>\[\]{}]"#, in: text) { _ in "" }
        text = text.replacingOccurrences(of: "’", with: "'")
        for (written, said) in shorthand { text = text.replacingOccurrences(of: written, with: said) }
        text = replace(#"(?<=[A-Za-z])/(?=[A-Za-z])"#, in: text) { _ in " or " }
        text = text.replacingOccurrences(of: "/", with: " ")
        text = numbers(text)
        text = joinedWords(text)
        text = replace(#"\b[A-Z]{2,5}s?\b"#, in: text, acronym)
        text = replace(#"\s+([.,!?;:])"#, in: text) { "\($0[1])" }
        return replace(#"\s{2,}"#, in: text) { _ in " " }.trimmingCharacters(in: .whitespaces)
    }

    /// Left-to-right marks and the like, which apps such as WhatsApp put inside their labels.
    private static func isInvisible(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.generalCategory == .format
    }

    private static let shorthand: [(String, String)] = [
        ("e.g.", "for example"), ("i.e.", "that is"), ("etc.", "and so on"), ("vs.", "versus"),
        (" & ", " and "), ("@", " at "), ("→", " to "), ("->", " to "), ("…", "."), ("—", ", "), ("–", ", "),
        ("+", " plus "), ("=", " equals "), ("#", " number "),
    ]

    private static let keyNames: [(String, String)] = [
        ("⌘", "command"), ("⌥", "option"), ("⇧", "shift"), ("⌃", "control"), ("⏎", "return"), ("↩", "return"),
        ("⌫", "delete"), ("⎋", "escape"), ("⇥", "tab"),
    ]

    /// "⌘W", "cmd+shift+t", "Ctrl-C" → "command W", "command shift T", "control C".
    private static func keys(_ text: String) -> String {
        var text = text
        for (symbol, name) in keyNames { text = text.replacingOccurrences(of: symbol, with: " \(name) ") }
        let modifier = #"(?:cmd|command|ctrl|control|opt|option|alt|shift|fn)"#
        return replace(#"(?i)\b\#(modifier)(?:\s*[+-]\s*\#(modifier))*\s*[+-]\s*(\w+)\b"#, in: text) { match in
            let parts = match[0].split(whereSeparator: { "+- ".contains($0) }).map { part -> String in
                switch part.lowercased() {
                case "cmd": "command"
                case "ctrl": "control"
                case "opt", "alt": "option"
                default: part.count == 1 ? part.uppercased() : String(part)
                }
            }
            return parts.joined(separator: " ")
        }
    }

    private static func numbers(_ text: String) -> String {
        var text = text
        // Phone-style digit runs read digit by digit: "1-4-8-3" → "one four eight three".
        text = replace(#"\b\d(?:-\d){2,}\b"#, in: text) { match in
            match[0].split(separator: "-").compactMap { Int($0).map(spell) }.joined(separator: " ")
        }
        text = replace(#"[$₹€£]\s?(\d+(?:,\d{3})*(?:\.\d+)?)"#, in: text) { match in
            let name = ["$": "dollars", "₹": "rupees", "€": "euros", "£": "pounds"][match[0].prefix(1)] ?? ""
            return "\(match[1]) \(name)"
        }
        text = replace(#"(\d)\s?%"#, in: text) { "\($0[1]) percent" }
        text = replace(#"\b(\d{1,2}):(\d{2})\b"#, in: text) { match in
            let minutes = Int(match[2]) ?? 0
            return "\(match[1]) " + (minutes == 0 ? "o'clock" : minutes < 10 ? "oh \(minutes)" : "\(minutes)")
        }
        text = replace(#"\b(\d+)(?:st|nd|rd|th)\b"#, in: text) { match in
            Int(match[1]).map(ordinal) ?? match[0]
        }
        // Ranges: "3-5 minutes" → "3 to 5 minutes".
        text = replace(#"\b(\d+)\s?-\s?(\d+)\b"#, in: text) { "\($0[1]) to \($0[2])" }
        // "10x faster", "4K", "8GB"
        text = replace(#"\b(\d+(?:\.\d+)?)([a-zA-Z]{1,3})\b"#, in: text) { match in
            let unit = units[match[2]] ?? match[2]
            return "\(match[1]) \(unit)"
        }
        return replace(#"\d+(?:,\d{3})*(?:\.\d+)*"#, in: text) { match in
            let parts = match[0].replacingOccurrences(of: ",", with: "").split(separator: ".")
            // "26.6.2", a version: each part on its own.
            if parts.count > 2 { return parts.compactMap { Int($0).map(spell) }.joined(separator: " point ") }
            var words = Int(parts.first ?? "").map(spell) ?? String(match[0])
            if parts.count == 2 {
                words += " point " + parts[1].compactMap { $0.wholeNumberValue.map(spell) }.joined(separator: " ")
            }
            return words
        }
    }

    private static let units = [
        "x": "times", "K": "K", "k": "thousand", "GB": "gigabytes", "MB": "megabytes", "TB": "terabytes",
        "KB": "kilobytes", "ms": "milliseconds", "s": "seconds", "min": "minutes", "h": "hours", "km": "kilometres",
        "m": "metres", "kg": "kilos", "g": "grams", "px": "pixels", "pt": "points", "am": "A M", "pm": "P M",
    ]

    /// "WhatsApp" → "Whats App", "YouTube" → "You Tube", "macOS" → "mac OS": the voice reads the parts better.
    private static func joinedWords(_ text: String) -> String {
        replace(#"\b([A-Za-z][a-z]+)([A-Z][A-Za-z]*)\b"#, in: text) { "\($0[1]) \($0[2])" }
    }

    /// Short all-capital words are letters ("ABQ" → "A B Q"), except ones that are read as words.
    private static func acronym(_ match: [String]) -> String {
        let word = match[0]
        if readAsWords.contains(word.lowercased()) { return word.capitalized }
        let plural = word.count > 2 && word.hasSuffix("s")
        let letters = (plural ? word.dropLast() : Substring(word)).map(String.init).joined(separator: " ")
        return plural ? letters + "s" : letters
    }

    private static let readAsWords: Set<String> = [
        "ok", "okay", "nasa", "wifi", "jpeg", "gif", "png", "radar", "laser", "scuba", "unicef", "covid",
        "i", "a", "am", "an", "at", "be", "by", "do", "go", "he", "hi", "if", "in", "is", "it", "me", "my", "no",
        "of", "oh", "on", "or", "so", "to", "up", "us", "we", "the", "and", "you", "not", "all", "now", "new", "yes",
        "but", "for", "how", "can", "get", "see", "use", "its", "are", "was", "one", "two", "this", "that", "with",
        "your", "what", "when", "will", "have", "from", "here", "done", "send", "open", "stop", "help", "note",
    ]

    private static func spell(_ number: Int) -> String {
        words.string(from: NSNumber(value: number)) ?? String(number)
    }

    private static let words: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .spellOut
        formatter.locale = Locale(identifier: "en_US")
        return formatter
    }()

    /// 21 → "twenty-first"
    private static func ordinal(_ number: Int) -> String {
        let spelled = spell(number)
        let irregular = ["one": "first", "two": "second", "three": "third", "five": "fifth", "eight": "eighth",
                         "nine": "ninth", "twelve": "twelfth"]
        for (cardinal, ordinal) in irregular where spelled.hasSuffix(cardinal) {
            return spelled.dropLast(cardinal.count) + ordinal
        }
        return spelled.hasSuffix("y") ? spelled.dropLast() + "ieth" : spelled + "th"
    }

    /// Replaces every match of `pattern`, building the replacement from the match and its groups.
    private static func replace(_ pattern: String, in text: String, _ make: ([String]) -> String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        var result = ""
        var last = text.startIndex
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text) else { continue }
            let groups = (0..<match.numberOfRanges).map { index in
                Range(match.range(at: index), in: text).map { String(text[$0]) } ?? ""
            }
            result += text[last..<range.lowerBound] + make(groups)
            last = range.upperBound
        }
        return result + text[last...]
    }
}

/// Kokoro makes long sentences in pieces of up to five seconds and leaves almost a second of silence
/// where they meet, and at commas. This shortens those gaps to a natural pause.
nonisolated enum SpokenAudio {
    static func tightened(_ samples: [Float], sampleRate: Double = 24_000) -> [Float] {
        let window = Int(sampleRate * 0.01)
        let quiet: Float = 0.01
        let longestPause = Int(sampleRate * 0.22)
        // Loudness in 10 ms steps.
        let steps = stride(from: 0, to: samples.count, by: window).map { start in
            samples[start..<min(start + window, samples.count)].reduce(0) { max($0, abs($1)) } >= quiet
        }
        guard let first = steps.firstIndex(of: true), let last = steps.lastIndex(of: true) else { return [] }

        var result: [Float] = []
        result.reserveCapacity(samples.count)
        var silence = 0
        for step in max(first - 2, 0)...min(last + 15, steps.count - 1) {
            let range = (step * window)..<min((step + 1) * window, samples.count)
            if steps[step] {
                silence = 0
            } else {
                silence += range.count
                if silence > longestPause { continue }
            }
            result.append(contentsOf: samples[range])
        }
        return result
    }

    /// Kokoro speaks at under half of full volume; this brings it up to about Aman's loudness.
    static func louder(_ samples: [Float]) -> [Float] {
        guard let peak = samples.map(abs).max(), peak > 0 else { return samples }
        let rms = (samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count)).squareRoot()
        let gain = min(0.14 / max(rms, 0.001), 0.95 / peak, 4)
        return samples.map { $0 * gain }
    }
}
