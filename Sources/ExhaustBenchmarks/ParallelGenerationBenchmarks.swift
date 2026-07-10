import Benchmark
import Exhaust
import ExhaustCore
import Foundation

func registerParallelGenerationBenchmarks() {
    let laneCounts = ConcurrencyLevel.allCases

    for lanes in laneCounts {
        let suffix = lanes == .one ? "sequential" : "parallel(\(lanes.rawValue))"

        benchmark("ParGen: Parser \(suffix)") {
            _ = #exhaust(
                parserLangGen,
                .suppress(.all),
                .budget(.custom(screening: 0, sampling: 2000)),
                .parallelize(lanes: lanes)
            ) { _ in true }
        }

        benchmark("ParGen: Bound5 \(suffix)") {
            _ = #exhaust(
                bound5Gen,
                .suppress(.all),
                .budget(.custom(screening: 0, sampling: 2000)),
                .parallelize(lanes: lanes)
            ) { _ in true }
        }

        benchmark("ParGen: Coupling \(suffix)") {
            _ = #exhaust(
                couplingGen,
                .suppress(.all),
                .budget(.custom(screening: 0, sampling: 2000)),
                .parallelize(lanes: lanes)
            ) { _ in true }
        }

        benchmark("ParGen: LargeUnionList \(suffix)") {
            _ = #exhaust(
                largeUnionListGen,
                .suppress(.all),
                .budget(.custom(screening: 0, sampling: 2000)),
                .parallelize(lanes: lanes)
            ) { _ in true }
        }

        benchmark("ParGen: Calculator \(suffix)") {
            _ = #exhaust(
                calculatorExpressionGen(depth: 5),
                .suppress(.all),
                .budget(.custom(screening: 0, sampling: 2000)),
                .parallelize(lanes: lanes)
            ) { _ in true }
        }
    }
}
