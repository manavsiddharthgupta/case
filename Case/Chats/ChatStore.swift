import Foundation

/// A saved conversation: the words, plus any screenshot you asked Case to take. The screenshots
/// sent along with each question are never kept.
nonisolated struct Chat: Codable, Identifiable, Hashable, Sendable {
    nonisolated struct Turn: Codable, Identifiable, Hashable, Sendable {
        var id = UUID()
        var question: String
        var answer: String
        var date = Date.now
        /// Paths of screenshots taken for you during this turn.
        var images: [String] = []

        init(question: String, answer: String, images: [String] = []) {
            self.question = question
            self.answer = answer
            self.images = images
        }

        // Chats saved before screenshots have no images.
        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(UUID.self, forKey: .id)
            question = try container.decode(String.self, forKey: .question)
            answer = try container.decode(String.self, forKey: .answer)
            date = try container.decode(Date.self, forKey: .date)
            images = try container.decodeIfPresent([String].self, forKey: .images) ?? []
        }
    }

    var id = UUID()
    var title: String
    var updated = Date.now
    var turns: [Turn] = []
    /// How many turns memory has already learned from, so a continued chat isn't read twice.
    var learnedTurns = 0
}

/// Every chat, in ~/Library/Application Support/Case/chats.json. Newest first.
@Observable
final class ChatStore {
    private(set) var chats: [Chat] = []

    private static let file = Storage.folder.appending(path: "chats.json")

    init() {
        // An app that quit mid-answer can leave a chat with nothing in it.
        chats = (Storage.load([Chat].self, from: Self.file) ?? []).filter { !$0.turns.isEmpty }
    }

    func chat(_ id: UUID?) -> Chat? {
        chats.first { $0.id == id }
    }

    func start(question: String) -> UUID {
        let oneLine = question.split(whereSeparator: \.isNewline).joined(separator: " ")
        let chat = Chat(title: oneLine.count > 60 ? oneLine.prefix(60) + "…" : oneLine)
        chats.insert(chat, at: 0)
        return chat.id
    }

    func add(question: String, answer: String, images: [String] = [], to id: UUID) {
        guard let index = chats.firstIndex(where: { $0.id == id }) else { return }
        var chat = chats.remove(at: index)
        chat.turns.append(.init(question: question, answer: answer, images: images))
        chat.updated = .now
        chats.insert(chat, at: 0)
        save()
    }

    func markLearned(_ id: UUID) {
        guard let index = chats.firstIndex(where: { $0.id == id }) else { return }
        chats[index].learnedTurns = chats[index].turns.count
        save()
    }

    func delete(_ id: UUID) {
        chats.removeAll { $0.id == id }
        save()
    }

    private func save() {
        Storage.save(chats.filter { !$0.turns.isEmpty }, to: Self.file)
    }
}

/// Where Case keeps what it saves. Nothing here leaves the Mac by itself.
nonisolated enum Storage {
    static let folder = URL.applicationSupportDirectory.appending(path: "Case", directoryHint: .isDirectory)

    static func load<Value: Decodable>(_ type: Value.Type, from file: URL) -> Value? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? decoder.decode(type, from: data)
    }

    static func save(_ value: some Encodable, to file: URL) {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? encoder.encode(value) else { return }
        try? data.write(to: file, options: .atomic)
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}
