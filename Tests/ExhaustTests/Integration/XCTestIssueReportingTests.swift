import Exhaust
import XCTest

/// Verifies that `#exhaust` records XCTest failures when a property fails.
///
/// The framework uses `reportIssue` from the IssueReporting library, which bridges
/// to `XCTFail` under XCTest. These tests confirm that bridge works: a failing
/// property should produce an XCTest failure, and `.suppress(.issueReporting)` should
/// prevent it.
final class XCTestIssueReportingTests: XCTestCase {
    // XCTExpectFailure exists only in Apple's XCTest, not corelibs-xctest, so this test cannot run on Linux: without the marker the intentional failure would fail the suite.
    #if canImport(ObjectiveC)
        func testFailingPropertyRecordsXCTestFailure() {
            // reportIssue bridges to XCTFail, so #exhaust records an XCTest failure
            // for the failing property. XCTExpectFailure marks this as intentional.
            XCTExpectFailure("exhaust should report property failure via XCTFail")
            let result = #exhaust(
                #gen(.int(in: 0 ... 100)),
                .budget(.custom(screening: 0, sampling: 10))
            ) { value in
                value < 0
            }
            XCTAssertNotNil(result, "Should return a counterexample")
        }
    #endif

    func testSuppressedPropertyDoesNotRecordXCTestFailure() {
        // With suppressIssueReporting, no XCTest issue should be recorded.
        let result = #exhaust(
            #gen(.int(in: 0 ... 100)),
            .suppress(.issueReporting),
            .budget(.custom(screening: 0, sampling: 10))
        ) { value in
            value < 0
        }
        XCTAssertNotNil(result, "Should still return a counterexample")
    }

    func testPassingPropertyRecordsNoFailure() {
        let result = #exhaust(
            #gen(.int(in: 0 ... 100)),
            .budget(.custom(screening: 0, sampling: 10))
        ) { value in
            value >= 0
        }
        XCTAssertNil(result, "No counterexample for a passing property")
    }
}
