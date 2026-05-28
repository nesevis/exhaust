import XCTest
@testable import Exhaust

/// Integration tests for XCTest-specific behavior in the `#exhaust` pipeline.
final class XCTestIntegrationTests: XCTestCase {
    func testXCTSkipTreatedAsPassingValue() {
        let result = #exhaust(
            #gen(.int(in: 0 ... 100)),
            .suppress(.issueReporting),
            .budget(.custom(coverage: 0, sampling: 10))
        ) { _ in
            throw XCTSkip("Skipping everything")
        }
        XCTAssertNil(result, "XCTSkip should be treated as passing, not as a counterexample")
    }

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
