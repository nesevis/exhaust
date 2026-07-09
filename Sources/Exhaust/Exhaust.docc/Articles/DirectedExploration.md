# Directed exploration

When `#exhaust` passes too easily for comfort, `#explore` is the next step. `#exhaust` gives you confidence that the property holds across the generator's structural boundaries, but it can't guarantee that your specific semantic concerns were covered. A test that passes across hundreds of iterations might never have generated a value in the region you care about.

`#explore` lets you declare the regions you want the test to cover as named directions over the output space, and guarantees each one receives a minimum number of samples.

## Declaring directions

Directions are named predicates over the generated value:

```swift
@Test func balanceCheckerCoversEdgeCases() {
    let gen = #gen(
        .int(in: -100...100), .int(in: -100...100),
        .int(in: -100...100), .int(in: -100...100)
    )

    let report = #explore(gen,
        directions: [
            ("all positive",     { t in t.0 >= 0 && t.1 >= 0 && t.2 >= 0 && t.3 >= 0 }),
            ("dips below zero",  { t in /* running sum goes negative */ ... }),
            ("large values",     { t in abs(t.0) > 80 || abs(t.1) > 80 }),
        ]
    ) { value in
        validateBalance(value)
    }
}
```

## How exploration works

Exploration starts with an untuned warm-up phase that samples without bias. This often covers several directions at once. Then, for each direction that still needs samples, Exhaust tunes a separate copy of the generator via Choice Gradient Sampling to steer toward that region and draws K samples. Every sample is classified against every direction, so a single sample can satisfy multiple directions simultaneously. Unused budget from directions that are satisfied early flows to directions that need more attempts.

`#exhaust` asks "does the property hold across the generator's structural edges?" `#explore` asks "have the specific regions I declared actually been visited?" Use `#exhaust` to cover the generator's structural edges, `#explore` to cover the semantic regions you name, or both when you want both guarantees.

A direction that receives no matching samples within its attempt budget fails the test, naming the unreachable direction. Either the generator cannot produce matching values, the predicate never holds, or the budget is too small; the failure tells you to widen the generator, fix the predicate, or raise the budget. An unreachable region never passes silently.

## ExploreReport

`#explore` returns an `ExploreReport` containing:

- **Per-direction coverage**: how many samples matched each direction, with separate counts for the untuned warm-up and each direction's tuning pass.
- **Direction attribution**: if the property fails, the counterexample's report shows which directions it belonged to, so you know which behavioural region the bug lives in. Reduction preserves the matched directions: the reduced counterexample stays in the same behavioural region as the original failure.
- **Co-occurrence matrix**: pairwise overlap counts between directions, revealing which directions are independent and which are entangled.

## Settings

| Setting | Default | Effect |
|---|---|---|
| `.budget(.quick)` | — | 10 hits per direction, 100 max attempts per direction. |
| `.budget(.standard)` | default | 30 hits per direction, 300 max attempts per direction. |
| `.budget(.thorough)` | — | 100 hits per direction, 1,000 max attempts per direction. |
| `.budget(.extensive)` | — | 300 hits per direction, 3,000 max attempts per direction. |
| `.budget(.custom(...))` | — | Explicit values for hit target and attempt budget. |
| `.replay(seed)` | — | Deterministic reproduction. |
| `.parallelize` | off | Tunes and samples each direction on its own GCD lane. Skips the warm-up pass. Has no effect with `.replay`. |
| `.suppress(.issueReporting)` | — | Silences issue reporting. Use when asserting on the returned `ExploreReport` directly. `.suppress(.logs)` and `.suppress(.all)` also available. |
| `.log(.debug)` | `.error` | Sets the minimum log level for this test run. |

> Note:
> `#explore` is more expensive than `#exhaust`. The total attempt budget is the per-direction budget multiplied by the number of declared directions. Five directions at `.standard` means 1,500 total attempts, plus CGS tuning overhead per direction. Start with `.standard` and increase the budget only for directions that need stronger coverage.
