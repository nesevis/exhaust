import Benchmark
import Exhaust

// MARK: - Configuration

let enableReport = true
let enableCounterExamples = true
let reductionCount = 400
let benchmarkSeedsToRun = 1000
let reducerConfig = Interpreters.ReducerConfiguration(maxStalls: 2)

// Etna mutation-testing configuration
let etnaSeedCount = 10
let etnaCoverageBudget: Int = 0
let etnaSamplingBudget: Int = 200_000_000

// registerShrinkingChallengeBenchmarks()
registerECOOPBenchmarks()
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
// registerCGSTuningParameterSweepBenchmarks()
// registerCGSOnlineThroughputBenchmarks()
Benchmark.main()
