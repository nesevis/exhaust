import Benchmark
import Exhaust
import ExhaustCore
import Foundation

func registerParallelGenerationBenchmarks() {
    let laneCounts = Array(UInt8(1) ... 8)

    for lanes in laneCounts {
        let suffix = lanes == 1 ? "sequential" : "parallel(\(lanes))"

        benchmark("ParGen: Parser \(suffix)") {
            _ = #exhaust(
                parserLangGen,
                .suppress(.all),
                .budget(.extensive),
                .randomOnly,
                .parallelize(lanes)
            ) { _ in true }
        }

        benchmark("ParGen: Bound5 \(suffix)") {
            _ = #exhaust(
                bound5Gen,
                .suppress(.all),
                .budget(.extensive),
                .randomOnly,
                .parallelize(lanes)
            ) { _ in true }
        }

        benchmark("ParGen: Coupling \(suffix)") {
            _ = #exhaust(
                couplingGen,
                .suppress(.all),
                .budget(.extensive),
                .randomOnly,
                .parallelize(lanes)
            ) { _ in true }
        }

        benchmark("ParGen: LargeUnionList \(suffix)") {
            _ = #exhaust(
                largeUnionListGen,
                .suppress(.all),
                .budget(.extensive),
                .randomOnly,
                .parallelize(lanes)
            ) { _ in true }
        }

        benchmark("ParGen: Calculator \(suffix)") {
            _ = #exhaust(
                calculatorExpressionGen(depth: 5),
                .suppress(.all),
                .budget(.extensive),
                .randomOnly,
                .parallelize(lanes)
            ) { _ in true }
        }
    }
}
