import SwiftUI

/// Case's window: your chats, meetings and memory, with a sidebar to move between them.
struct MainWindow: View {
    @Environment(AppModel.self) private var model
    @AppStorage("window.sidebarHidden") private var sidebarHidden = false

    var body: some View {
        HStack(spacing: 0) {
            if !sidebarHidden {
                Sidebar()
                    .transition(.move(edge: .leading))
                Rule(vertical: true)
            }
            Group {
                switch model.page {
                case .chats: ChatsPage()
                case .meetings: MeetingsPage()
                case .memory: MemoryPage()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // Beside the window's close, minimize and zoom buttons, as in Mac apps like Notes.
        .overlay(alignment: .topLeading) {
            Button {
                withAnimation(.snappy(duration: 0.25)) { sidebarHidden.toggle() }
            } label: {
                Image(systemName: "sidebar.left")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.muted)
                    .frame(width: 26, height: 24)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .keyboardShortcut("s", modifiers: [.control, .command])
            .help(sidebarHidden ? "Show sidebar" : "Hide sidebar")
            .padding(.leading, 78)
            // Level with the middle of those buttons.
            .padding(.top, 4)
        }
        .font(Theme.font(14))
        .foregroundStyle(Theme.foreground)
        .tint(Theme.foreground)
        .background(Theme.background)
        .ignoresSafeArea(edges: .top)
        .frame(minWidth: 820, minHeight: 520)
        // A real app while the window is open: it shows in the Dock and in ⌘Tab.
        .onAppear {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate()
        }
        .onDisappear { NSApp.setActivationPolicy(.accessory) }
    }
}

private struct Sidebar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 10) {
                // The same width as the icons below, so the words line up.
                MarkGlyph(size: 18, color: Theme.foreground)
                Text("Case")
                    .font(Theme.font(16, weight: .medium))
                    .tracking(-0.3)
            }
            .padding(.horizontal, 10)
            .padding(.top, 52)
            .padding(.bottom, 20)

            ForEach(AppModel.Page.allCases, id: \.self) { page in
                SidebarRow(page: page)
            }

            Spacer()

            if model.recorder.isCapturing, let startedAt = model.recorder.startedAt {
                let paused = model.recorder.phase == .paused
                Button {
                    model.page = .meetings
                } label: {
                    HStack(spacing: 8) {
                        RecordingDot(paused: paused)
                        Text(paused ? "Paused" : "Recording")
                        Spacer()
                        if !paused {
                            Text(startedAt, style: .timer)
                                .monospacedDigit()
                                .foregroundStyle(Theme.muted)
                        }
                    }
                    .font(Theme.font(13))
                    .padding(.horizontal, 10)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .padding(.bottom, 12)
            }

            Text(model.claude.summary)
                .font(Theme.font(12))
                .foregroundStyle(Theme.muted)
                .padding(.horizontal, 10)
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 16)
        .frame(width: 200)
        .frame(maxHeight: .infinity)
        .background(Theme.card)
    }
}

private struct SidebarRow: View {
    @Environment(AppModel.self) private var model
    let page: AppModel.Page

    var body: some View {
        let selected = model.page == page
        Button {
            model.page = page
        } label: {
            HStack(spacing: 10) {
                Image(systemName: page.symbol)
                    .frame(width: 18)
                Text(page.title)
                Spacer()
            }
            .font(Theme.font(14, weight: selected ? .medium : .regular))
            .foregroundStyle(selected ? Theme.foreground : Theme.muted)
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(selected ? Theme.pill : .clear, in: .rect(cornerRadius: 8))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

/// The list down the left of the Chats and Meetings pages.
struct ListColumn<Header: View, Rows: View>: View {
    let title: String
    @ViewBuilder let header: Header
    @ViewBuilder let rows: Rows

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                PageTitle(title)
                Spacer()
                header
            }
            .padding(.horizontal, 16)
            .padding(.top, 44)
            .padding(.bottom, 14)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) { rows }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 12)
            }
        }
        .frame(width: 270)
    }
}

/// One saved chat or meeting in that list.
struct ListRow: View {
    let title: String
    let detail: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Theme.font(14, weight: selected ? .medium : .regular))
                    .lineLimit(1)
                Text(detail)
                    .font(Theme.font(12))
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(selected ? Theme.pill : .clear, in: .rect(cornerRadius: 8))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

struct RecordingDot: View {
    var paused = false

    var body: some View {
        Circle()
            .fill(paused ? Theme.ghost : Color.red)
            .frame(width: 8, height: 8)
    }
}

extension AppModel.Page {
    var title: String {
        switch self {
        case .chats: "Chats"
        case .meetings: "Meetings"
        case .memory: "Memory"
        }
    }

    var symbol: String {
        switch self {
        case .chats: "bubble.left"
        case .meetings: "waveform"
        case .memory: "brain"
        }
    }
}

extension Date {
    /// "3:42 pm" today, "Yesterday", or "28 Oct".
    var listLabel: String {
        if Calendar.current.isDateInToday(self) { return formatted(date: .omitted, time: .shortened) }
        if Calendar.current.isDateInYesterday(self) { return "Yesterday" }
        return formatted(.dateTime.day().month())
    }
}
