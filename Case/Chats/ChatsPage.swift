import SwiftUI

/// Every chat, and the chance to carry on with any of them.
struct ChatsPage: View {
    @Environment(AppModel.self) private var model
    /// Nil is a new chat that hasn't started yet.
    @State private var selected: UUID?
    @State private var draft = ""
    @FocusState private var typing: Bool

    private var assistant: Assistant { model.assistant }

    var body: some View {
        HStack(spacing: 0) {
            // The list only shows once there's something in it.
            if !model.chats.chats.isEmpty {
                ListColumn(title: "Chats") {
                    Button("New") {
                        selected = nil
                        typing = true
                    }
                    .buttonStyle(PillButtonStyle())
                } rows: {
                    ForEach(model.chats.chats) { chat in
                        ListRow(title: chat.title, detail: chat.updated.listLabel, selected: chat.id == selected) {
                            selected = chat.id
                        }
                        .contextMenu {
                            Button("Delete Chat", role: .destructive) { delete(chat.id) }
                        }
                    }
                }
                .transition(.move(edge: .leading).combined(with: .opacity))
                Rule(vertical: true)
            }
            VStack(spacing: 0) {
                conversation
                composer
            }
        }
        .animation(.snappy(duration: 0.25), value: model.chats.chats.isEmpty)
        .onAppear { selected = assistant.currentChat ?? model.chats.chats.first?.id }
        // A chat started at the cursor, or from the box here.
        .onChange(of: assistant.currentChat) { _, chat in
            if let chat { selected = chat }
        }
    }

    /// The question being answered, if it belongs to the chat on screen.
    private var isAnswering: Bool {
        assistant.isBusy && selected != nil && assistant.currentChat == selected
    }

    @ViewBuilder private var conversation: some View {
        if let chat = model.chats.chat(selected), !chat.turns.isEmpty || isAnswering {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    ForEach(chat.turns) { turn in
                        Asked(text: turn.question)
                        Replied(text: turn.answer.isEmpty ? "Stopped before answering." : turn.answer, faint: turn.answer.isEmpty)
                    }
                    if isAnswering {
                        Asked(text: assistant.question)
                        let waiting = assistant.status.isEmpty ? "Thinking…" : assistant.status
                        Replied(text: assistant.answer.isEmpty ? waiting : assistant.answer, faint: assistant.answer.isEmpty)
                    }
                }
                .frame(maxWidth: 640)
                .padding(.horizontal, 28)
                .padding(.top, 8)
                .padding(.bottom, 20)
                .frame(maxWidth: .infinity)
            }
            .defaultScrollAnchor(.bottom)
            .id(chat.id)
            // Clear of the title bar, which treats a scroll area under it specially.
            .padding(.top, 36)
        } else {
            EmptyNote(title: "Ask anything",
                      detail: "Your chats from the cursor show up here too. Text only, kept on your Mac.")
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Ask anything…", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(Theme.font(15))
                .lineLimit(1...6)
                .focused($typing)
                .onSubmit(send)
                .padding(.vertical, 5)
            if assistant.isBusy {
                Button(action: assistant.dismiss) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 10))
                        .frame(width: 28, height: 28)
                        .foregroundStyle(Theme.background)
                        .background(Theme.foreground, in: .circle)
                }
                .buttonStyle(.plain)
                .help("Stop")
            } else {
                Button(action: send) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 28, height: 28)
                        .foregroundStyle(Theme.background)
                        .background(canSend ? Theme.foreground : Theme.ghost, in: .circle)
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 7)
        .padding(.vertical, 7)
        .background(Theme.pill, in: .rect(cornerRadius: 21))
        .frame(maxWidth: 640)
        .padding(.horizontal, 28)
        .padding(.bottom, 20)
        .padding(.top, 8)
    }

    private var canSend: Bool {
        assistant.phase == .ready && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func send() {
        guard canSend else { return }
        assistant.askInWindow(draft, chat: selected)
        draft = ""
    }

    private func delete(_ id: UUID) {
        assistant.deleteChat(id)
        if selected == id { selected = model.chats.chats.first?.id }
    }
}

/// What you said.
private struct Asked: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Theme.font(15))
            .lineSpacing(3)
            .textSelection(.enabled)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(Theme.pill, in: .rect(cornerRadius: 16))
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.leading, 80)
    }
}

/// What Case said.
private struct Replied: View {
    let text: String
    var faint = false

    var body: some View {
        Text(text)
            .font(Theme.font(15))
            .lineSpacing(4)
            .foregroundStyle(faint ? Theme.muted : Theme.foreground)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
