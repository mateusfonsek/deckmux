import Foundation
import Testing
@testable import DeckmuxCode

struct CodeTabStateTests {
    @Test func roundTrips() throws {
        let state = CodeTabState(root: "/r", file: "a b/ç.swift", view: .files, group: .staged, diffMode: .inline)
        #expect(try JSONDecoder().decode(CodeTabState.self, from: JSONEncoder().encode(state)) == state)
    }

    @Test func decodesMinimal() throws {
        let s = try JSONDecoder().decode(CodeTabState.self, from: Data(#"{"root":"/r","view":"changes","diffMode":"auto"}"#.utf8))
        #expect(s == CodeTabState(root: "/r"))
    }
}
