// A child process that fuzzes a trapping spec until it dies, so the parent test can
// inspect the breadcrumb and progress log the dead process left behind.
//
// The parent sets `EXHAUST_STATE_DIR` to a directory it controls so the runtime's state
// lands where the parent can find it.

import SpecFixture
import Exhaust
import Foundation

@StateMachine
final class TrapSpec {
    var expected: Int = 0
    @SystemUnderTest var counter: TrappingCounter = .init()

    @Command
    func increment() throws {
        expected += 1
        counter.increment()
    }

    @Invariant
    func matches() -> Bool {
        counter.value == expected
    }

    func failureDescription() -> String? {
        "\(counter)"
    }
}

// The trap fires at value 3, which is three increment commands. A generous budget the probe
// never spends: the trap fires within milliseconds.
_ = await #explore(TrapSpec.self, mode: .sequential, time: .seconds(120))

// Only reachable if the trap never fired.
FileHandle.standardError.write(Data("SpecTrapProbe completed without trapping\n".utf8))
Foundation.exit(1)
