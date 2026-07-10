// The typed input the fixture parser consumes.
//
// A mode enum, flag bits, a wide-domain checksum, a small-range region selector, and a length-coupled payload. The length coupling is what forces the generator to contain a reified `.bind`, giving the bind-boundary splice operator something real to recombine.

/// The message kind, selecting which parser branch runs.
public enum Mode: UInt8, CaseIterable, Sendable, Equatable, Codable {
    case handshake = 0
    case data = 1
    case control = 2
    case heartbeat = 3
}

/// One parser input.
public struct Message: Sendable, Equatable, Codable {
    /// Selects the parser branch.
    public var mode: Mode
    /// Bit flags; individual bits gate the deep fault chains.
    public var flags: UInt8
    /// A wide-domain field whose only interesting value is the boundary `UInt16.max` — the shallow bug D lands here.
    public var checksum: UInt16
    /// A small-range selector in `0 ... 7`; `region == k` is a clean 1-in-8 gate with a gradient.
    public var region: UInt8
    /// Length-coupled payload. The generator binds the length first, then draws that many bytes.
    public var payload: [UInt8]

    public init(mode: Mode, flags: UInt8, checksum: UInt16, region: UInt8, payload: [UInt8]) {
        self.mode = mode
        self.flags = flags
        self.checksum = checksum
        self.region = region
        self.payload = payload
    }
}
