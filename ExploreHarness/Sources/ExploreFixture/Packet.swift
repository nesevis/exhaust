// The typed input the deep benchmark parser consumes.
//
// A small-range channel selector, flag bits, a small-range window, a command list drawn from a
// oneOf (the future swarm target), and a length-coupled body. The body's length coupling forces a
// reified `.bind`, matching the shape of `Message` so the mutation operators face the same
// structural substrate on both fixtures.

/// One stack command in a ``Packet``. Generated through a `.oneOf` over the four cases so the branch structure exists for per-branch reweighting (swarm generation) to act on later.
public enum Command: UInt8, CaseIterable, Sendable, Equatable, Codable {
    /// Deepens the stack by one.
    case push = 0
    /// Shallows the stack by one, never below zero.
    case pop = 1
    /// Leaves the stack unchanged.
    case mark = 2
    /// Resets the stack to empty.
    case clear = 3
}

/// One deep-parser input.
public struct Packet: Sendable, Equatable, Codable {
    /// A small-range selector in `0 ... 7`; `channel == k` is a clean 1-in-8 gate with a gradient.
    public var channel: UInt8
    /// Bit flags; individual bits gate the deep fault chains.
    public var flags: UInt8
    /// A second small-range selector in `0 ... 7`, gating one stage deeper than `channel`.
    public var window: UInt8
    /// The command list the stack simulator runs; the swarm-suppressed fault R lives here.
    public var commands: [Command]
    /// Length-coupled body. The generator binds the length first, then draws that many bytes.
    public var body: [UInt8]

    public init(channel: UInt8, flags: UInt8, window: UInt8, commands: [Command], body: [UInt8]) {
        self.channel = channel
        self.flags = flags
        self.window = window
        self.commands = commands
        self.body = body
    }
}
