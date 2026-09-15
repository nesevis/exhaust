import Benchmark
import Exhaust
import ExhaustCore

// MARK: - Configuration

let enableReport = true
let enableCounterExamples = true
let reductionCount = 400
let benchmarkSeedsToRun = 1000
let reducerConfig = Interpreters.ReducerConfiguration(maxStalls: 2)

// Etna mutation-testing configuration
let etnaSeedCount = 10
let etnaScreeningBudget: Int = 0
let etnaSamplingBudget: Int = 200_000_000

// registerShrinkingChallengeBenchmarks()
registerMutationArmGateBenchmarks()
// registerECOOPBenchmarks()
// registerInterpreterHappyPathPerformanceBenchmarks()
// registerPreemptiveLoweHashMapBenchmarks()
// registerComplexGrammarBenchmarks()
// registerGenerationBenchmarks()
// registerSynthesizedGeneratorBenchmarks()
// registerParallelGenerationBenchmarks()
// registerStringGenerationBenchmarks()
// registerCoveringArrayBenchmarks()
// logRBTFeederGenerator()
// registerEtnaBenchmarks()
// registerUniquenessBenchmarks()
// registerCGSBSTThroughputBenchmarks()
// registerCGSOnlineThroughputBenchmarks()

// Standalone probes, run in place of the harness: `runWitnessShapeBenchmark()` for attempts-to-witness per synthetic shape, `runFuzzHotPathProbe()` for mutation-phase throughput on one workload. Each returns after printing; comment the harness call out below when using one.
// runWitnessShapeBenchmark(seeds: 24, seedOffset: 0, budgetSeconds: 4)
// runFuzzHotPathProbe(shape: .ifc, attempts: 200_000, repeats: 3)
Benchmark.main()
