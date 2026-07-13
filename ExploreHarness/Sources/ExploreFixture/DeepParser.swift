// The deep benchmark parser, with ground-truth planted faults.
//
// The assertion fixture (`Parser`) saturates in under a second, so it can gate regressions but
// cannot demonstrate search-power improvements. This parser exists for that second job: its two
// deep chains are tuned so a coverage-guided run climbs them inside a 10-second budget while blind
// sampling at the matched attempt count has well under one expected hit. Every stage is a narrow
// condition on its own branch (a fresh SUT edge per passed stage); the only masked equalities sit
// on byte low-bits, where the boundary catalogue cannot enumerate them but a mutation draw can.
//
// Shape coordinates (matrix registry, MX3a). Trigger class: staged gate chains (P, Q) and wide alignment (R, swarm-suppressed). Coverage surface: laddered for P and Q (one edge per passed stage), flat for R (no intermediate edges). Vocabulary: one packet generator with a reified `.bind` and a 4-ary command `.oneOf`. Argument domains: bytes and small ints. Length scale: scalar fields plus a 3-byte body (P, Q); a run of 12 pushes in 0...16 commands (R).
//
// Ground-truth registry. Per-stage pass probabilities under the uniform generator mix
// (`DeepFixture.packetGenerator`: channel and window uniform in 0...7, flags uniform over UInt8,
// body length uniform in 0...6, body bytes uniform over UInt8, commands uniform over the four
// cases with length 0...16):
//
//   Fault P (AlignmentError, data-style chain, 8 stages):
//     channel == 3            1/8
//     flags bit 0             1/2
//     flags bit 1             1/2
//     flags bit 5             1/2
//     window == 5             1/8
//     body.count >= 3         4/7
//     body[0] < 4             1/64
//     body[1] > 251           1/64
//     body[2] & 7 == 5        1/8
//     joint ≈ 3.4e-8 per blind attempt (~0.014 expected hits in 400k attempts).
//
//   Fault Q (AlignmentError, disjoint chain, 9 stages, structurally mirroring P so the pair's
//   discovery odds stay comparable):
//     channel == 6            1/8
//     flags bit 2             1/2
//     flags bit 3             1/2
//     flags bit 6             1/2
//     window == 2             1/8
//     body.count >= 3         4/7
//     body[0] > 251           1/64
//     body[1] < 4             1/64
//     body[2] & 7 == 3        1/8
//     joint ≈ 3.4e-8 per blind attempt (~0.014 expected hits in 400k attempts).
//
//   Fault R (OverflowError, swarm-suppressed): the running stack depth reaches 12, requiring at
//   least 12 pushes among at most 16 commands with no interleaved clear — joint on the order of
//   1e-8 under the uniform mix, but near-certain once a swarm mask suppresses pop and clear.
//   No intermediate stage lights an edge, so coverage guidance gets no ladder; this fault is the
//   measurement target for swarm generation (W3), not for the search-power gates.
//
// P and Q throw one shared error type from one shared site — the slippage pair at depth. Blind
// symptom deduplication collapses them; the clustered inventory must separate them by reduced form.
//
// Pinned baselines (MX2e re-measure, 2026-07-12, seeds 1-20, 10 s, defaults): P 20/20, Q 20/20, R 0/20 (the earlier 2/20 pin predates the phase-2 default flips; R stays the swarm differential either way).

/// The deep slippage pair P and Q: two unrelated eight-stage chains throwing one type from one shared site.
public struct AlignmentError: Error, Equatable, Sendable {
    public init() {}
}

/// The swarm-suppressed fault R: stack depth reaching 12.
public struct OverflowError: Error, Equatable, Sendable {
    public init() {}
}

/// A parsed packet. The fixture never uses the contents; decoding either succeeds or surfaces a planted fault.
public struct DecodedPacket: Sendable, Equatable {
    public let channel: UInt8
    public let byteCount: Int
}

/// The deep benchmark parser. See the file header for the ground-truth fault registry.
public enum DeepParser {
    /// Decodes a packet, surfacing the planted faults P, Q (deep chains), and R (swarm target).
    ///
    /// - Throws: ``AlignmentError`` (the deep slippage pair P and Q) or ``OverflowError`` (fault R).
    public static func decode(_ packet: Packet) throws -> DecodedPacket {
        try runCommands(packet.commands)
        try checkDataChain(packet)
        try checkControlChain(packet)
        return DecodedPacket(channel: packet.channel, byteCount: packet.body.count)
    }

    // MARK: - Fault P

    /// Fault P's chain: each stage is a narrow condition on its own branch. Minimal reproducer in ``DeepFixture/reproducerP``.
    private static func checkDataChain(_ packet: Packet) throws {
        if packet.channel == 3 {
            if packet.flags & 0b0000_0001 != 0 {
                if packet.flags & 0b0000_0010 != 0 {
                    if packet.flags & 0b0010_0000 != 0 {
                        if packet.window == 5 {
                            if packet.body.count >= 3 {
                                if packet.body[0] < 4 {
                                    if packet.body[1] > 251 {
                                        if packet.body[2] & 0b0000_0111 == 5 {
                                            try alignmentCheck()
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Fault Q

    /// Fault Q's chain: disjoint from P in channel, flag bits, window, and value direction, so neither minimal form contains the other. Minimal reproducer in ``DeepFixture/reproducerQ``.
    private static func checkControlChain(_ packet: Packet) throws {
        if packet.channel == 6 {
            if packet.flags & 0b0000_0100 != 0 {
                if packet.flags & 0b0000_1000 != 0 {
                    if packet.flags & 0b0100_0000 != 0 {
                        if packet.window == 2 {
                            if packet.body.count >= 3 {
                                if packet.body[0] > 251 {
                                    if packet.body[1] < 4 {
                                        if packet.body[2] & 0b0000_0111 == 3 {
                                            try alignmentCheck()
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Fault R

    /// Fault R: the stack simulator. The depth check deliberately lights no intermediate edges — partial depth gives coverage guidance nothing to climb, so only a command-mix shift (swarm) or luck reaches 12. Minimal reproducer in ``DeepFixture/reproducerR``.
    private static func runCommands(_ commands: [Command]) throws {
        var depth = 0
        for command in commands {
            switch command {
                case .push:
                    depth += 1
                case .pop:
                    depth = max(0, depth - 1)
                case .mark:
                    break
                case .clear:
                    depth = 0
            }
            if depth >= 12 {
                throw OverflowError()
            }
        }
    }

    // MARK: - Shared Fault Site

    /// The shared throw site for P and Q. Both chains funnel here, so the surface symptom is identical and only the distinct reduced forms separate them.
    private static func alignmentCheck() throws {
        throw AlignmentError()
    }
}
