import Testing
@testable import Exhaust

@Suite("#exhaust closure shapes")
struct ExhaustClosureShapeTests {
    // MARK: - Sync predicate (Bool-returning)

    @Test("Sync predicate: passing property")
    func syncPredicatePassing() {
        let result = #exhaust(
            #gen(.int(in: 0 ... 100)),
            .budget(.expedient),
            .suppress(.all)
        ) { value in
            value >= 0
        }
        #expect(result == nil)
    }

    @Test("Sync predicate: failing property finds counterexample")
    func syncPredicateFailing() {
        let result = #exhaust(
            #gen(.int(in: 0 ... 100)),
            .budget(.expedient),
            .suppress(.all)
        ) { value in
            value < 50
        }
        #expect(result != nil)
        if let counterexample = result {
            #expect(counterexample >= 50)
        }
    }

    // MARK: - Sync assertion (Void/#expect/#require)

    @Test("Sync assertion with #expect: passing property")
    func syncExpectPassing() {
        let result = #exhaust(
            #gen(.int(in: 0 ... 100)),
            .budget(.expedient),
            .suppress(.all)
        ) { value in
            #expect(value >= 0)
        }
        #expect(result == nil)
    }

    @Test("Sync assertion with #expect: failing property finds counterexample")
    func syncExpectFailing() {
        let result = #exhaust(
            #gen(.int(in: 0 ... 100)),
            .budget(.expedient),
            .suppress(.all)
        ) { value in
            #expect(value < 50)
        }
        #expect(result != nil)
    }

    @Test("Sync assertion with multi-statement body: passing property")
    func syncMultiStatementPassing() {
        let result = #exhaust(
            #gen(.int(in: 0 ... 100)),
            .budget(.expedient),
            .suppress(.all)
        ) { value in
            let doubled = value * 2
            #expect(doubled >= 0)
        }
        #expect(result == nil)
    }

    // MARK: - Async predicate

    @Test("Async predicate: passing property")
    func asyncPredicatePassing() async {
        let result = await #exhaust(
            #gen(.int(in: 0 ... 100)),
            .budget(.expedient),
            .suppress(.all)
        ) { value async in
            value >= 0
        }
        #expect(result == nil)
    }

    @Test("Async predicate: failing property finds counterexample")
    func asyncPredicateFailing() async {
        let result = await #exhaust(
            #gen(.int(in: 0 ... 100)),
            .budget(.expedient),
            .suppress(.all)
        ) { value async in
            value < 50
        }
        #expect(result != nil)
    }

    // MARK: - Async assertion

    @Test("Async assertion with #expect: passing property")
    func asyncExpectPassing() async {
        let result = await #exhaust(
            #gen(.int(in: 0 ... 100)),
            .budget(.expedient),
            .suppress(.all)
        ) { value async in
            #expect(value >= 0)
        }
        #expect(result == nil)
    }

    @Test("Async assertion with #expect: failing property finds counterexample")
    func asyncExpectFailing() async {
        let result = await #exhaust(
            #gen(.int(in: 0 ... 100)),
            .budget(.expedient),
            .suppress(.all)
        ) { value async in
            #expect(value < 50)
        }
        #expect(result != nil)
    }
}
