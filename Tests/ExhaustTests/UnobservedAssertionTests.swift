import ExhaustCore
import Foundation
import Testing
import XCTest
@testable import Exhaust

@Suite("Assertions the detection rewrite cannot see")
struct UnobservedAssertionTests {
    @Test("Assertion in a stored closure fails the run instead of passing silently")
    func storedClosureAssertionFailsTheRun() {
        var failure: String?
        withKnownIssue {
            #exhaust(
                #gen(.int(in: 0 ... 100)),
                .budget(.quick),
                .onReport { report in
                    failure = report.unobservedAssertionFailure
                }
            ) { (value: Int) in
                #expect(value >= 0)
                alwaysFailingCheck(value)
            }
        }
        #expect(failure != nil)
    }

    @Test("Assertion in a called function fails the run")
    func helperFunctionAssertionFailsTheRun() {
        var failure: String?
        withKnownIssue {
            #exhaust(
                #gen(.int(in: 0 ... 100)),
                .budget(.quick),
                .onReport { report in
                    failure = report.unobservedAssertionFailure
                }
            ) { (value: Int) in
                #expect(value >= 0)
                failingHelper(value)
            }
        }
        #expect(failure != nil)
    }

    @Test("Assertion in a nested closure fails the run")
    func nestedClosureAssertionFailsTheRun() {
        var failure: String?
        withKnownIssue {
            #exhaust(
                #gen(.int(in: 0 ... 100).array(length: 1 ... 3)),
                .budget(.quick),
                .onReport { report in
                    failure = report.unobservedAssertionFailure
                }
            ) { (values: [Int]) in
                #expect(values.isEmpty == false)
                // The closure is the point: a for-in loop would put this assertion in the property
                // closure's own body, where the macro rewrites it and the run finds a counterexample.
                // swiftformat:disable:next preferForLoop
                values.forEach { element in
                    #expect(element > 1000)
                }
            }
        }
        #expect(failure != nil)
    }

    @Test("Assertion inside a parallel sampling lane fails the run")
    func parallelLaneAssertionFailsTheRun() {
        var failure: String?
        withKnownIssue {
            #exhaust(
                #gen(.int(in: 0 ... 100)),
                // Zero screening puts every invocation in the sampling phase, which
                // dispatches to worker threads at this lane count.
                .budget(.custom(screening: 0, sampling: 200)),
                .parallelize(lanes: .four),
                .onReport { report in
                    failure = report.unobservedAssertionFailure
                }
            ) { (value: Int) in
                #expect(value >= 0)
                alwaysFailingCheck(value)
            }
        }
        #expect(failure != nil)
    }

    @Test("Assertion in an async property fails the run")
    func asyncPropertyAssertionFailsTheRun() async {
        var failure: String?
        await withKnownIssue {
            await #exhaust(
                #gen(.int(in: 0 ... 100)),
                .budget(.quick),
                .onReport { report in
                    failure = report.unobservedAssertionFailure
                }
            ) { (value: Int) in
                #expect(value >= 0)
                await failingAsyncHelper(value)
            }
        }
        #expect(failure != nil)
    }

    @Test("Invocation that asserts and then skips still fails the run")
    func assertionFollowedBySkipFailsTheRun() {
        var failure: String?
        var skipped = -1
        var invocations = -1
        withKnownIssue {
            #exhaust(
                #gen(.int(in: 0 ... 100)),
                .budget(.quick),
                .onReport { report in
                    failure = report.unobservedAssertionFailure
                    skipped = report.skippedInvocations
                    invocations = report.propertyInvocations
                }
            ) { (value: Int) in
                #expect(value >= 0)
                if value < 50 {
                    alwaysFailingCheck(value)
                    throw PropertySkip()
                }
            }
        }
        #expect(failure != nil)
        #expect(skipped > 0)
        #expect(skipped < invocations)
    }

    @Test("Property absorbing its own issue does not fail the run")
    func ownKnownIssueScopeDoesNotFailTheRun() {
        var failure: String?
        let result = #exhaust(
            #gen(.int(in: 0 ... 100)),
            .budget(.quick),
            .onReport { report in
                failure = report.unobservedAssertionFailure
            }
        ) { (value: Int) in
            #expect(value >= 0)
            withKnownIssue {
                alwaysFailingCheck(value)
            }
        }
        #expect(result == nil)
        #expect(failure == nil)
    }

    @Test("Passing run reports no unobserved assertion")
    func passingRunReportsNothing() {
        var failure: String?
        let result = #exhaust(
            #gen(.int(in: 0 ... 100)),
            .budget(.quick),
            .onReport { report in
                failure = report.unobservedAssertionFailure
            }
        ) { (value: Int) in
            #expect(value >= 0)
        }
        #expect(result == nil)
        #expect(failure == nil)
    }

    @Test("Run that finds a counterexample reports no unobserved assertion")
    func counterexampleRunReportsNothing() {
        var failure: String?
        var counterexample: Int?
        withKnownIssue {
            counterexample = #exhaust(
                #gen(.int(in: 0 ... 100)),
                .budget(.quick),
                .onReport { report in
                    failure = report.unobservedAssertionFailure
                }
            ) { (value: Int) in
                #expect(value < 50)
            }
        }
        #expect(counterexample == 50)
        #expect(failure == nil)
    }

    @Test("Ledger records the assertion's own source location")
    func ledgerRecordsAssertionLocation() {
        let ledger = AbsorbedIssues()
        ledger.absorbing {
            #expect(Bool(false))
        }
        let failures = ledger.expectationFailures
        #expect(failures.count == 1)
        #expect(failures.first?.location?.contains("UnobservedAssertionTests.swift") == true)
    }
}

/// Covers the XCTest branch of the suppression scope, which only an `XCTestCase` can exercise: `XCTExpectFailure` traps when it runs outside an XCTest test.
///
/// The branch sees XCTest's own assertion failures. A Swift Testing `#expect` records through Swift Testing, which an XCTest expected-failure scope never observes, so under an XCTest host an assertion the detection rewrite missed stays invisible.
final class AbsorbedIssuesXCTestTests: XCTestCase {
    func testXCTestAssertionFailuresReachTheLedger() {
        // Resolved inside an XCTestCase, where Test.current is nil, so this exercises the XCTest branch.
        let ledger = AbsorbedIssues()
        XCTAssertEqual(ledger.framework, .xcTest)

        ledger.absorbing {
            XCTFail("absorbed")
        }
        XCTAssertEqual(ledger.expectationFailures.count, 1)
    }
}

// MARK: - Helpers

/// A stored closure whose assertion the macro cannot rewrite, since it is not in the property closure's body.
private let alwaysFailingCheck: @Sendable (Int) -> Void = { value in
    #expect(value > 1000)
}

private func failingHelper(_ value: Int) {
    #expect(value > 1000)
}

private func failingAsyncHelper(_ value: Int) async {
    #expect(value > 1000)
}
