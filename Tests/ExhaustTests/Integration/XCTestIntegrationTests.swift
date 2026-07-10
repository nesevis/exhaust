import Exhaust
import XCTest

/// Integration tests for XCTest-specific behavior in the `#exhaust` pipeline.
final class XCTestIntegrationTests: XCTestCase {
    // The pipeline's silent probing under XCTest relies on expected-failure support (XCTExpectFailure via IssueReporting), which corelibs-xctest does not provide; on Linux IssueReporting reports "Expecting failures is unavailable in XCTest on this platform" instead.
    #if canImport(ObjectiveC)
        func testXCTSkipTreatedAsPassingValue() {
            // A skipped invocation is not a counterexample, so the result stays nil. A run whose every invocation was skipped asserts nothing, so it must report a pointless-run failure; XCTExpectFailure fails this test if that failure ever stops firing.
            XCTExpectFailure("All invocations were skipped, so the run reports a pointless-run failure")
            let result = #exhaust(
                #gen(.int(in: 0 ... 100)),
                .suppress(.issueReporting),
                .budget(.custom(screening: 0, sampling: 10))
            ) { _ in
                throw XCTSkip("Skipping everything")
            }
            XCTAssertNil(result, "XCTSkip should be treated as passing, not as a counterexample")
        }
    #endif

    /// When an XTUnwrap fails it takes ~400ms to report a failure
    func doNotRun_testVoidClosureDoesNotWork() throws {
        throw XCTSkip("Should except to test response")
        #exhaust(
            .int(in: 0 ... 100).optional(),
            .suppress(.issueReporting)
        ) { value in
            try XCTUnwrap(value) > 0
        }
    }

    func testXCTAssertProvidesDiagnostic() {
//        #exhaust(.int()) { n in
//            XCTAssertTrue(n > 5)
//        }
    }
}
