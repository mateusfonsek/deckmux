import AppKit
import DeckmuxMonitor
import SwiftUI

/// The Janelinha's content: one block per session (face, name,
/// state, pulse, subagents) and the usage footer; or, collapsed, a row of
/// faces over two thin usage bars. The panel provides the material behind it.
struct MonitorView: View {
    @ObservedObject var model: MonitorModel
    let collapsed: Bool
    let onReveal: (UUID) -> Void
    let onToggleCollapse: () -> Void

    static let width: CGFloat = 300
    static let collapsedWidth: CGFloat = 150

    @State private var hovered = false

    var body: some View {
        Group {
            if collapsed { collapsedBody } else { fullBody }
        }
        .onHover { hovered = $0 }
        .animation(.easeInOut(duration: 0.2), value: model.sessions.map(\.id))
    }

    // MARK: Full

    private var fullBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !model.sessions.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(model.sessions) { session in
                        SessionBlock(session: session, eyesFrame: model.eyesFrame, onReveal: onReveal)
                            .transition(.opacity)
                    }
                }
                .padding(.bottom, 6)
                Divider().opacity(0.6)
            }
            UsageFooter(usage: model.usage, problem: model.usageProblem, thin: false)
                .padding(.top, model.sessions.isEmpty ? 0 : 8)
        }
        .padding(10)
        .frame(width: Self.width, alignment: .leading)
        .overlay(alignment: .topTrailing) { collapseButton.opacity(hovered ? 1 : 0) }
    }

    /// The only way down: the collapsed form opens again with one click on it.
    private var collapseButton: some View {
        Button(action: onToggleCollapse) {
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(4)
        .help("Recolher")
        .accessibilityLabel("Recolher")
    }

    // MARK: Collapsed

    /// Stays collapsed under the mouse; one click anywhere on it opens the full form.
    private var collapsedBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !model.sessions.isEmpty {
                HStack(spacing: 10) {
                    ForEach(model.sessions) { session in
                        FaceView(state: session.state, frame: model.eyesFrame, size: 22)
                            .opacity(session.state == .idle ? 0.55 : 1)
                            .overlay(alignment: .bottomTrailing) {
                                if let color = session.workspaceColor {
                                    Circle().fill(Color(nsColor: color)).frame(width: 6, height: 6).offset(x: 2, y: 2)
                                }
                            }
                            .transition(.opacity)
                    }
                }
                .padding(.horizontal, 2)
            }
            UsageFooter(usage: model.usage, problem: model.usageProblem, thin: true)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(width: Self.collapsedWidth, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggleCollapse)
        .help("Abrir")
    }
}

/// A session: face, name with the workspace dot, state line, the pulse and
/// its subagents, all indented under the face.
private struct SessionBlock: View {
    let session: MonitorSession
    let eyesFrame: Int
    let onReveal: (UUID) -> Void

    private static let indent: CGFloat = 31
    private var isAttention: Bool { session.state.order <= MonitorState.finished.order }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .center, spacing: 9) {
                FaceView(state: session.state, frame: eyesFrame, size: 22)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(session.workspaceColor.map { Color(nsColor: $0) } ?? Color.secondary.opacity(0.6))
                            .frame(width: 7, height: 7)
                        Text(session.name)
                            .font(.system(size: 12.5, weight: .medium))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        Text(MonitorModel.stateText(session, now: context.date))
                            .font(Theme.Font.caption)
                            .foregroundStyle(isAttention ? Theme.attention : Color.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 6)
                Text(session.workspaceName ?? "~")
                    .font(Theme.Font.caption)
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
            .onTapGesture { onReveal(session.id) }
            PulseView(bars: session.bars)
                .padding(.leading, Self.indent)
            ForEach(session.subagents) { agent in
                SubagentRow(agent: agent, eyesFrame: eyesFrame)
                    .padding(.leading, Self.indent)
                    .contentShape(Rectangle())
                    .onTapGesture { onReveal(session.id) }
            }
        }
        .padding(.vertical, 3)
    }
}

private struct SubagentRow: View {
    let agent: SubagentInfo
    let eyesFrame: Int

    var body: some View {
        HStack(spacing: 7) {
            FaceView(state: agent.isFinished ? .finished : .working, frame: eyesFrame, size: 14)
            Text(agent.description.isEmpty ? agent.agentType : "\(agent.agentType) · \(agent.description)")
                .font(Theme.Font.caption)
                .foregroundStyle(.primary.opacity(0.8))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 6)
            TimelineView(.periodic(from: .now, by: 30)) { context in
                Text(agent.isFinished ? "pronto" : AgentStatusItem.ago(agent.startedAt, now: context.date).replacingOccurrences(of: "há ", with: ""))
                    .font(Theme.Font.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }
}

/// The Deckmux face at `size`, in the label color (never a template here).
struct FaceView: View {
    let state: MonitorState
    let frame: Int
    let size: CGFloat
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Image(nsImage: AgentFace.image(state.agentStatus, frame: frame, size: size, ink: scheme == .dark ? .white : .black))
            .renderingMode(.original)
            .opacity(0.9)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// 30 bars of 2 pt with 1 pt between: 10 pt when the minute had work, 2 pt
/// idle, orange when the user was needed, faint when there was no sample.
struct PulseView: View {
    let bars: [PulseSample?]

    var body: some View {
        HStack(alignment: .bottom, spacing: 1) {
            ForEach(Array(bars.enumerated()), id: \.offset) { _, bar in
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(color(bar))
                    .frame(width: 2, height: height(bar))
            }
        }
        .frame(height: 10, alignment: .bottom)
        .accessibilityHidden(true)
    }

    private func height(_ bar: PulseSample?) -> CGFloat {
        switch bar {
        case .working?, .waiting?: 10
        default: 2
        }
    }

    private func color(_ bar: PulseSample?) -> Color {
        switch bar {
        case .waiting?: Theme.attention
        case .working?: Color.primary.opacity(0.7)
        case .idle?: Color.primary.opacity(0.3)
        case nil: Color.primary.opacity(0.12)
        }
    }
}

/// "5 h" and "7 d" with their bars; `thin` is the collapsed form (bars only).
struct UsageFooter: View {
    let usage: Usage?
    let problem: String?
    let thin: Bool

    var body: some View {
        if let usage {
            VStack(alignment: .leading, spacing: thin ? 4 : 5) {
                row("5 h", usage.fiveHour)
                row("7 d", usage.sevenDay)
                if !thin, let problem {
                    Text(problem).font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
        } else if !thin {
            Text(problem ?? "Uso indisponível").font(Theme.Font.caption).foregroundStyle(.secondary)
        } else {
            bar(nil).frame(width: 60)
        }
    }

    @ViewBuilder private func row(_ label: String, _ window: UsageWindow?) -> some View {
        if thin {
            bar(window)
        } else {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                HStack(spacing: 9) {
                    Text(label).font(Theme.Font.caption).foregroundStyle(.secondary).monospacedDigit().frame(width: 22, alignment: .leading)
                    bar(window)
                    Text(text(window, now: context.date)).font(Theme.Font.caption).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
                }
            }
        }
    }

    private func text(_ window: UsageWindow?, now: Date) -> String {
        guard let window else { return "—" }
        var parts = ["\(Int(window.percent.rounded()))%"]
        if let resetsAt = window.resetsAt { parts.append(UsageParser.renewalText(resetsAt, now: now)) }
        return parts.joined(separator: " · ")
    }

    private func bar(_ window: UsageWindow?) -> some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.12))
                if let window {
                    Capsule().fill(fill(window.percent))
                        .frame(width: max(thin ? 3 : 4, proxy.size.width * min(1, window.percent / 100)))
                }
            }
        }
        .frame(height: thin ? 3 : 4)
    }

    private func fill(_ percent: Double) -> Color {
        if percent >= 95 { return Theme.now }
        if percent >= 80 { return Theme.attention }
        return Color.primary.opacity(0.45)
    }
}
