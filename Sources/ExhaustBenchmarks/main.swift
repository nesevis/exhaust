import Benchmark
import Exhaust

// MARK: - Configuration

let enableReport = true
let enableCounterExamples = true
let reductionCount = 400
let benchmarkSeedsToRun = 1000
let reducerConfig = Interpreters.ReducerConfiguration(maxStalls: 2)

// registerShrinkingChallengeBenchmarks()
// registerECOOPBenchmarks()
// registerComplexGrammarBenchmarks()
// registerGenerationBenchmarks()
registerParallelGenerationBenchmarks()
Benchmark.main()
