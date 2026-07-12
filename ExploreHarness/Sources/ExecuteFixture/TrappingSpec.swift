// A spec whose SUT traps on a specific command sequence, for the crash-recovery probe.

import Exhaust

public struct TrappingCounter: Sendable {
    public var value: Int = 0
    public init() {}

    public mutating func increment() {
        value += 1
        if value == 3 {
            fatalError("planted trap at value 3")
        }
    }
}
