import Foundation
import Testing
@testable import DeckmuxCode

@Test func classifies() {
    #expect(FileContent.classify(Data("oi\n".utf8), name: "a.md") == .text("oi\n"))
    #expect(FileContent.classify(Data([0x00, 0x01, 0x02]), name: "a.bin") == .binary(size: 3))
    #expect(FileContent.classify(Data([0x89, 0x50]), name: "logo.PNG") == .image(Data([0x89, 0x50])))
    #expect(FileContent.classify(Data(count: CodeLimits.maxBytes + 1), name: "big.txt") == .tooLarge(size: CodeLimits.maxBytes + 1))
    #expect(FileContent.load(URL(fileURLWithPath: "/nonexistent/x")) == .missing)
}

@Test func invalidUTF8IsBinary() {
    #expect(FileContent.classify(Data([0xff, 0xfe, 0x41]), name: "a.txt") == .binary(size: 3))
}
