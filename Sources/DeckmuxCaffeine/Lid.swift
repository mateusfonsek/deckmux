/// The lid, as IOPMrootDomain reports it to general-interest listeners.
public enum Lid {
    /// kIOPMMessageClamshellStateChange: iokit_family_msg(sub_iokit_powermanagement, 0x100).
    public static let clamshellStateChange: UInt32 = 0xE003_4100
    /// kClamshellStateBit: set while the lid is closed.
    static let closedBit: UInt = 1 << 0

    /// Whether the lid is closed, for a clamshell message; nil for any other message.
    public static func isClosed(message: UInt32, argument: UInt) -> Bool? {
        guard message == clamshellStateChange else { return nil }
        return argument & closedBit != 0
    }
}
