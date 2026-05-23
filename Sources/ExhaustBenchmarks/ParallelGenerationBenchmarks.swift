import Benchmark
import Exhaust
import ExhaustCore
import Foundation

func registerParallelGenerationBenchmarks() {
    benchmark("ParGen: Parser sequential") {
        _ = #exhaust(
            parserLangGen,
            .suppress(.all),
            .budget(.extensive),
            .randomOnly
        ) { _ in true }
    }

    benchmark("ParGen: Parser parallel") {
        _ = #exhaust(
            parserLangGen,
            .suppress(.all),
            .budget(.extensive),
            .randomOnly,
            .parallelize
        ) { _ in true }
    }

    benchmark("ParGen: Calculator sequential") {
        _ = #exhaust(
            calculatorExpressionGen(depth: 5),
            .suppress(.all),
            .budget(.extensive),
            .randomOnly
        ) { _ in true }
    }

    benchmark("ParGen: Calculator parallel") {
        _ = #exhaust(
            calculatorExpressionGen(depth: 5),
            .suppress(.all),
            .budget(.extensive),
            .randomOnly,
            .parallelize
        ) { _ in true }
    }

    benchmark("ParGen: LargeUnionList sequential") {
        _ = #exhaust(
            largeUnionListGen,
            .suppress(.all),
            .budget(.extensive),
            .randomOnly
        ) { _ in true }
    }

    benchmark("ParGen: LargeUnionList parallel") {
        _ = #exhaust(
            largeUnionListGen,
            .suppress(.all),
            .budget(.extensive),
            .randomOnly,
            .parallelize
        ) { _ in true }
    }

    benchmark("ParGen: Bound5 sequential") {
        _ = #exhaust(
            bound5Gen,
            .suppress(.all),
            .budget(.extensive),
            .randomOnly
        ) { _ in true }
    }

    benchmark("ParGen: Bound5 parallel") {
        _ = #exhaust(
            bound5Gen,
            .suppress(.all),
            .budget(.extensive),
            .randomOnly,
            .parallelize
        ) { _ in true }
    }

    benchmark("ParGen: Coupling sequential") {
        _ = #exhaust(
            couplingGen,
            .suppress(.all),
            .budget(.extensive),
            .randomOnly
        ) { _ in true }
    }

    benchmark("ParGen: Coupling parallel") {
        _ = #exhaust(
            couplingGen,
            .suppress(.all),
            .budget(.extensive),
            .randomOnly,
            .parallelize
        ) { _ in true }
    }
}
