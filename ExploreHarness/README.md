# ExploreHarness

The validation harness for `#explore(time:)`. A separate package so coverage instrumentation never touches Exhaust's own manifest.

CI runs both test targets through `swift package explore`, the path a real user follows, once with `--no-parallel` and once in parallel. `EXHAUST_HARNESS_COMMAND_COVERAGE=1` removes the manifest's own coverage flags so the command's recorder is the only one in the build:

```sh
EXHAUST_HARNESS_COMMAND_COVERAGE=1 swift package --package-path ExploreHarness explore \
  --instrument ExploreFixture --instrument SpecFixture --instrument SpecTrapProbe \
  --test-target ExploreTests --configuration debug --no-parallel
```

Without the variable, the manifest instruments the fixtures with `trace-pc-guard` in debug builds, so plain `swift test`, Xcode, and `ExploreBenchmark` work as before.

## The two-fixture rule

The package carries two deliberately buggy parsers, and they have different jobs:

- **`Parser` (the assertion fixture).** Four planted faults, all found within a 500 ms budget. It saturates far too fast to demonstrate search-power improvements, so it gates *regressions*: the tests in `ExploreTests` (`fuzzInventory`, `slippageDifferential`, the trap tests) are the standing regression gate for every landed mechanism, and their assertions are never weakened without asking.
- **`DeepParser` (the benchmark fixture).** Staged gate chains tuned so a coverage-guided run finds the deep faults P and Q within a 10-second budget while blind sampling at the matched attempt count has well under one expected hit per run (ground-truth registry with per-stage pass probabilities in `DeepParser.swift`). Search-power measurements run here. If tuning drifts, retune the gates — never the assertions.

## Benchmarking

`ExploreBenchmark` loops seeds against one fixture under one experiment arm and emits one JSONL record per run to stdout. Arms are switched through `EXHAUST_FUZZ_EXPERIMENT` (debug builds only; unknown knobs are a hard error). Always run with resume disabled and a scratch state directory so an interrupted benchmark cannot resume-contaminate the next run:

```sh
mkdir -p .benchmarks
EXHAUST_RESUME=0 EXHAUST_STATE_DIR=$(mktemp -d) \
swift run ExploreBenchmark --seeds 1-20 --budget-seconds 10 --fixture parser --arm baseline \
  >> .benchmarks/baseline-parser.jsonl

EXHAUST_RESUME=0 EXHAUST_STATE_DIR=$(mktemp -d) \
EXHAUST_FUZZ_EXPERIMENT="normalization=on" \
swift run ExploreBenchmark --seeds 1-20 --budget-seconds 10 --fixture parser --arm normalization-on \
  >> .benchmarks/normalization-on-parser.jsonl

swift run ExploreBenchmark analyze .benchmarks/baseline-parser.jsonl .benchmarks/normalization-on-parser.jsonl \
  --discovery "faultB=.control;region: 2;[0]: 241"
```

The `analyze` subcommand pairs runs by (fixture, seed), prints per-seed deltas first, then per-fixture medians, IQRs, and two-sided paired sign-test verdicts per metric (plus a pooled block on multi-fixture files). `swift run ExploreBenchmark calibrate` runs the whole matrix calibration sweep and prints per-fixture window verdicts; it pins the resume environment itself. `.benchmarks/` is gitignored; benchmark outputs are never committed.
