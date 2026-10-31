import CoreGraphics

/// Where Claude wants the buddy to go.
nonisolated enum PointTarget: Equatable, Sendable {
    /// A number from the list of things on screen.
    case element(Int)
    /// A spot in screenshot pixels.
    case pixel(CGPoint)
    /// A box drawn around something that isn't in the list, in screenshot pixels.
    case area(CGRect)
}

/// Splits Claude's streamed answer into text to show and say, and the [POINT:…] and [AREA:…] tags between it.
/// Each tag sits just before the sentence it's about, so the buddy can move as that sentence is spoken.
nonisolated struct AnswerStream {
    enum Part: Equatable {
        case text(String)
        case point(PointTarget)
    }

    private static let openings = ["[POINT:", "[AREA:"]
    private var buffer = ""

    /// Adds a streamed piece and returns everything that's now complete.
    /// Text that might be the start of a tag ("[PO") waits for the next piece.
    mutating func append(_ piece: String) -> [Part] {
        buffer += piece
        var parts: [Part] = []
        while true {
            if let tag = Self.openings.compactMap({ buffer.range(of: $0) }).min(by: { $0.lowerBound < $1.lowerBound }) {
                emit(String(buffer[..<tag.lowerBound]), into: &parts)
                guard let close = buffer[tag.upperBound...].firstIndex(of: "]") else {
                    buffer = String(buffer[tag.lowerBound...])
                    return parts
                }
                if let target = Self.parse(buffer[tag.upperBound..<close]) {
                    parts.append(.point(target))
                }
                buffer = String(buffer[buffer.index(after: close)...])
            } else {
                if let open = buffer.lastIndex(of: "["), Self.openings.contains(where: { $0.hasPrefix(buffer[open...]) }) {
                    emit(String(buffer[..<open]), into: &parts)
                    buffer = String(buffer[open...])
                } else {
                    emit(buffer, into: &parts)
                    buffer = ""
                }
                return parts
            }
        }
    }

    /// The answer is complete. A tag that never closed, or was cut off ("[PO"), is dropped.
    mutating func finish() -> [Part] {
        defer { buffer = "" }
        guard !Self.openings.contains(where: { buffer.hasPrefix($0) || $0.hasPrefix(buffer) }) else { return [] }
        var parts: [Part] = []
        emit(buffer, into: &parts)
        return parts
    }

    private func emit(_ text: String, into parts: inout [Part]) {
        if !text.isEmpty { parts.append(.text(text)) }
    }

    /// "#7" → element 7, "640,320" → that pixel, "100,80,300,200" → that box, anything else ("none") → nothing.
    private static func parse(_ value: Substring) -> PointTarget? {
        let value = value.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("#"), let number = Int(value.dropFirst().prefix { $0.isNumber }) {
            return .element(number)
        }
        let numbers = value.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        if numbers.count >= 4, numbers[2] > 0, numbers[3] > 0 {
            return .area(CGRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3]))
        }
        return numbers.count >= 2 ? .pixel(CGPoint(x: numbers[0], y: numbers[1])) : nil
    }
}
