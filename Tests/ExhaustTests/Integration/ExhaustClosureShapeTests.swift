import Exhaust
import Testing

@Suite("#exhaust closure shapes")
struct ExhaustClosureShapeTests {
    @Test("syncPredicate preserves passing and failing behavior in both phases", arguments: [false, true], [false, true])
    func syncPredicate(screening: Bool, fails: Bool) throws {
        var report: ExhaustReport?
        let result: Int? = #exhaust(
            #gen(.int(in: 0 ... 100)),
            .budget(.custom(screening: screening ? 200 : 0, sampling: screening ? 0 : 200)),
            .replay(42),
            .suppress(.all),
            .onReport { report = $0 }
        ) { value in
            fails == false || value < 50
        }
        #expect(result == (fails ? 50 : nil))
        let completed = try #require(report)
        #expect(completed.propertyInvocations > 0)
    }

    @Test("syncAssertion preserves passing and failing behavior in both phases", arguments: [false, true], [false, true])
    func syncAssertion(screening: Bool, fails: Bool) throws {
        var report: ExhaustReport?
        let result: Int? = #exhaust(
            #gen(.int(in: 0 ... 100)),
            .budget(.custom(screening: screening ? 200 : 0, sampling: screening ? 0 : 200)),
            .replay(42),
            .suppress(.all),
            .onReport { report = $0 }
        ) { value in
            #expect(value >= 0)
            #expect(value <= 100)
            #expect(fails == false || value < 50)
        }
        #expect(result == (fails ? 50 : nil))
        let completed = try #require(report)
        #expect(completed.propertyInvocations > 0)
    }

    @Test("asyncPredicate preserves passing and failing behavior in both phases", arguments: [false, true], [false, true])
    func asyncPredicate(screening: Bool, fails: Bool) async throws {
        var report: ExhaustReport?
        let result: Int? = await #exhaust(
            #gen(.int(in: 0 ... 100)),
            .budget(.custom(screening: screening ? 200 : 0, sampling: screening ? 0 : 200)),
            .replay(42),
            .suppress(.all),
            .onReport { report = $0 }
        ) { value async in
            fails == false || value < 50
        }
        #expect(result == (fails ? 50 : nil))
        let completed = try #require(report)
        #expect(completed.propertyInvocations > 0)
    }

    @Test("asyncAssertion preserves passing and failing behavior in both phases", arguments: [false, true], [false, true])
    func asyncAssertion(screening: Bool, fails: Bool) async throws {
        var report: ExhaustReport?
        let result: Int? = await #exhaust(
            #gen(.int(in: 0 ... 100)),
            .budget(.custom(screening: screening ? 200 : 0, sampling: screening ? 0 : 200)),
            .replay(42),
            .suppress(.all),
            .onReport { report = $0 }
        ) { value async in
            #expect(value >= 0)
            #expect(value <= 100)
            #expect(fails == false || value < 50)
        }
        #expect(result == (fails ? 50 : nil))
        let completed = try #require(report)
        #expect(completed.propertyInvocations > 0)
    }

    @Test("Sync assertion with multi-statement body: passing property")
    func syncMultiStatementPassing() {
        let result = #exhaust(
            #gen(.int(in: 0 ... 100)),
            .budget(.standard),
            .suppress(.all)
        ) { value in
            let doubled = value * 2
            #expect(doubled >= 0)
        }
        #expect(result == nil)
    }
}
