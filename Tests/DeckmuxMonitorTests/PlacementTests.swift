import CoreGraphics
import Foundation
import Testing
@testable import DeckmuxMonitor

// The MacBook screen: full frame and the visible part (menu bar and Dock out).
private let main = (frame: CGRect(x: 0, y: 0, width: 1470, height: 956), visible: CGRect(x: 0, y: 80, width: 1470, height: 841))
private let size = CGSize(width: 300, height: 200)

@Test func noSavedCornerUsesTheMainCorner() {
    let frame = PanelPlacement.frame(size: size, savedCorner: nil, screens: [main])
    #expect(frame.maxX == 1470 - 16 && frame.minY == 80 + 16 && frame.size == size)
}

@Test func savedCornerOnTheRightEdgeIsKept() {
    let frame = PanelPlacement.frame(size: size, savedCorner: CGPoint(x: 1470, y: 300), screens: [main])
    #expect(frame.maxX == 1470 && frame.minY == 300)
}

@Test func cornerUnderTheDockIsClampedNotReset() {
    let frame = PanelPlacement.frame(size: size, savedCorner: CGPoint(x: 1000, y: 70), screens: [main])
    #expect(frame.maxX == 1000 && frame.minY == 80)
}

@Test func farAwayCornerFallsBackToTheMainCorner() {
    let frame = PanelPlacement.frame(size: size, savedCorner: CGPoint(x: 99_999, y: 99_999), screens: [main])
    #expect(frame.maxX == 1470 - 16 && frame.minY == 80 + 16)
}

@Test func cornerOnASecondScreenStaysThere() {
    let second = (frame: CGRect(x: 1470, y: 100, width: 1920, height: 1080), visible: CGRect(x: 1470, y: 100, width: 1920, height: 1055))
    let frame = PanelPlacement.frame(size: size, savedCorner: CGPoint(x: 3000, y: 500), screens: [main, second])
    #expect(frame.maxX == 3000 && frame.minY == 500)
    #expect(PanelPlacement.screenIndex(savedCorner: CGPoint(x: 3000, y: 500), screens: [main, second]) == 1)
}
