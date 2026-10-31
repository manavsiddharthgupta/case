import AppKit
import SwiftUI

/// Meeting notes: start one, jot things down while it runs, and read the notes afterwards.
struct MeetingsPage: View {
    @Environment(AppModel.self) private var model
    @State private var selected: UUID?
    @State private var deleting: UUID?

    private var recorder: MeetingRecorder { model.recorder }

    var body: some View {
        HStack(spacing: 0) {
            // The list only shows once there's something in it; until then Start sits in the middle.
            if !model.meetings.meetings.isEmpty {
                ListColumn(title: "Meetings") {
                    startButton
                } rows: {
                    ForEach(model.meetings.meetings) { meeting in
                        ListRow(title: meeting.title, detail: detail(for: meeting), selected: meeting.id == selected) {
                            selected = meeting.id
                        }
                        .contextMenu {
                            Button("Delete Meeting", role: .destructive) { deleting = meeting.id }
                                .disabled(meeting.id == recorder.meetingID)
                        }
                    }
                }
                .transition(.move(edge: .leading).combined(with: .opacity))
                Rule(vertical: true)
            }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .animation(.snappy(duration: 0.25), value: model.meetings.meetings.isEmpty)
        .onAppear { selected = recorder.meetingID ?? selected ?? model.meetings.meetings.first?.id }
        .onChange(of: recorder.meetingID) { _, id in
            if let id { selected = id }
        }
        .confirmationDialog("Delete this meeting?", isPresented: Binding(
            get: { deleting != nil },
            set: { if !$0 { deleting = nil } }
        )) {
            Button("Delete", role: .destructive) {
                if let deleting { model.meetings.delete(deleting) }
                if selected == deleting { selected = model.meetings.meetings.first?.id }
            }
        } message: {
            Text("Its notes and transcript will be gone for good.")
        }
    }

    @ViewBuilder private var content: some View {
        if let meeting = model.meetings.meeting(selected) {
            if meeting.id == recorder.meetingID, recorder.phase == .stopping {
                WritingNotes()
            } else if meeting.id == recorder.meetingID {
                LiveMeeting(meeting: meeting)
            } else {
                FinishedMeeting(meeting: meeting)
            }
        } else if let problem = recorder.problem {
            EmptyNote(title: "That didn't work", detail: problem) { emptyStart }
        } else {
            EmptyNote(title: "No bot joins the call",
                      detail: "Press Start when a meeting begins. Case listens through your Mac and keeps only the text.") {
                emptyStart
            }
        }
    }

    @ViewBuilder private var startButton: some View {
        if !recorder.isActive {
            Button("Start") { Task { await recorder.start() } }
                .buttonStyle(PillButtonStyle(filled: true))
        }
    }

    @ViewBuilder private var emptyStart: some View {
        if model.meetings.meetings.isEmpty {
            startButton
        }
    }

    private func detail(for meeting: Meeting) -> String {
        let minutes = meeting.ended.map { "\(max(Int($0.timeIntervalSince(meeting.started) / 60), 1)) min" }
        return [meeting.started.listLabel, minutes ?? "Recording"].joined(separator: " · ")
    }
}

/// While the meeting runs: your own notes, and what's being said.
private struct LiveMeeting: View {
    @Environment(AppModel.self) private var model
    let meeting: Meeting

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                let paused = model.recorder.phase == .paused
                RecordingDot(paused: paused)
                if paused {
                    Text("Paused")
                        .foregroundStyle(Theme.muted)
                } else if let startedAt = model.recorder.startedAt {
                    Text(startedAt, style: .timer)
                        .font(Theme.font(14))
                        .monospacedDigit()
                        .foregroundStyle(Theme.muted)
                } else {
                    Text("Starting…")
                        .foregroundStyle(Theme.muted)
                }
                Spacer()
                Button(paused ? "Resume" : "Pause") {
                    Task { await paused ? model.recorder.resume() : model.recorder.pause() }
                }
                .buttonStyle(PillButtonStyle())
                .disabled(!model.recorder.isCapturing)
                Button("Stop") { Task { await model.recorder.stop() } }
                    .buttonStyle(PillButtonStyle(filled: true))
                    .disabled(!model.recorder.isCapturing)
            }
            .padding(.horizontal, 28)
            .padding(.top, 44)
            .padding(.bottom, 14)

            HStack(spacing: 0) {
                JottedNotes(meeting: meeting)
                Rule(vertical: true)
                TranscriptView(lines: meeting.lines, hearing: model.recorder.hearing, inset: 16)
                    .frame(width: 260)
            }
            .overlay(alignment: .top) { Rule() }
        }
    }
}

private struct JottedNotes: View {
    @Environment(AppModel.self) private var model
    let meeting: Meeting

    var body: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: Binding(
                get: { meeting.jotted },
                set: { text in model.meetings.update(meeting.id) { $0.jotted = text } }
            ))
            .font(Theme.font(15))
            .lineSpacing(4)
            .scrollContentBackground(.hidden)
            .padding(.horizontal, 23)
            .padding(.vertical, 20)
            if meeting.jotted.isEmpty {
                Text("Jot down what matters, or leave this empty. Your notes shape the final write-up.")
                    .font(Theme.font(15))
                    .foregroundStyle(Theme.muted)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 20)
                    .allowsHitTesting(false)
            }
        }
    }
}

private struct WritingNotes: View {
    var body: some View {
        VStack(spacing: 16) {
            MarkView(active: true, size: 44)
            Text("Writing your notes…")
                .font(Theme.font(16))
                .foregroundStyle(Theme.muted)
        }
    }
}

/// A finished meeting: the notes, the full transcript, and what you jotted down.
private struct FinishedMeeting: View {
    @Environment(AppModel.self) private var model
    let meeting: Meeting

    private enum Tab: String, CaseIterable {
        case notes = "Notes"
        case transcript = "Transcript"
        case jotted = "Your notes"
    }

    @State private var tab = Tab.notes
    @State private var making = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField("Meeting name", text: Binding(
                get: { meeting.title },
                set: { title in model.meetings.update(meeting.id) { $0.title = title } }
            ))
            .textFieldStyle(.plain)
            .font(Theme.font(28))
            .tracking(-0.8)

            Text(meeting.started.formatted(date: .long, time: .shortened))
                .font(Theme.font(13))
                .foregroundStyle(Theme.muted)
                .padding(.top, 2)

            HStack(spacing: 4) {
                ForEach(Tab.allCases, id: \.self) { item in
                    Button(item.rawValue) { tab = item }
                        .font(Theme.font(13, weight: tab == item ? .medium : .regular))
                        .foregroundStyle(tab == item ? Theme.foreground : Theme.muted)
                        .padding(.horizontal, 12)
                        .frame(height: 28)
                        .background(tab == item ? Theme.pill : .clear, in: .capsule)
                        .contentShape(.capsule)
                        .buttonStyle(.plain)
                }
                Spacer()
                if tab == .notes, let notes = meeting.notes {
                    Button("Copy") { Self.copy(notes.asText) }
                        .buttonStyle(PillButtonStyle())
                } else if tab == .transcript, !meeting.lines.isEmpty {
                    Button("Copy") { Self.copy(meeting.transcript) }
                        .buttonStyle(PillButtonStyle())
                }
            }
            .padding(.top, 16)
            .padding(.bottom, 12)

            Rule()

            switch tab {
            case .notes: notes
            case .transcript: TranscriptView(lines: meeting.lines, hearing: [:])
            case .jotted:
                if meeting.jotted.isEmpty {
                    EmptyNote(title: "Nothing jotted down", detail: "Anything you type during a meeting stays here.")
                } else {
                    ScrollView {
                        Text(meeting.jotted)
                            .font(Theme.font(15))
                            .lineSpacing(4)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 20)
                    }
                }
            }
        }
        .padding(.horizontal, 32)
        .padding(.top, 44)
        .padding(.bottom, 12)
    }

    @ViewBuilder private var notes: some View {
        if let notes = meeting.notes {
            ScrollView {
                NotesView(notes: notes)
                    .padding(.vertical, 20)
            }
        } else if making {
            WritingNotes()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 14) {
                EmptyNote(title: "No notes yet", detail: model.recorder.problem ?? "These can be made from the transcript.")
                    .frame(maxHeight: 120)
                Button("Make notes") {
                    making = true
                    Task {
                        await model.recorder.makeNotes(for: meeting.id)
                        making = false
                    }
                }
                .buttonStyle(PillButtonStyle(filled: true))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

private struct NotesView: View {
    let notes: Meeting.Notes

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text(notes.summary)
                .font(Theme.font(17))
                .lineSpacing(4)

            ForEach(notes.sections, id: \.self) { section in
                VStack(alignment: .leading, spacing: 8) {
                    Text(section.title)
                        .font(Theme.font(20))
                        .tracking(-0.4)
                    ForEach(section.points, id: \.self) { point in
                        Point(text: point)
                    }
                }
            }

            if !notes.actions.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Action items")
                        .font(Theme.font(20))
                        .tracking(-0.4)
                    ForEach(notes.actions, id: \.self) { action in
                        Point(text: action.task, owner: action.owner)
                    }
                }
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: 640, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct Point: View {
    let text: String
    var owner: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("–")
                .foregroundStyle(Theme.muted)
            Text("\(Text(owner.map { "\($0)  " } ?? "").foregroundStyle(Theme.muted))\(text)")
                .lineSpacing(3)
        }
        .font(Theme.font(15))
    }
}

/// Who said what, with neighbouring lines from the same side joined up.
private struct TranscriptView: View {
    let lines: [Meeting.Line]
    let hearing: [Meeting.Speaker: String]
    var inset: CGFloat = 0

    private struct Block: Identifiable {
        let id: UUID
        let speaker: Meeting.Speaker
        let at: Double
        var text: String
    }

    private var blocks: [Block] {
        var blocks: [Block] = []
        for line in lines {
            if blocks.last?.speaker == line.speaker {
                blocks[blocks.count - 1].text += " " + line.text
            } else {
                blocks.append(Block(id: line.id, speaker: line.speaker, at: line.at, text: line.text))
            }
        }
        return blocks
    }

    var body: some View {
        if lines.isEmpty, hearing.isEmpty {
            EmptyNote(title: "Listening", detail: "What's said will show up here.")
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(blocks) { block in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(block.speaker.name)  \(Meeting.clock(block.at))")
                                .font(Theme.font(12))
                                .foregroundStyle(Theme.muted)
                            Text(block.text)
                                .font(Theme.font(14))
                                .lineSpacing(3)
                                .textSelection(.enabled)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    ForEach([Meeting.Speaker.you, .them], id: \.self) { speaker in
                        if let words = hearing[speaker], !words.isEmpty {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(speaker.name)
                                    .font(Theme.font(12))
                                Text(words)
                                    .font(Theme.font(14))
                            }
                            .foregroundStyle(Theme.muted)
                        }
                    }
                }
                .padding(.vertical, 20)
                .padding(.horizontal, inset)
            }
            .defaultScrollAnchor(.bottom)
        }
    }
}
