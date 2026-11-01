import SwiftUI

/// Everything Case remembers about you, to read, add to or delete.
struct MemoryPage: View {
    @Environment(AppModel.self) private var model
    @State private var draft = ""

    private var memory: MemoryStore { model.memory }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageTitle("Memory")
            Text("What Case has learned about you. It's kept on your Mac and goes to Claude with each question.")
                .font(Theme.font(14))
                .foregroundStyle(Theme.muted)
                .padding(.top, 4)

            HStack(spacing: 8) {
                TextField("Add something for it to remember…", text: $draft)
                    .textFieldStyle(.plain)
                    .font(Theme.font(14))
                    .padding(.horizontal, 14)
                    .frame(height: 34)
                    .background(Theme.pill, in: .capsule)
                    .onSubmit(add)
                Button("Add", action: add)
                    .buttonStyle(PillButtonStyle(filled: true))
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.top, 20)
            .padding(.bottom, 12)

            if memory.facts.isEmpty, memory.noticed.isEmpty {
                EmptyNote(title: "Nothing yet",
                          detail: "It picks up lasting facts as you chat, or say \"remember that…\" any time.")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Fact.Topic.allCases, id: \.self) { topic in
                            let facts = memory.facts.filter { ($0.topic ?? .you) == topic }
                            if !facts.isEmpty {
                                SectionLabel(text: topic.rawValue)
                                ForEach(facts) { fact in
                                    MemoryRow(text: fact.text, detail: fact.added.listLabel) { memory.delete(fact.id) }
                                }
                            }
                        }
                        if !memory.noticed.isEmpty {
                            SectionLabel(text: "Noticing", detail: "Saved once it comes up in \(MemoryStore.chatsToSave) chats")
                            ForEach(memory.noticed) { item in
                                MemoryRow(text: item.text, detail: "\(item.chats.count) of \(MemoryStore.chatsToSave)", faint: true) {
                                    memory.dropNoticed(item.id)
                                }
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: 640, alignment: .leading)
        .padding(.horizontal, 32)
        .padding(.top, 44)
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func add() {
        if memory.add(draft) { draft = "" }
    }
}

private struct SectionLabel: View {
    let text: String
    var detail: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(text)
                .font(Theme.font(13, weight: .medium))
            if let detail {
                Text(detail)
                    .font(Theme.font(12))
                    .foregroundStyle(Theme.muted)
            }
        }
        .padding(.top, 18)
        .padding(.bottom, 8)
    }
}

private struct MemoryRow: View {
    let text: String
    let detail: String
    var faint = false
    let onDelete: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Rule()
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                Text(text)
                    .font(Theme.font(15))
                    .foregroundStyle(faint ? Theme.muted : Theme.foreground)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(detail)
                    .font(Theme.font(12))
                    .foregroundStyle(Theme.muted)
                Button(action: onDelete) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.muted)
                        .frame(width: 20, height: 20)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help("Delete")
            }
            .padding(.vertical, 12)
        }
    }
}
