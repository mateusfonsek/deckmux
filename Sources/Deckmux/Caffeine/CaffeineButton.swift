import DeckmuxCaffeine
import SwiftUI

/// The café in the top bar, next to the clock. Off: a cup that turns it on.
/// On: how many chats it keeps awake and for how long; a click opens the details.
struct CaffeineButton: View {
    @ObservedObject var caffeine: CaffeineController
    @State private var hovered = false
    @State private var showsPanel = false

    private var snapshot: CaffeineSnapshot { caffeine.snapshot }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            Button {
                if snapshot.isOn { showsPanel.toggle() } else { caffeine.toggle() }
            } label: {
                label(now: context.date)
            }
            .buttonStyle(.plain)
            .onHover { hovered = $0 }
            .help(snapshot.isOn ? "Mostrar o café" : "Manter o Mac acordado, mesmo com a tampa fechada, até os chats terminarem")
            .popover(isPresented: $showsPanel, arrowEdge: .bottom) {
                CaffeinePanel(caffeine: caffeine) { showsPanel = false }
            }
        }
        .onChange(of: snapshot.isOn) { _, isOn in if !isOn { showsPanel = false } }
    }

    private func label(now: Date) -> some View {
        HStack(spacing: 5) {
            Image(systemName: snapshot.isOn ? "cup.and.saucer.fill" : "cup.and.saucer")
                .font(.system(size: 11, weight: .medium))
            switch snapshot.phase {
            case .off:
                EmptyView()
            case .waiting:
                Text("esperando um chat…")
            case .active(let since, _):
                Text("\(snapshot.chats.count) · \(CaffeineCopy.elapsed(now.timeIntervalSince(since)))").monospacedDigit()
            }
        }
        .font(Theme.Font.secondary)
        .foregroundStyle(snapshot.isOn ? .primary : .secondary)
        .padding(.horizontal, snapshot.isOn ? 9 : 6)
        .frame(height: 24)
        .background(Capsule().fill(Color.primary.opacity(snapshot.isOn ? (hovered ? 0.12 : 0.08) : (hovered ? 0.08 : 0))))
        .contentShape(Capsule())
    }
}

/// What the café is doing: since when, which chats, when it stops at the latest.
struct CaffeinePanel: View {
    @ObservedObject var caffeine: CaffeineController
    let close: () -> Void

    private var snapshot: CaffeineSnapshot { caffeine.snapshot }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Label("Mantendo o Mac acordado", systemImage: "cup.and.saucer.fill")
                        .font(Theme.Font.title)
                    if let since = snapshot.onSince {
                        Text("Ligado há \(CaffeineCopy.elapsed(context.date.timeIntervalSince(since))) (desde \(CaffeineCopy.clock(since)))")
                            .font(Theme.Font.secondary)
                            .foregroundStyle(.secondary)
                    }
                }
                chats(now: context.date)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Desliga quando o último terminar.")
                    if let limit = limitLine { Text(limit) }
                }
                .font(Theme.Font.caption)
                .foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("Desligar") {
                        close()
                        caffeine.turnOff()
                    }
                }
            }
            .padding(14)
            .frame(width: 270)
        }
    }

    @ViewBuilder private func chats(now: Date) -> some View {
        if case .waiting(let since) = snapshot.phase {
            let left = max(0, Int(Caffeine.startWait - now.timeIntervalSince(since)))
            Text("Esperando um chat começar · desliga em \(left / 60):\(String(format: "%02d", left % 60))")
                .font(Theme.Font.body)
                .monospacedDigit()
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(snapshot.chats) { chat in
                    HStack(spacing: 8) {
                        Circle().fill(chat.color ?? .secondary).frame(width: 7, height: 7)
                        Text(chat.name).font(Theme.Font.body).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 8)
                        Text(Self.work(chat.work)).font(Theme.Font.secondary).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var limitLine: String? {
        guard let deadline = snapshot.deadline else { return nil }
        var line = "No máximo até \(CaffeineCopy.clock(deadline))"
        if snapshot.power.onBattery, let percent = snapshot.power.percent { line += " · bateria \(percent)%" }
        return line
    }

    static func work(_ work: ChatWork) -> String {
        switch work {
        case .idle: ""
        case .working: "trabalhando"
        case .subagents(let n): n == 1 ? "1 sub-agente" : "\(n) sub-agentes"
        }
    }
}
