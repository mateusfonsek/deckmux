import Foundation
import Testing
@testable import DeckmuxCaffeine

private let sp = TimeZone(identifier: "America/Sao_Paulo")!

/// Off at 03:12 in São Paulo, on for 3h 12m.
private func summary(_ reason: CaffeineStopReason, peak: Int) -> CaffeineSummary {
    var components = DateComponents()
    (components.year, components.month, components.day, components.hour, components.minute) = (2026, 11, 11, 3, 12)
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = sp
    let off = calendar.date(from: components)!
    return CaffeineSummary(reason: reason, onSince: off - (3 * 3600 + 12 * 60), offAt: off, peakChats: peak)
}

@Test func elapsedFormat() {
    #expect(CaffeineCopy.elapsed(10) == "1m")
    #expect(CaffeineCopy.elapsed(45 * 60) == "45m")
    #expect(CaffeineCopy.elapsed(84 * 60) == "1h 24m")
    #expect(CaffeineCopy.elapsed(3 * 3600) == "3h 0m")
}

@Test func notificationBodies() {
    #expect(CaffeineCopy.notificationBody(summary(.lastChatFinished, peak: 4), timeZone: sp)
        == "Café desligou às 03:12 · ficou ligado 3h 12m com 4 chats · último chat terminou")
    #expect(CaffeineCopy.notificationBody(summary(.nothingStarted, peak: 0), timeZone: sp)
        == "Café desligou às 03:12 · ficou ligado 3h 12m · nenhum chat começou")
    #expect(CaffeineCopy.reason(.lowBattery(19)) == "bateria em 19%")
    #expect(CaffeineCopy.reason(.timeLimit) == "limite de 12 h")
    #expect(CaffeineCopy.reason(.hot) == "Mac quente")
    #expect(CaffeineCopy.chats(1) == "1 chat")
    #expect(CaffeineCopy.chats(3) == "3 chats")
    #expect(CaffeineCopy.refusal(.lowBattery(18)) == "Bateria em 18%: baixa demais para manter acordado")
    #expect(CaffeineCopy.refusal(.hot) == "O Mac está quente demais para manter acordado")
}

@Test func sudoersLine() {
    #expect(SystemCommands.sudoersLine(user: "fonsek")
        == "fonsek ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1")
}

@Test func sudoersRejectsUnsafeUser() {
    for bad in ["", "a b", "x;rm -rf /", "a'b", "a\"b", "$(id)", "a\nb"] {
        #expect(SystemCommands.sudoersLine(user: bad) == nil)
        #expect(SystemCommands.installScript(user: bad) == nil)
    }
}

@Test func installScriptValidatesBeforeInstalling() throws {
    let s = try #require(SystemCommands.installScript(user: "fonsek"))
    let visudo = try #require(s.range(of: "visudo -cf"))
    let move = try #require(s.range(of: "mv "))
    #expect(visudo.lowerBound < move.lowerBound)
    #expect(s.contains("&&"))
    #expect(s.contains("0440"))
    #expect(s.contains("root:wheel"))
    #expect(s.contains("/etc/sudoers.d/deckmux"))
}

@Test func watcherRestoresSleep() {
    #expect(SystemCommands.watcherScript.contains("kill -0 \"$1\""))
    #expect(SystemCommands.watcherScript.contains("sudo -n /usr/bin/pmset -a disablesleep 0"))
    #expect(SystemCommands.watcherScript.contains("trap '' HUP"))
}

@Test func readsSleepDisabledFromPmset() {
    let on = "System-wide power settings:\n SleepDisabled\t\t1\nCurrently in use:\n standby              1\n"
    let off = "System-wide power settings:\n SleepDisabled\t\t0\nCurrently in use:\n sleep                1\n"
    #expect(SystemCommands.sleepDisabled(pmsetOutput: on))
    #expect(!SystemCommands.sleepDisabled(pmsetOutput: off))
    #expect(!SystemCommands.sleepDisabled(pmsetOutput: "Currently in use:\n standby 1\n"))
}
