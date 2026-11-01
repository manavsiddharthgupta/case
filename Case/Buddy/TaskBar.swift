import AppKit
import SwiftUI

/// The running tasks at the top right, with a Stop for each. It shows while there's anything in
/// it, and never takes the keyboard. Stop stops straight away, with no "are you sure".
final class TaskBar: NSPanel {
    private static let width: CGFloat = 320
    private static let edgeGap: CGFloat = 12

    private let tasks: TaskManager

    init(tasks: TaskManager) {
        self.tasks = tasks
        super.init(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 60), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
    }

    override var canBecomeKey: Bool { false }

    /// Called when a task starts, ends or goes away. Steps and timers update by themselves.
    func refresh() {
        guard !tasks.items.isEmpty else { return orderOut(nil) }
        // A new view each time, so it measures what's there now.
        let view = FirstClickHostingView(rootView: TaskList(tasks: tasks, width: Self.width))
        view.sizingOptions = .intrinsicContentSize
        contentView = view
        let size = view.fittingSize
        let mouse = NSEvent.mouseLocation
        let visible = (NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main)?.visibleFrame ?? .zero
        // Stays where it is while it's up, rather than following the mouse between screens.
        let right = isVisible ? frame.maxX : visible.maxX - Self.edgeGap
        let top = isVisible ? frame.maxY : visible.maxY - Self.edgeGap
        setFrame(NSRect(x: right - Self.width, y: top - size.height, width: Self.width, height: size.height), display: true)
        orderFrontRegardless()
    }
}

private struct TaskList: View {
    let tasks: TaskManager
    let width: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            ForEach(tasks.items) { item in
                TaskRow(item: item, tasks: tasks)
                if item.id != tasks.items.last?.id { Divider() }
            }
        }
        .frame(width: width)
        // Behind the content, not around it: glass drains the colour out of what it holds.
        .background { Color.clear.glassEffect(.regular, in: .rect(cornerRadius: 16)) }
    }
}

private struct TaskRow: View {
    let item: TaskManager.Item
    let tasks: TaskManager

    var body: some View {
        HStack(spacing: 10) {
            icon.frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(item.isActive ? 1 : 2)
                    .help(detail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            trailing
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder private var icon: some View {
        switch item.state {
        case .waiting: Image(systemName: "clock").foregroundStyle(.secondary)
        case .running: ProgressView().controlSize(.small)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
        }
    }

    private var detail: String {
        switch item.state {
        case .waiting: "Waiting for another task"
        case .running: item.step
        case .done(let summary, _): summary
        case .failed(let problem): problem
        }
    }

    @ViewBuilder private var trailing: some View {
        switch item.state {
        case .waiting, .running:
            if let started = item.started {
                Text(timerInterval: started...Date.distantFuture, countsDown: false)
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .trailing)
            }
            button("stop.circle.fill", label: "Stop", size: 20) { tasks.stop(item.id) }
        case .done(_, let path?):
            Button("Open") { tasks.open(path, from: item.id) }
                .buttonStyle(.plain)
                .font(.system(size: 13, weight: .medium))
            button("xmark", label: "Dismiss", size: 11) { tasks.dismiss(item.id) }
        case .done, .failed:
            button("xmark", label: "Dismiss", size: 11) { tasks.dismiss(item.id) }
        }
    }

    private func button(_ symbol: String, label: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}
