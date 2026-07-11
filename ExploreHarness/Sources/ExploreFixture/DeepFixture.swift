// The packet generator and the ground-truth minimal reproducers for the deep benchmark parser.

import Exhaust

/// The generator and hand-computed reproducers for ``DeepParser``'s planted faults.
public enum DeepFixture {
    /// A generator over ``Packet`` whose length-coupled body forces a reified `.bind` and whose command list is drawn through a `.oneOf`.
    ///
    /// The body length is bound first, mirroring ``Fixture/messageGenerator`` so both fixtures exercise the same structural machinery (bind-boundary splice, length-coupled deletion). Commands go through `.oneOf` over the four cases rather than `.element(from:)` so each command kind is a generator branch — the seam swarm generation will reweight.
    public static var packetGenerator: ReflectiveGenerator<Packet> {
        #gen(.int(in: 0 ... 6)).bind { length in
            #gen(
                .int(in: 0 ... 7),
                .uint8(),
                .int(in: 0 ... 7),
                commandGenerator.array(length: 0 ... 16),
                .uint8().array(length: length ... length)
            ) { channel, flags, window, commands, body in
                Packet(
                    channel: UInt8(channel),
                    flags: flags,
                    window: UInt8(window),
                    commands: commands,
                    body: body
                )
            }
        }
    }

    /// One command, drawn through a `.oneOf` so each case is its own generator branch.
    public static var commandGenerator: ReflectiveGenerator<Command> {
        .oneOf(.just(.push), .just(.pop), .just(.mark), .just(.clear))
    }

    // MARK: - Minimal Reproducers

    // Each is the shortlex-minimal input that still triggers its fault: every field reduced to the simplest value that keeps the failure. The per-stage pass probabilities live in DeepParser.swift's ground-truth registry.

    /// Fault P's minimal form: channel 3, flag bits 0, 1, and 5, window 5, a three-byte body of `[0, 252, 5]`.
    public static let reproducerP = Packet(
        channel: 3,
        flags: 0b0010_0011,
        window: 5,
        commands: [],
        body: [0, 252, 5]
    )

    /// Fault Q's minimal form: channel 6, flag bits 2, 3, and 6, window 2, a three-byte body of `[252, 0, 3]`.
    public static let reproducerQ = Packet(
        channel: 6,
        flags: 0b0100_1100,
        window: 2,
        commands: [],
        body: [252, 0, 3]
    )

    /// Fault R's minimal form: 12 consecutive pushes with every other field at its simplest.
    public static let reproducerR = Packet(
        channel: 0,
        flags: 0,
        window: 0,
        commands: Array(repeating: .push, count: 12),
        body: []
    )
}
