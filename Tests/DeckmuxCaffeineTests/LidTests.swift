import Testing
@testable import DeckmuxCaffeine

/// iokit_family_msg(sub_iokit_powermanagement, 0x100), from IOPM.h.
private let clamshellChange: UInt32 = 0xE003_4100

@Test func clamshellMessageTellsWhetherTheLidIsClosed() {
    #expect(Lid.isClosed(message: clamshellChange, argument: 0b01) == true)
    #expect(Lid.isClosed(message: clamshellChange, argument: 0b11) == true)
    #expect(Lid.isClosed(message: clamshellChange, argument: 0b00) == false)
    // Only "closing the lid causes sleep" changed: the lid is open.
    #expect(Lid.isClosed(message: clamshellChange, argument: 0b10) == false)
}

@Test func otherPowerMessagesAreNotAboutTheLid() {
    #expect(Lid.isClosed(message: 0xE000_0280, argument: 1) == nil)   // kIOMessageSystemWillSleep
}
