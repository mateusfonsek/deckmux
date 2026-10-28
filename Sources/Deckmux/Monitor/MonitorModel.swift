import AppKit
import Combine
import DeckmuxMonitor

/// What a session's Claude is doing, most urgent first.
enum MonitorState: Equatable {
    case needsInput(String?)
    case finished
    case working
    case idle

    var agentStatus: AgentStatus {
        switch self {
        case .needsInput: .needsInput
        case .finished: .finished
        case .working: .working
        case .idle: .idle
        }
    }

    var order: Int {
        switch self {
        case .needsInput: 0
        case .finished: 1
        case .working: 2
        case .idle: 3
        }
    }

    var sample: PulseSample {
        switch self {
        case .needsInput, .finished: .waiting
        case .working: .working
        case .idle: .idle
        }
    }
}

/// One Deckmux terminal running Claude Code, as the Janelinha shows it.
struct MonitorSession: Identifiable, Equatable {
    /// The terminal's ID.
    let id: UUID
    var name: String
    var workspaceName: String?
    var workspaceColor: NSColor?
    var state: MonitorState
    /// The bell's time, or when the current working run began.
    var since: Date?
    /// 30 bars, oldest first.
    var bars: [PulseSample?]
    var subagents: [SubagentInfo]
    var cwd: String?
    var sessionID: String
}

/// The Janelinha's data: the sessions of the deck's terminals, sampled every
/// 10 s for the pulse while enabled, plus the subagents and the account usage
/// that the watcher and the usage client feed in.
@MainActor
final class MonitorModel: ObservableObject {
    @Published private(set) var sessions: [MonitorSession] = []
    @Published private(set) var usage: Usage?
    /// nil, "Uso: faça /login no Claude Code", "Uso indisponível" or "⚠ há 12 min".
    @Published private(set) var usageProblem: String?
    @Published private(set) var eyesFrame = 0
    @Published private(set) var isEnabled = false

    private let deck: Deck
    private var deckObserver: AnyCancellable?
    private var tracks: [UUID: PulseTrack] = [:]
    private var workingSince: [UUID: Date] = [:]
    private var subagents: [UUID: [SubagentInfo]] = [:]
    private var sampler: Timer?
    private var eyes: Timer?
    private var isVisible = false

    init(deck: Deck) {
        self.deck = deck
    }

    /// Starts or stops the 10 s sampler; writes MonitorSettings.enabled.
    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        MonitorSettings.enabled = enabled
        if enabled {
            deckObserver = deck.objectWillChange
                .receive(on: DispatchQueue.main)
                .sink { [weak self] in self?.rebuild(sampling: false) }
            rebuild(sampling: true)
            let timer = Timer.scheduledTimer(withTimeInterval: PulseTrack.sampleInterval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.rebuild(sampling: true) }
            }
            timer.tolerance = 1
            sampler = timer
        } else {
            deckObserver = nil
            sampler?.invalidate()
            sampler = nil
            tracks = [:]
            workingSince = [:]
            subagents = [:]
            sessions = []
        }
        updateEyes()
    }

    /// The eyes timer (0.6 s) runs only while enabled, visible and some session works.
    func setVisible(_ visible: Bool) {
        isVisible = visible
        updateEyes()
    }

    func setSubagents(_ agents: [SubagentInfo], forTerminal id: UUID) {
        guard subagents[id] != agents else { return }
        subagents[id] = agents
        rebuild(sampling: false)
    }

    func setUsage(_ usage: Usage?, problem: String?) {
        self.usage = usage
        usageProblem = problem
    }

    /// Some session waits for the user or finished.
    var hasAttention: Bool {
        sessions.contains { $0.state.order <= MonitorState.finished.order }
    }

    // MARK: Building

    private func rebuild(sampling: Bool) {
        let now = Date()
        var built: [MonitorSession] = []
        var seen: Set<UUID> = []
        for item in deck.items {
            let layout = item.layout
            let workspace = deck.workspace(of: item)
            for (id, session) in layout.claudeSessions {
                seen.insert(id)
                let surface = layout.terminal(withID: id)
                let state: MonitorState
                if let attention = layout.attention[id] {
                    switch attention {
                    case .needsInput(let detail): state = .needsInput(detail)
                    case .finished: state = .finished
                    }
                } else if let surface, TerminalLabel.isWorking(surface) {
                    state = .working
                } else {
                    state = .idle
                }
                if state == .working {
                    if workingSince[id] == nil { workingSince[id] = now }
                } else {
                    workingSince[id] = nil
                }
                if sampling {
                    var track = tracks[id] ?? PulseTrack()
                    track.record(state.sample, at: now)
                    tracks[id] = track
                }
                let since: Date? = layout.attentionSince[id] ?? workingSince[id]
                // Subagents of an idle parent are over, whatever their files say.
                let agents = (subagents[id] ?? []).map { agent -> SubagentInfo in
                    var agent = agent
                    if state == .idle { agent.isFinished = true }
                    return agent
                }
                built.append(MonitorSession(
                    id: id,
                    name: TerminalLabel.plainName(pwd: surface?.pwd, title: surface?.title ?? "", runsClaude: true),
                    workspaceName: workspace?.name,
                    workspaceColor: workspace.flatMap { NSColor(hex: $0.manifest.color) },
                    state: state, since: since,
                    bars: (tracks[id] ?? PulseTrack()).minutes(now: now),
                    subagents: agents, cwd: session.directory ?? surface?.pwd, sessionID: session.sessionID))
            }
        }
        for id in tracks.keys where !seen.contains(id) {
            tracks[id] = nil
            workingSince[id] = nil
            subagents[id] = nil
        }
        let sorted = Self.sorted(built)
        if sorted != sessions { sessions = sorted }
        updateEyes()
    }

    /// Groups in urgency order; inside a group the oldest bell or run first, then by name.
    static func sorted(_ sessions: [MonitorSession]) -> [MonitorSession] {
        sessions.sorted { a, b in
            if a.state.order != b.state.order { return a.state.order < b.state.order }
            switch (a.since, b.since) {
            case let (x?, y?) where x != y: return x < y
            case (nil, .some): return false
            case (.some, nil): return true
            default: return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
        }
    }

    /// "Quer usar Bash · há 2 min", "Precisa de você · há 2 min", "Claude terminou · há 5 min", "Trabalhando · 14 min", "Parado".
    static func stateText(_ session: MonitorSession, now: Date) -> String {
        switch session.state {
        case .needsInput(let detail):
            return "\(detail ?? "Precisa de você") · \(AgentStatusItem.ago(session.since ?? now, now: now))"
        case .finished:
            return "Claude terminou · \(AgentStatusItem.ago(session.since ?? now, now: now))"
        case .working:
            let minutes = Int(now.timeIntervalSince(session.since ?? now) / 60)
            return minutes < 1 ? "Trabalhando" : "Trabalhando · \(minutes < 60 ? "\(minutes) min" : "\(minutes / 60) h \(String(format: "%02d", minutes % 60))")"
        case .idle:
            return "Parado"
        }
    }

    private func updateEyes() {
        let wants = isEnabled && isVisible && sessions.contains { $0.state == .working }
        if wants, eyes == nil {
            let timer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.eyesFrame += 1 }
            }
            timer.tolerance = 0.1
            eyes = timer
        } else if !wants, let eyes {
            eyes.invalidate()
            self.eyes = nil
        }
    }
}
