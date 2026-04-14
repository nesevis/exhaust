import Exhaust
import Benchmark

// MARK: - Configuration

let enableReport = true
let enableCounterExamples = true
let reductionCount = 400
let benchmarkSeedsToRun = 1000
let reducerConfig = Interpreters.ReducerConfiguration.slow

// registerShrinkingChallengeBenchmarks()
registerECOOPBenchmarks()
// registerComplexGrammarBenchmarks()
Benchmark.main()
