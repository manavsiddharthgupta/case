import Foundation

/// Everything that went past on screen while collecting was on, in the order it first showed.
nonisolated struct TextCollection: Codable, Identifiable, Hashable, Sendable {
    /// One stretch in one window. A new part starts when you switch app or window.
    nonisolated struct Part: Codable, Hashable, Sendable {
        var app: String
        var window: String
        var lines: [String] = []

        var heading: String { window.isEmpty || window == app ? app : "\(app): \(window)" }
    }

    var id = UUID()
    var started = Date.now
    /// Still nil while collecting.
    var ended: Date?
    var parts: [Part] = []

    var lineCount: Int { parts.reduce(0) { $0 + $1.lines.count } }
    var characterCount: Int { parts.reduce(0) { $0 + $1.lines.reduce(0) { $0 + $1.count } } }

    /// The apps it came from, in order, each once.
    var apps: [String] {
        parts.map(\.app).reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
    }

    var text: String {
        parts.filter { !$0.lines.isEmpty }
            .map { "## \($0.heading)\n" + $0.lines.joined(separator: "\n") }
            .joined(separator: "\n\n")
    }
}

/// Every collection, one file each in ~/Library/Application Support/Case/collections/.
/// Only words are kept, never screenshots. Saved a moment after lines arrive, so a crash loses little.
@Observable
final class CollectionStore {
    private(set) var collections: [TextCollection] = []

    private static let folder = Storage.folder.appending(path: "collections", directoryHint: .isDirectory)
    private static let saveAfter: Duration = .seconds(2)

    @ObservationIgnored private var pendingSave: Task<Void, Never>?

    init() {
        let files = (try? FileManager.default.contentsOfDirectory(at: Self.folder, includingPropertiesForKeys: nil)) ?? []
        collections = files.compactMap { Storage.load(TextCollection.self, from: $0) }.sorted { $0.started > $1.started }
        // One still open here was cut off when the app last stopped.
        for index in collections.indices where collections[index].ended == nil {
            collections[index].ended = collections[index].started
            save(collections[index])
        }
    }

    var latest: TextCollection? { collections.first }

    func collection(_ id: UUID?) -> TextCollection? {
        collections.first { $0.id == id }
    }

    func start() -> UUID {
        let collection = TextCollection()
        collections.insert(collection, at: 0)
        save(collection)
        return collection.id
    }

    /// Lines arrive often, so they're written out once things go quiet.
    func update(_ id: UUID, _ change: (inout TextCollection) -> Void) {
        guard let index = collections.firstIndex(where: { $0.id == id }) else { return }
        change(&collections[index])
        pendingSave?.cancel()
        pendingSave = Task { [weak self] in
            try? await Task.sleep(for: Self.saveAfter)
            guard !Task.isCancelled, let self, let collection = collection(id) else { return }
            save(collection)
        }
    }

    func finish(_ id: UUID) {
        guard let index = collections.firstIndex(where: { $0.id == id }) else { return }
        pendingSave?.cancel()
        collections[index].ended = .now
        // Nothing collected isn't worth keeping.
        if collections[index].lineCount == 0 { return delete(id) }
        save(collections[index])
    }

    func delete(_ id: UUID) {
        collections.removeAll { $0.id == id }
        try? FileManager.default.removeItem(at: Self.file(id))
    }

    private func save(_ collection: TextCollection) {
        Storage.save(collection, to: Self.file(collection.id))
    }

    private static func file(_ id: UUID) -> URL {
        folder.appending(path: "\(id.uuidString).json")
    }
}
