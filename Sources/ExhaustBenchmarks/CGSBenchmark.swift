// MARK: - CGS Tuning Benchmark

//
// Measures the cost of online CGS tuning during generation.
// The generator places a filter inside a bind so that CGS tuning
// is deferred until generation time (cannot be pre-tuned).
// Each seed generates a single value — the cost is dominated by
// the CGS derivative sampling path (CGSDerivativeInterpreter).

import Benchmark
import Exhaust
import ExhaustCore
import Foundation

func registerCGSBenchmarks() {
    let seedCount = 1000
    let baseSeed: UInt64 = 1337

    let gen = cgsBenchmarkGen()

    benchmark("CGS Tuning (filter-in-bind)") {
        var totalIterations = 0
        for i in 0 ..< seedCount {
            let seed = baseSeed &+ UInt64(i)
            var iterator = ValueAndChoiceTreeInterpreter(
                gen.gen,
                materializePicks: false,
                seed: seed,
                maxRuns: 10000
            )
            do {
                if try iterator.next() != nil {
                    totalIterations += 1
                }
            } catch {}
        }
        precondition(totalIterations > 0)
    }
}

// MARK: - Generator

private func cgsBenchmarkGen() -> ReflectiveGenerator<[Int]> {
    #gen(
        .int(in: 1 ... 200).bind { bound in
            .int(in: 0 ... 1000)
                .filter { $0 % bound == 0 }
                .array(length: 3 ... 5)
        }
    )
}
