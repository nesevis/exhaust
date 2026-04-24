import Testing
@testable import Exhaust

@Suite("#explore closure shapes")
struct ExploreClosureShapeTests {
    private static let budget = ExploreBudget.custom(hitsPerDirection: 10, maxAttemptsPerDirection: 200)
    private static let directions: [(String, @Sendable (Int) -> Bool)] = [
        ("any", { _ in true }),
    ]

    // MARK: - Sync predicate (Bool-returning)

    @Test("Sync predicate: passing property")
    func syncPredicatePassing() {
        let gen = #gen(.int(in: 0 ... 100))
        let report = #explore(
            gen,
            .budget(.custom(hitsPerDirection: 10, maxAttemptsPerDirection: 200)),
            .suppress(.all),
            directions: [("any", { (_: Int) in true })]
        ) { value in
            value >= 0
        }
        #expect(report.result == nil)
        #expect(report.termination == .coverageAchieved)
    }

    @Test("Sync predicate: failing property finds counterexample")
    func syncPredicateFailing() {
        let gen = #gen(.int(in: 0 ... 100))
        let report = #explore(
            gen,
            .budget(.custom(hitsPerDirection: 10, maxAttemptsPerDirection: 200)),
            .suppress(.all),
            directions: [("any", { (_: Int) in true })]
        ) { value in
            value < 50
        }
        #expect(report.result != nil)
        #expect(report.termination == .propertyFailed)
    }

    // MARK: - Sync assertion (Void/#expect/#require)

    @Test("Sync assertion with #expect: passing property")
    func syncExpectPassing() {
        let gen = #gen(.int(in: 0 ... 100))
        let report = #explore(
            gen,
            .budget(.custom(hitsPerDirection: 10, maxAttemptsPerDirection: 200)),
            .suppress(.all),
            directions: [("any", { (_: Int) in true })]
        ) { value in
            #expect(value >= 0)
        }
        #expect(report.result == nil)
        #expect(report.termination == .coverageAchieved)
    }

    @Test("Sync assertion with #expect: failing property finds counterexample")
    func syncExpectFailing() {
        let gen = #gen(.int(in: 0 ... 100))
        let report = #explore(
            gen,
            .budget(.custom(hitsPerDirection: 10, maxAttemptsPerDirection: 200)),
            .suppress(.all),
            directions: [("any", { (_: Int) in true })]
        ) { value in
            #expect(value < 50)
        }
        #expect(report.result != nil)
        #expect(report.termination == .propertyFailed)
    }

    @Test("Sync assertion with throw: failing property finds counterexample")
    func syncThrowFailing() {
        let gen = #gen(.int(in: 0 ... 100))
        let report = #explore(
            gen,
            .budget(.custom(hitsPerDirection: 10, maxAttemptsPerDirection: 200)),
            .suppress(.all),
            directions: [("any", { (_: Int) in true })]
        ) { value in
            if value >= 50 {
                throw TestError()
            }
        }
        #expect(report.result != nil)
        #expect(report.termination == .propertyFailed)
    }

    @Test("Sync assertion with multi-statement body: passing property")
    func syncMultiStatementPassing() {
        let gen = #gen(.int(in: 0 ... 100))
        let report = #explore(
            gen,
            .budget(.custom(hitsPerDirection: 10, maxAttemptsPerDirection: 200)),
            .suppress(.all),
            directions: [("any", { (_: Int) in true })]
        ) { value in
            let doubled = value * 2
            #expect(doubled >= 0)
        }
        #expect(report.result == nil)
        #expect(report.termination == .coverageAchieved)
    }

    // MARK: - Async predicate

    @Test("Async predicate: passing property")
    func asyncPredicatePassing() async {
        let gen = #gen(.int(in: 0 ... 100))
        let report = await #explore(
            gen,
            .budget(.custom(hitsPerDirection: 10, maxAttemptsPerDirection: 200)),
            .suppress(.all),
            directions: [("any", { (_: Int) in true })]
        ) { value async in
            value >= 0
        }
        #expect(report.result == nil)
        #expect(report.termination == .coverageAchieved)
    }

    @Test("Async predicate: failing property finds counterexample")
    func asyncPredicateFailing() async {
        let gen = #gen(.int(in: 0 ... 100))
        let report = await #explore(
            gen,
            .budget(.custom(hitsPerDirection: 10, maxAttemptsPerDirection: 200)),
            .suppress(.all),
            directions: [("any", { (_: Int) in true })]
        ) { value async in
            value < 50
        }
        #expect(report.result != nil)
        #expect(report.termination == .propertyFailed)
    }

    // MARK: - Async assertion

    @Test("Async assertion with #expect: passing property")
    func asyncExpectPassing() async {
        let gen = #gen(.int(in: 0 ... 100))
        let report = await #explore(
            gen,
            .budget(.custom(hitsPerDirection: 10, maxAttemptsPerDirection: 200)),
            .suppress(.all),
            directions: [("any", { (_: Int) in true })]
        ) { value async in
            #expect(value >= 0)
        }
        #expect(report.result == nil)
        #expect(report.termination == .coverageAchieved)
    }

    @Test("Async assertion with #expect: failing property finds counterexample")
    func asyncExpectFailing() async {
        let gen = #gen(.int(in: 0 ... 100))
        let report = await #explore(
            gen,
            .budget(.custom(hitsPerDirection: 10, maxAttemptsPerDirection: 200)),
            .suppress(.all),
            directions: [("any", { (_: Int) in true })]
        ) { value async in
            #expect(value < 50)
        }
        #expect(report.result != nil)
        #expect(report.termination == .propertyFailed)
    }
}

// MARK: - Helpers

private struct TestError: Error {}
