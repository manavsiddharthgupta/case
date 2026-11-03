import AppKit
import SwiftUI

/// What collecting mode gathered: every collection, and the words in each, app by app.
struct CollectionsPage: View {
    @Environment(AppModel.self) private var model
    @State private var selected: UUID?
    @State private var deleting: UUID?

    private var collector: Collector { model.collector }

    var body: some View {
        HStack(spacing: 0) {
            // The list only shows once there's something in it; until then Start sits in the middle.
            if !model.collections.collections.isEmpty {
                ListColumn(title: "Collected") {
                    toggle
                } rows: {
                    ForEach(model.collections.collections) { collection in
                        ListRow(title: title(for: collection), detail: detail(for: collection), selected: collection.id == selected) {
                            selected = collection.id
                        }
                        .contextMenu {
                            Button("Delete Collection", role: .destructive) { deleting = collection.id }
                                .disabled(collection.id == collector.current)
                        }
                    }
                }
                .transition(.move(edge: .leading).combined(with: .opacity))
                Rule(vertical: true)
            }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .animation(.snappy(duration: 0.25), value: model.collections.collections.isEmpty)
        .onAppear { selected = collector.current ?? selected ?? model.collections.latest?.id }
        .onChange(of: collector.current) { _, id in
            if let id { selected = id }
        }
        .confirmationDialog("Delete this collection?", isPresented: Binding(
            get: { deleting != nil },
            set: { if !$0 { deleting = nil } }
        )) {
            Button("Delete", role: .destructive) {
                if let deleting { model.collections.delete(deleting) }
                if selected == deleting { selected = model.collections.latest?.id }
            }
        } message: {
            Text("Everything in it will be gone for good.")
        }
    }

    @ViewBuilder private var content: some View {
        if let collection = model.collections.collection(selected) {
            CollectionView(collection: collection, isLive: collection.id == collector.current)
        } else {
            EmptyNote(title: "Collect as you scroll",
                      detail: "Turn this on, then scroll through a feed, chat or document. Case keeps every new line it sees, so you can ask about it after.") {
                if model.collections.collections.isEmpty { toggle }
            }
        }
    }

    @ViewBuilder private var toggle: some View {
        if collector.isOn {
            Button("Stop") { collector.stop() }
                .buttonStyle(PillButtonStyle())
        } else {
            Button("Start") { collector.start() }
                .buttonStyle(PillButtonStyle(filled: true))
        }
    }

    private func title(for collection: TextCollection) -> String {
        collection.apps.isEmpty ? "Collecting…" : collection.apps.joined(separator: ", ")
    }

    private func detail(for collection: TextCollection) -> String {
        let lines = "\(collection.lineCount.formatted()) lines"
        return [collection.started.listLabel, collection.id == collector.current ? "Collecting · \(lines)" : lines]
            .joined(separator: " · ")
    }
}

/// One collection: a heading for each app and window, then its lines in the order they appeared.
private struct CollectionView: View {
    @Environment(AppModel.self) private var model
    let collection: TextCollection
    let isLive: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                PageTitle(collection.apps.isEmpty ? "Collecting…" : collection.apps.joined(separator: ", "))
                    .lineLimit(1)
                Spacer()
                if isLive {
                    Button("Stop") { model.collector.stop() }
                        .buttonStyle(PillButtonStyle(filled: true))
                }
                Button("Copy") { copy(collection.text) }
                    .buttonStyle(PillButtonStyle())
                    .disabled(collection.lineCount == 0)
            }

            HStack(spacing: 8) {
                if isLive { RecordingDot() }
                Text(summary)
            }
            .font(Theme.font(13))
            .foregroundStyle(Theme.muted)
            .padding(.top, 2)
            .padding(.bottom, 16)

            Rule()

            if collection.lineCount == 0 {
                EmptyNote(title: "Nothing yet", detail: "Scroll in any app and new lines show up here.")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(collection.parts.indices, id: \.self) { index in
                            let part = collection.parts[index]
                            if !part.lines.isEmpty {
                                Text(part.heading)
                                    .font(Theme.font(17, weight: .medium))
                                    .tracking(-0.3)
                                    .padding(.top, index == 0 ? 0 : 18)
                                    .padding(.bottom, 4)
                                ForEach(part.lines.indices, id: \.self) { line in
                                    Text(part.lines[line])
                                        .font(Theme.font(14))
                                        .lineSpacing(3)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }
                    }
                    .textSelection(.enabled)
                    .frame(maxWidth: 680, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 20)
                }
                // While collecting, new lines come in at the bottom, so stay with them.
                .defaultScrollAnchor(isLive ? .bottom : .top)
            }
        }
        .padding(.horizontal, 32)
        .padding(.top, 44)
        .padding(.bottom, 12)
    }

    private var summary: String {
        let lines = "\(collection.lineCount.formatted()) lines"
        let when = collection.started.formatted(date: .long, time: .shortened)
        if isLive { return model.collector.isFull ? "Full · \(lines)" : "Collecting · \(lines)" }
        return "\(when) · \(lines)"
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
