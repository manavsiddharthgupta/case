import AppKit
import Contacts
import SQLite3

/// iMessage, SMS and RCS through the Messages app, with nothing moving on screen. Reading uses
/// Messages' own database, which needs Full Disk Access. Sending goes through Messages itself,
/// then the database shows whether the message really went out.
nonisolated enum MessagesApp {
    enum Failure: Error {
        case needsFullDiskAccess
        case failed(String)
    }

    /// Who a message goes to: one person, or a group chat.
    struct Recipient: Sendable {
        var name: String
        var address: String
        var service: String
        var isGroup = false
    }

    private struct Person {
        var name: String
        var addresses: [String]
    }

    fileprivate struct Conversation {
        var id: Int64
        var guid: String
        var identifier: String
        var displayName: String
        var service: String
        var isGroup: Bool { identifier.hasPrefix("chat") }
    }

    fileprivate struct Message {
        var text: String
        var isFromMe: Bool
        var isRead: Bool
        var date: Date
        var sender: String
        var chatID: Int64
    }

    private static let databaseURL = URL.homeDirectory.appending(path: "Library/Messages/chat.db")
    private static let longestMessage = 500
    private static let chatsListed = 10
    private static let settingsPage = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!

    // MARK: Reading

    /// The latest chats, or one chat when `person` is a name, number or group.
    @concurrent
    static func read(person: String?, count: Int) async throws -> String {
        let book = await addressBook()
        let database = try Database(url: databaseURL)
        let chats = try database.chats()
        let query = (person ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        if query.isEmpty {
            let latest = try database.messages(in: nil, limit: 400)
            var seen: [Int64] = []
            for message in latest where !seen.contains(message.chatID) && seen.count < chatsListed { seen.append(message.chatID) }
            guard !seen.isEmpty else { return "There are no messages." }
            return seen.map { id in
                let messages = latest.filter { $0.chatID == id }
                let unread = messages.filter { !$0.isRead && !$0.isFromMe }.count
                let name = chats.first { $0.id == id }.map { name(of: $0, book) } ?? "Unknown"
                return "\(name)\(unread > 0 ? " (\(unread) unread)" : ""): \(line(messages[0], book))"
            }.joined(separator: "\n")
        }

        let keys = addressKeys(for: query, book)
        let matches = chats.filter { keys.contains(key($0.identifier)) || $0.displayName.localizedCaseInsensitiveContains(query) }
        guard !matches.isEmpty else { return "No messages with \(query)." }
        let messages = try database.messages(in: matches.map(\.id), limit: max(1, min(count, 50)))
        guard !messages.isEmpty else { return "No messages with \(query)." }
        return messages.reversed().map { line($0, book) }.joined(separator: "\n")
    }

    private static func line(_ message: Message, _ book: [Person]) -> String {
        let when = message.date.formatted(date: .abbreviated, time: .shortened)
        let who = message.isFromMe ? "You" : name(ofAddress: message.sender, book)
        let text = message.text.count > longestMessage ? message.text.prefix(longestMessage) + "…" : message.text
        return "[\(when)] \(who): \(text)"
    }

    private static func name(of chat: Conversation, _ book: [Person]) -> String {
        if !chat.displayName.isEmpty { return chat.displayName }
        return chat.isGroup ? "Group chat" : name(ofAddress: chat.identifier, book)
    }

    private static func name(ofAddress address: String, _ book: [Person]) -> String {
        let wanted = key(address)
        return book.first { $0.addresses.contains { key($0) == wanted } }?.name ?? address
    }

    // MARK: Sending

    /// Works out exactly who a name means. More than one match is a failure, so nothing goes to a guess.
    @concurrent
    static func recipient(for to: String) async throws -> Recipient {
        let query = to.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { throw Failure.failed("Say who it's for.") }
        let chats = (try? Database(url: databaseURL).chats()) ?? []

        if isAddress(query) {
            let chat = chats.first { key($0.identifier) == key(query) }
            return Recipient(name: query, address: chat?.identifier ?? tidy(query), service: chat?.service ?? "iMessage")
        }

        let book = await addressBook()
        let people = matchingPeople(query, book)
        let groups = chats.filter { $0.isGroup && $0.displayName.localizedCaseInsensitiveContains(query) }
        let names = people.map(\.name) + groups.map(\.displayName)
        guard names.count == 1 else {
            throw Failure.failed(names.isEmpty ? "There's no contact or group called \(query), so nothing was sent. Ask the user for the number."
                : "Nothing was sent, because \(query) could mean \(names.joined(separator: ", ")). Ask which one.")
        }
        if let group = groups.first {
            return Recipient(name: group.displayName, address: group.guid, service: group.service, isGroup: true)
        }

        let person = people[0]
        // Chats are newest first, so someone with two numbers gets the one you've been using.
        if let chat = chats.first(where: { chat in person.addresses.contains { key($0) == key(chat.identifier) } }) {
            return Recipient(name: person.name, address: chat.identifier, service: chat.service)
        }
        guard person.addresses.count == 1 else {
            throw Failure.failed(person.addresses.isEmpty ? "\(person.name) has no number or email, so nothing was sent."
                : "Nothing was sent, because \(person.name) has several numbers: \(person.addresses.joined(separator: ", ")). Ask which one.")
        }
        return Recipient(name: person.name, address: tidy(person.addresses[0]), service: "iMessage")
    }

    /// Hands the message to Messages, then checks it went out. Returns what to tell the user.
    @concurrent
    static func send(_ text: String, to recipient: Recipient) async throws -> String {
        let before = try? Database(url: databaseURL).lastSentID()
        let target = recipient.isGroup ? "chat id theAddress"
            : "participant theAddress of (first account whose service type is \(serviceType(recipient.service)))"
        let script = """
            on run argv
            set theAddress to item 1 of argv
            set theText to item 2 of argv
            tell application "Messages" to send theText to \(target)
            end run
            """
        // The address goes first: osascript would read text starting with a dash as an option.
        let result = try await ClaudeCLI.run(URL(fileURLWithPath: "/usr/bin/osascript"), ["-e", script, recipient.address, text])
        guard result.status == 0 else {
            throw Failure.failed("Messages couldn't send it, so nothing went to \(recipient.name). Case may need permission to control Messages.")
        }

        guard let before else { return "Messages took it, but Case can't check that it went out without Full Disk Access." }
        for _ in 0..<16 {
            try await Task.sleep(for: .milliseconds(500))
            guard let sent = try? Database(url: databaseURL).sentMessage(after: before, text: text) else { continue }
            if sent.failed { throw Failure.failed("Messages couldn't deliver it to \(recipient.name).") }
            if sent.isSent { return "Sent to \(recipient.name)." }
        }
        return "Messages took it, but it hasn't shown as sent to \(recipient.name) yet. Tell the user it may not have gone out."
    }

    /// Whether the user's own words asked to message this person. Claude's choice of recipient
    /// isn't enough, since it may have just read a message telling it what to do.
    static func wasAsked(_ question: String, toMessage recipient: Recipient) -> Bool {
        let words = Set(question.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
        guard !words.isDisjoint(with: sendWords) else { return false }
        let digits = question.filter(\.isNumber)
        if isAddress(recipient.name) { return digits.contains(key(recipient.name)) }
        return recipient.name.lowercased().split { !$0.isLetter && !$0.isNumber }
            .contains { $0.count >= 2 && words.contains(String($0)) }
    }

    private static let sendWords: Set = ["send", "text", "message", "msg", "tell", "reply", "respond", "answer", "say",
                                         "ask", "wish", "ping", "inform", "imessage", "sms", "let", "write"]

    private static func serviceType(_ service: String) -> String {
        service == "SMS" || service == "RCS" ? service : "iMessage"
    }

    // MARK: Permission

    /// macOS has no prompt for this, so this opens the page, with Case showing in Finder to drag in.
    @MainActor
    static func openFullDiskAccess() {
        NSWorkspace.shared.open(settingsPage)
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }

    // MARK: Contacts

    /// Asks for Contacts the first time. Without it, messages show numbers instead of names.
    private static func addressBook() async -> [Person] {
        let store = CNContactStore()
        if CNContactStore.authorizationStatus(for: .contacts) == .notDetermined {
            _ = try? await store.requestAccess(for: .contacts)
        }
        let keys = [CNContactGivenNameKey, CNContactFamilyNameKey, CNContactNicknameKey, CNContactOrganizationNameKey,
                    CNContactPhoneNumbersKey, CNContactEmailAddressesKey] as [CNKeyDescriptor]
        var people: [Person] = []
        try? store.enumerateContacts(with: CNContactFetchRequest(keysToFetch: keys)) { contact, _ in
            let full = [contact.givenName, contact.familyName].filter { !$0.isEmpty }.joined(separator: " ")
            let name = [full, contact.nickname, contact.organizationName].first { !$0.isEmpty } ?? ""
            let addresses = contact.phoneNumbers.map(\.value.stringValue) + contact.emailAddresses.map { $0.value as String }
            if !name.isEmpty { people.append(Person(name: name, addresses: addresses)) }
        }
        return people
    }

    /// An exact name beats a partial one, so "Sam Lee" doesn't also mean "Sam Leeds".
    private static func matchingPeople(_ query: String, _ book: [Person]) -> [Person] {
        let exact = book.filter { $0.name.caseInsensitiveCompare(query) == .orderedSame }
        return exact.isEmpty ? book.filter { $0.name.localizedCaseInsensitiveContains(query) } : exact
    }

    private static func addressKeys(for query: String, _ book: [Person]) -> Set<String> {
        if isAddress(query) { return [key(query)] }
        return Set(matchingPeople(query, book).flatMap(\.addresses).map(key))
    }

    private static func isAddress(_ text: String) -> Bool {
        text.contains("@") || text.filter(\.isNumber).count >= 7
    }

    /// The same number can be written many ways, so numbers compare by their last ten digits.
    static func key(_ address: String) -> String {
        if address.contains("@") { return address.lowercased() }
        return String(address.filter(\.isNumber).suffix(10))
    }

    private static func tidy(_ address: String) -> String {
        address.contains("@") ? address : address.filter { $0.isNumber || $0 == "+" }
    }

    // MARK: Message text

    /// Newer messages keep their words only in an archived block. This pulls the words straight
    /// out of the bytes, rather than unarchiving objects from something other people can send.
    static func plainText(fromArchive data: Data) -> String? {
        let bytes = [UInt8](data)
        let marker = Array("NSString".utf8)
        guard bytes.count > marker.count,
              var index = (0...(bytes.count - marker.count)).first(where: { Array(bytes[$0..<($0 + marker.count)]) == marker })
        else { return nil }
        index += marker.count
        // A few header bytes come before the "+" that starts the text.
        let headerEnd = min(index + 16, bytes.count)
        while index < headerEnd, bytes[index] != 0x2B { index += 1 }
        index += 1
        guard index < bytes.count else { return nil }

        let lead = bytes[index]
        index += 1
        var length = Int(lead)
        let extra = lead == 0x81 ? 2 : lead == 0x82 ? 4 : 0
        if extra > 0 {
            guard index + extra <= bytes.count else { return nil }
            length = (0..<extra).reduce(0) { $0 | Int(bytes[index + $1]) << (8 * $1) }
            index += extra
        }
        guard length >= 0, index + length <= bytes.count else { return nil }
        return String(decoding: bytes[index..<(index + length)], as: UTF8.self)
    }

    /// Dates are nanoseconds since 2001, or seconds in very old messages.
    fileprivate static func date(from stored: Int64) -> Date {
        Date(timeIntervalSinceReferenceDate: stored > 1_000_000_000_000 ? Double(stored) / 1_000_000_000 : Double(stored))
    }
}

/// A read-only look at Messages' database. Each one is opened, used once and closed.
private nonisolated final class Database {
    private var handle: OpaquePointer?

    init(url: URL) throws {
        // SQLite's error here doesn't say why, and opening the file does.
        guard (try? FileHandle(forReadingFrom: url).close()) != nil else { throw MessagesApp.Failure.needsFullDiskAccess }
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            throw MessagesApp.Failure.failed("Couldn't open the messages.")
        }
        sqlite3_busy_timeout(handle, 1000)
    }

    deinit { sqlite3_close(handle) }

    private func query(_ sql: String, _ values: [Int64] = [], each row: (OpaquePointer) -> Void) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw MessagesApp.Failure.failed("Couldn't read the messages: \(String(cString: sqlite3_errmsg(handle)))")
        }
        defer { sqlite3_finalize(statement) }
        for (index, value) in values.enumerated() { sqlite3_bind_int64(statement, Int32(index + 1), value) }
        while sqlite3_step(statement) == SQLITE_ROW { row(statement) }
    }

    private func text(_ row: OpaquePointer, _ column: Int32) -> String {
        sqlite3_column_text(row, column).map { String(cString: $0) } ?? ""
    }

    /// The words of a message, wherever they're kept.
    private func body(_ row: OpaquePointer, text column: Int32, archive: Int32, attachment: Int32) -> String {
        var words = text(row, column)
        if words.isEmpty, let bytes = sqlite3_column_blob(row, archive) {
            let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(row, archive)))
            words = MessagesApp.plainText(fromArchive: data) ?? ""
        }
        words = words.replacingOccurrences(of: "\u{FFFC}", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        if words.isEmpty { return sqlite3_column_int(row, attachment) != 0 ? "(an attachment)" : "" }
        return words
    }

    /// Newest first.
    func chats() throws -> [MessagesApp.Conversation] {
        var chats: [MessagesApp.Conversation] = []
        try query("""
            SELECT c.ROWID, c.guid, c.chat_identifier, c.display_name, c.service_name
            FROM chat c
            LEFT JOIN (SELECT chat_id, MAX(message_date) AS latest FROM chat_message_join GROUP BY chat_id) j ON j.chat_id = c.ROWID
            ORDER BY j.latest DESC
            """) { row in
            chats.append(.init(id: sqlite3_column_int64(row, 0), guid: text(row, 1), identifier: text(row, 2),
                              displayName: text(row, 3), service: text(row, 4)))
        }
        return chats
    }

    /// Newest first. Reactions and "joined the group" lines aren't messages, so they're left out.
    func messages(in chats: [Int64]?, limit: Int) throws -> [MessagesApp.Message] {
        let only = chats.map { " AND c.ROWID IN (\($0.map(String.init).joined(separator: ",")))" } ?? ""
        var messages: [MessagesApp.Message] = []
        try query("""
            SELECT m.text, m.attributedBody, m.cache_has_attachments, m.is_from_me, m.is_read, m.date, h.id, c.ROWID
            FROM message m
            JOIN chat_message_join j ON j.message_id = m.ROWID
            JOIN chat c ON c.ROWID = j.chat_id
            LEFT JOIN handle h ON h.ROWID = m.handle_id
            WHERE m.associated_message_type = 0 AND m.item_type = 0\(only)
            ORDER BY m.date DESC LIMIT ?
            """, [Int64(limit)]) { row in
            let words = body(row, text: 0, archive: 1, attachment: 2)
            guard !words.isEmpty else { return }
            messages.append(.init(text: words, isFromMe: sqlite3_column_int(row, 3) != 0, isRead: sqlite3_column_int(row, 4) != 0,
                                  date: MessagesApp.date(from: sqlite3_column_int64(row, 5)), sender: text(row, 6),
                                  chatID: sqlite3_column_int64(row, 7)))
        }
        return messages
    }

    func lastSentID() throws -> Int64 {
        var last: Int64 = 0
        try query("SELECT COALESCE(MAX(ROWID), 0) FROM message WHERE is_from_me = 1") { last = sqlite3_column_int64($0, 0) }
        return last
    }

    /// The message Case just sent, found by its words so one sent by hand doesn't count.
    func sentMessage(after id: Int64, text wanted: String) throws -> (isSent: Bool, failed: Bool)? {
        let words = wanted.trimmingCharacters(in: .whitespacesAndNewlines)
        var found: (isSent: Bool, failed: Bool)?
        try query("""
            SELECT text, attributedBody, cache_has_attachments, is_sent, error
            FROM message WHERE is_from_me = 1 AND ROWID > ? ORDER BY ROWID
            """, [id]) { row in
            guard found == nil, body(row, text: 0, archive: 1, attachment: 2) == words else { return }
            found = (sqlite3_column_int(row, 3) != 0, sqlite3_column_int(row, 4) != 0)
        }
        return found
    }
}
