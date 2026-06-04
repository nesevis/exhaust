import ExhaustTestSupport
import Testing
@testable import Exhaust

// MARK: - Tests

/// Out-of-range `concurrencyLevel` must be rejected with a reported issue (surfaced through Swift Testing and XCTest via IssueReporting), not a `UInt8` trap or a silent zero-lane degrade. `withKnownIssue` fails if no issue is recorded, so it is the regression signal.
@Suite("Concurrency level validation", .serialized, .tags(.contract))
struct ConcurrencyLevelValidationTests {
    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test("Cooperative runner reports an issue and aborts above the maximum concurrencyLevel")
    func cooperativeRejectsConcurrencyLevelAboveMaximum() async {
        await withKnownIssue {
            let result = await __ExhaustRuntime.__runContractConcurrent(
                ConcurrencyValidationSpec.self,
                settings: [.concurrent(9), .budget(.custom(coverage: 0, sampling: 1))]
            )
            #expect(result == nil)
        }
    }

    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test("Async preemptive runner reports an issue and aborts on a zero concurrencyLevel")
    func asyncPreemptiveRejectsZeroConcurrencyLevel() async {
        await withKnownIssue {
            let result = await __ExhaustRuntime.__runPreemptiveConcurrentContractAsync(
                ConcurrencyValidationConcurrentSpec.self,
                settings: [.concurrent(0), .budget(.custom(coverage: 0, sampling: 1))]
            )
            #expect(result == nil)
        }
    }
}

// MARK: - Specs

@Contract(.tasks)
final class ConcurrencyValidationSpec {
    @SystemUnderTest
    var counter: ValidationCounter = .init()

    @Command(weight: 1)
    func bump() async throws {
        await counter.bump()
    }
}

@Contract(.threads)
final class ConcurrencyValidationConcurrentSpec {
    @SystemUnderTest
    var counter: ValidationCounter = .init()

    @Oracle
    func valuesMatch(other _: ValidationCounter) -> Bool {
        true
    }

    @Command(weight: 1)
    func bump() async throws {
        await counter.bump()
    }
}

// MARK: - SUT

final class ValidationCounter: @unchecked Sendable {
    private var value: Int = 0

    func bump() async {
        value += 1
    }
}
