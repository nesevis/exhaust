// The message generator and the ground-truth minimal reproducers the harness asserts against.

import Exhaust

/// The generator and hand-computed reproducers for the planted faults.
public enum Fixture {
    /// A generator over ``Message`` whose length-coupled payload forces a reified `.bind`.
    ///
    /// The length is bound first, then the rest of the message is drawn with that many payload bytes, so the flattened choice sequence carries the `.bind` markers the bind-boundary splice recombines. Region is drawn in `0 ... 7` so `region == k` is a clean 1-in-8 gate with a gradient; the checksum spans its full domain so only a boundary draw reaches `UInt16.max` (fault D).
    public static var messageGenerator: ReflectiveGenerator<Message> {
        #gen(.int(in: 0 ... 6)).bind { length in
            #gen(
                .element(from: Mode.allCases),
                .uint8(),
                .uint16(),
                .int(in: 0 ... 7),
                .uint8().array(length: length ... length)
            ) { mode, flags, checksum, region, payload in
                Message(
                    mode: mode,
                    flags: flags,
                    checksum: checksum,
                    region: UInt8(region),
                    payload: payload
                )
            }
        }
    }

    // MARK: - Minimal Reproducers

    // Each is the shortlex-minimal input that still triggers its fault: every field reduced to its simplest value that keeps the failure. These are the exact values the reducer must converge on, so the end-to-end test compares cluster reduced forms against them.

    /// Fault A's minimal form: data mode, low two flag bits set, region 5, a two-byte payload with a small first byte.
    public static let reproducerA = Message(
        mode: .data,
        flags: 0b0000_0011,
        checksum: 0,
        region: 5,
        payload: [0, 0]
    )

    /// Fault B's minimal form: control mode, the next two flag bits set, region 2, a one-byte payload with a large first byte.
    public static let reproducerB = Message(
        mode: .control,
        flags: 0b0000_1100,
        checksum: 0,
        region: 2,
        payload: [241]
    )

    /// Fault C's minimal form: heartbeat mode, region 6, flags reduced away because the unconditional window check still throws.
    public static let reproducerC = Message(
        mode: .heartbeat,
        flags: 0,
        checksum: 0,
        region: 6,
        payload: []
    )

    /// Fault D's minimal form: the boundary checksum with every other field at its simplest.
    public static let reproducerD = Message(
        mode: .handshake,
        flags: 0,
        checksum: .max,
        region: 0,
        payload: []
    )
}
