import XCTest
@testable import Exhaust

/// Integration tests for XCTest-specific behavior in the `#exhaust` pipeline.
final class XCTestIntegrationTests: XCTestCase {
    func testXCTSkipTreatedAsPassingValue() {
        let result = #exhaust(
            #gen(.int(in: 0 ... 100)),
            .suppress(.issueReporting),
            .budget(.custom(coverage: 0, sampling: 10)),
            .randomOnly
        ) { _ in
            throw XCTSkip("Skipping everything")
        }
        XCTAssertNil(result, "XCTSkip should be treated as passing, not as a counterexample")
    }
}
