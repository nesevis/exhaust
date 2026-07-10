// The deliberately buggy fixture parser, with ground-truth planted faults.
//
// Every fault except D sits behind a chain of narrow-condition gates, each on its own branch so each passed stage lights a fresh SUT edge and gives sprawl a platform for the next stage. No gate is a wide equality over a full domain (except D, which is a boundary value screening enumerates directly): inline-8bit counters carry no comparison-operand gradient, so a wide equality would be findable only by luck and would test nothing.

// Distinct error *types*, not cases of one enum. The reduction gate's backpressure caps dispatches per symptom, and a symptom is the thrown error's type name — so distinct types give each fault its own reduction budget. The slippage pair A and B deliberately share one type (`IntegrityError`): that shared symptom is exactly what a symptom-deduplicating tool collapses and what the clustered inventory must separate by reduced form.

/// The shallow fault D: the boundary checksum value.
public struct ChecksumError: Error, Equatable, Sendable {
    public init() {}
}

/// The slippage pair A and B, and nothing else. Two unrelated root causes throwing one type from one shared site.
public struct IntegrityError: Error, Equatable, Sendable {
    public init() {}
}

/// The over-split control C, reachable through more than one branch but one root cause.
public struct WindowError: Error, Equatable, Sendable {
    public init() {}
}

/// A parsed message. The fixture never uses the contents; decoding either succeeds or surfaces a planted fault.
public struct Decoded: Sendable, Equatable {
    public let mode: Mode
    public let byteCount: Int
}

/// The fixture parser.
public enum Parser {
    /// Decodes a message, surfacing the catchable planted faults A, B, C, and D. Contains no trap, so the main soak can run it safely.
    ///
    /// - Throws: ``ChecksumError`` (fault D), ``IntegrityError`` (the slippage pair A and B), or ``WindowError`` (fault C).
    public static func decode(_ message: Message) throws -> Decoded {
        try checkChecksum(message)
        switch message.mode {
            case .handshake:
                return decodeHandshake(message)
            case .data:
                return try decodeData(message)
            case .control:
                return try decodeControl(message)
            case .heartbeat:
                return try decodeHeartbeat(message)
        }
    }

    /// Decodes a message including the fatal trap E. Called only by the trap probe: the trap kills the process, so the in-suite soak must not reach it.
    public static func decodeUnsafe(_ message: Message) throws -> Decoded {
        checkTrap(message)
        return try decode(message)
    }

    // MARK: - Shallow Fault (D)

    /// A wide equality, but on the UInt16 boundary value the covering array enumerates directly. Screening finds it before sprawl; blind sampling never would. This is the one gate that is meant to have no gradient.
    private static func checkChecksum(_ message: Message) throws {
        if message.checksum == UInt16.max {
            throw ChecksumError()
        }
    }

    // MARK: - Handshake Branch (no planted fault)

    private static func decodeHandshake(_ message: Message) -> Decoded {
        Decoded(mode: .handshake, byteCount: message.payload.count)
    }

    // MARK: - Data Branch (fault A)

    /// Fault A: mode data, low two flag bits set, region 5, a short payload whose first byte is small. Six stages, each roughly 1-in-2 to 1-in-16, each on its own branch. Minimal reproducer computed in `Fixture.reproducerA`.
    private static func decodeData(_ message: Message) throws -> Decoded {
        if message.flags & 0b0000_0001 != 0 {
            if message.flags & 0b0000_0010 != 0 {
                if message.region == 5 {
                    if message.payload.count >= 2 {
                        if message.payload[0] < 16 {
                            try integrityCheck(mode: .data)
                        }
                    }
                }
            }
        }
        return Decoded(mode: .data, byteCount: message.payload.count)
    }

    // MARK: - Control Branch (fault B)

    /// Fault B: mode control, high two of the low-nibble flag bits set, region 2, a payload whose first byte is large. Disjoint from A in mode, region, and value direction, so neither minimal form contains the other and the reducer cannot walk one into the other. Minimal reproducer in `Fixture.reproducerB`.
    private static func decodeControl(_ message: Message) throws -> Decoded {
        if message.flags & 0b0000_0100 != 0 {
            if message.flags & 0b0000_1000 != 0 {
                if message.region == 2 {
                    if message.payload.count >= 1 {
                        if message.payload[0] > 240 {
                            try integrityCheck(mode: .control)
                        }
                    }
                }
            }
        }
        return Decoded(mode: .control, byteCount: message.payload.count)
    }

    // MARK: - Heartbeat Branch (fault C)

    /// Fault C: one root cause — region 6 — reached through an unconditional call plus two flag-gated redundant calls. The redundant paths give failing inputs different coverage signatures (the "likely same" tier), but every failure reduces to the same minimal form because the unconditional call still throws once flags reduce to zero. Minimal reproducer in `Fixture.reproducerC`.
    private static func decodeHeartbeat(_ message: Message) throws -> Decoded {
        try validateWindow(message.region)
        if message.flags & 0b0000_0001 != 0 {
            try validateWindow(message.region)
        }
        if message.flags & 0b0000_0010 != 0 {
            try validateWindow(message.region)
        }
        return Decoded(mode: .heartbeat, byteCount: message.payload.count)
    }

    // MARK: - Shared Fault Sites

    /// The shared throw site for A and B. Both branches funnel here, so the surface symptom is identical and symptom-deduplicating tools collapse them; only the distinct reduced forms separate them.
    private static func integrityCheck(mode _: Mode) throws {
        throw IntegrityError()
    }

    /// The single root cause behind C's several call sites.
    private static func validateWindow(_ region: UInt8) throws {
        if region == 6 {
            throw WindowError()
        }
    }

    // MARK: - Fatal Fault (E)

    /// Fault E: a trap behind control mode, a flag bit, region 7, and a non-empty payload — roughly 1-in-75 by blind sampling. Only `decodeUnsafe` reaches it, so it never threatens the main soak (which runs `decode`); the probe traps within milliseconds, which is what the crash-recovery test needs. Its shallowness measures nothing about search quality — that is the deep A and B chains' job.
    private static func checkTrap(_ message: Message) {
        if message.mode == .control {
            if message.flags & 0b0001_0000 != 0 {
                if message.region == 7 {
                    if message.payload.isEmpty == false {
                        fatalError("planted trap E: control/region-7/non-empty payload")
                    }
                }
            }
        }
    }
}
