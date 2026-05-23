import ExhaustTestSupport
import Foundation
import Testing
@testable import Exhaust

@Suite("Preemptive concurrent contract: ObjC exception handling", .serialized, .tags(.contract))
struct PreemptiveObjCExceptionTests {
    @Test
    func `Catches NSException from concurrent command without crashing`() async throws {
        let result = try #require(
            await __ExhaustRuntime.dispatchToGCD {
                __runPreemptiveConcurrentContract(
                    ThrowingObjCSpec.self,
                    settings: [
                        .concurrency(2),
                        .commandLimit(4),
                        .budget(.custom(coverage: 0, sampling: 50)),
                        .suppress(.issueReporting),
                    ]
                )
            }
        )
        #expect(result.commands.isEmpty == false, "Should find a failure from the NSException")
    }
}

// MARK: - Spec

@ConcurrentContract
final class ThrowingObjCSpec {
    @SystemUnderTest
    var store: ObjCThrowingStore = .init()

    @Oracle
    func statesMatch(other: ObjCThrowingStore) -> Bool {
        store.value == other.value
    }

    @Command(weight: 3)
    func increment() throws {
        store.increment()
    }

    @Command(weight: 1)
    func triggerException() throws {
        store.triggerObjCException()
    }
}

// MARK: - SUT

final class ObjCThrowingStore: @unchecked Sendable, CustomDebugStringConvertible {
    private var _value: Int = 0

    var value: Int {
        _value
    }

    var debugDescription: String {
        "ObjCThrowingStore(value: \(_value))"
    }

    func increment() {
        _value += 1
    }

    func triggerObjCException() {
        let array = NSArray()
        _ = array.object(at: 42)
    }
}
