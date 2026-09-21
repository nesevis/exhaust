import Exhaust
import Testing

@Suite("Exhaustive verdict")
struct ExhaustiveVerdictTests {
    @Test("A property over optional values is sampled beyond the two pick rows")
    func optionalIsSampled() throws {
        let report = try report(for: #gen(.int(in: 0 ... 20000).optional()))
        #expect(report.randomSamplingInvocations > 0)
    }

    @Test("A property over a choice of ranges is sampled beyond the pick rows")
    func oneOfIsSampled() throws {
        let report = try report(for: #gen(.oneOf(.int(in: 0 ... 20000), .int(in: 30000 ... 50000))))
        #expect(report.randomSamplingInvocations > 0)
    }

    @Test("A property over a choice with one constant arm is sampled")
    func oneOfWithConstantArmIsSampled() throws {
        let report = try report(for: #gen(.oneOf(.just(0), .int(in: 1 ... 20000))))
        #expect(report.randomSamplingInvocations > 0)
    }

    @Test("A property over withdrawing arms is sampled")
    func anyNonNilIsSampled() throws {
        let arm = #gen(.int(in: 0 ... 20000)) { value in Int?.some(value) }
        let report = try report(for: #gen(.anyNonNil(always: (1, arm), (1, arm))))
        #expect(report.randomSamplingInvocations > 0)
    }

    @Test("A property over a vector beside a flag is sampled beyond the flag's rows")
    func opaqueVectorIsSampled() throws {
        let report = try report(for: #gen(.bool(), .simd2(.int(in: 0 ... 20000), .int(in: 0 ... 20000))))
        #expect(report.randomSamplingInvocations > 0)
    }

    @Test("A failure inside a pick arm is found")
    func failureInsideArmIsFound() throws {
        let generator = #gen(.oneOf(.int(in: 0 ... 200), .int(in: 300 ... 500)))
        let counterexample = #exhaust(generator, .budget(.extensive), .suppress(.issueReporting)) { value in
            value % 100 != 7
        }
        let value = try #require(counterexample)
        #expect(value % 100 == 7)
    }

    @Test("A choice of constants is still enumerated without sampling")
    func constantArmsStayExhaustive() throws {
        let report = try report(for: #gen(.oneOf(.just(1), .just(2), .just(3))))
        #expect(report.screeningInvocations == 3)
        #expect(report.randomSamplingInvocations == 0)
    }

    @Test("Small independent choices are still enumerated without sampling")
    func smallChoicesStayExhaustive() throws {
        let report = try report(for: #gen(.int(in: 0 ... 9), .bool()))
        #expect(report.screeningInvocations == 20)
        #expect(report.randomSamplingInvocations == 0)
    }
}

// MARK: - Helpers

private func report(for generator: ReflectiveGenerator<some Any>) throws -> ExhaustReport {
    var captured: ExhaustReport?
    #exhaust(generator, .budget(.standard), .onReport { captured = $0 }) { _ in
        true
    }
    return try #require(captured)
}
