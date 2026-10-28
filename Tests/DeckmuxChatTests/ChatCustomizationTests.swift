import Foundation
import Testing
@testable import DeckmuxChat

@Test func customNameWinsOverAutomatic() {
    let custom = ChatCustomization(name: "Planilha", tag: nil)
    #expect(Optional(custom).displayName(automatic: "Conversa do Claude") == "Planilha")
    #expect(ChatCustomization?.none.displayName(automatic: "Conversa do Claude") == "Conversa do Claude")
}

@Test func normalizedTrimsAndDropsEmptyParts() {
    let blankName = ChatCustomization(name: "   ", tag: ChatTag(text: " Finança ", icon: .money, color: .orange)).normalized
    #expect(blankName?.name == nil)
    #expect(blankName?.tag == ChatTag(text: "Finança", icon: .money, color: .orange))

    // A tag with neither text nor icon shows nothing: dropped.
    let emptyTag = ChatCustomization(name: "Planilha", tag: ChatTag(text: "  ", icon: nil, color: .blue)).normalized
    #expect(emptyTag == ChatCustomization(name: "Planilha", tag: nil))

    // Nothing left: no customization at all.
    #expect(ChatCustomization(name: "", tag: ChatTag(text: nil, icon: nil, color: .red)).normalized == nil)
}

@Test func tagTextIsCappedSoItStaysSmall() {
    let long = ChatTag(text: "Financeiro da empresa inteira", icon: nil, color: .green).normalized
    // Cut at the limit, then trimmed: no trailing space.
    #expect(long?.text == "Financeiro da")
    #expect((long?.text?.count ?? 0) <= ChatTag.maxTextLength)
}

@Test func roundTripsThroughJSON() throws {
    let custom = ChatCustomization(name: "Planilha", tag: ChatTag(text: "Finança", icon: .money, color: .orange))
    let data = try JSONEncoder().encode(custom)
    #expect(try JSONDecoder().decode(ChatCustomization.self, from: data) == custom)
}

/// A session saved by a newer version (an icon or color this one does not
/// know) must still open: the unknown part is dropped, not the session.
@Test func unknownIconOrColorDoesNotFailDecoding() throws {
    let json = #"{"name":"Planilha","tag":{"text":"Finança","icon":"rocket","color":"teal"}}"#
    let custom = try JSONDecoder().decode(ChatCustomization.self, from: Data(json.utf8))
    #expect(custom.tag == ChatTag(text: "Finança", icon: nil, color: .gray))
}

@Test func nineIconsAndEightColors() {
    #expect(ChatIcon.allCases.count == 9)
    #expect(ChatColor.allCases.count == 8)
    #expect(Set(ChatIcon.allCases.map(\.symbol)).count == 9)
}
