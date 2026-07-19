# \#explore

Test a property with per-direction coverage guarantees or coverage-guided fuzzing.

## Overview

`#explore` has two modes, selected by parameter:

**Directed exploration** (`directions:`) steers sampling toward named regions of the output space using Choice Gradient Sampling. Each direction is a predicate the test must reach; unreachable directions are reported rather than silently skipped.

```swift
#explore(orderGen,
    directions: [
        ("has refund",       { $0.hasRefund }),
        ("refund + partial", { $0.hasRefund && $0.fulfilment == .partial }),
    ]
) { order in
    #expect(order.balance.isValid)
}
```

| Parameter | Description |
|---|---|
| `gen` | The generator to draw inputs from. |
| `directions` | Named predicates over the output, each describing a region to cover. |
| `settings` | Variadic ``ExploreSettings`` values: budget, replay, parallelism, suppression. |
| `property` | Closure checked against each generated value. Async closures supported with `await`. |

Returns an ``ExploreReport`` with per-direction coverage and the counterexample if any.

For the full guide, see <doc:DirectedExploration>.

**Coverage-guided fuzzing** (`time:`) gives Exhaust a wall-clock time budget. It watches which branches your code takes, uses that feedback to generate inputs that reach new branches, and catalogues every distinct fault it finds rather than stopping at the first.

> Experiment: This mode is experimental. Settings, report format, and search behaviour may change in any release.

```swift
@Test func parserHandlesAdversarialInput() async {
    await #explore(myInputGenerator, time: .minutes(15)) { input in
        let result = try MyParser.parse(input)
        #expect(result.isWellFormed)
    }
}
```

| Parameter | Description |
|---|---|
| `gen` | The generator to draw inputs from. |
| `time` | Wall-clock ``TimeSpan`` for the run (for example `.minutes(15)`). |
| `settings` | Variadic ``FuzzSettings`` values: replay, suppression, log verbosity. |
| `property` | Closure checked against each generated value. Async closures supported with `await`. |

Requires coverage instrumentation on the target under test. Returns a ``FuzzReport`` with the clustered fault inventory, attempt counts, throughput, and coverage summary.

The `directions:` and `time:` parameters are mutually exclusive. Use `directions:` when you can name the regions you want tested. Use `time:` for the open-ended case where you want Exhaust to find what you haven't thought to name.

For the full guide, see <doc:CoverageGuidedFuzzing>.
