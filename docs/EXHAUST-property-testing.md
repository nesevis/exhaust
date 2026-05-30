# Running property tests

`#exhaust` tests a property across generated values and reports a minimal counterexample on failure. This page covers closure shapes, settings, and observability. For contract tests over stateful systems, see [Contract testing](EXECUTE-contract-testing.md) and the `#execute` macro.

## Closure shapes

`#exhaust` supports four closure shapes:

```swift
// Predicate — return true if the property holds
#exhaust(gen) { value in
    value.isValid == true
}

// Predicate, async
await #exhaust(gen) { value in
    await value.validate()
}

// Assertion — any thrown error or #expect failure is a counterexample
#exhaust(gen) { value in
    let result = try value.process()
    #expect(result.count > 0)
}

// Assertion, async
await #exhaust(gen) { value in
    let result = try await value.process()
    #expect(result.count > 0)
}
```

Exhaust decides which path to use based on the closure body: single-expression closures that return `Bool` use the predicate path, everything else uses the assertion path.

## Using `#expect` and `#require`

Instead of returning a `Bool`, you can write Swift Testing assertions directly inside `#exhaust`:

```swift
@Test func sortedArrayIsSorted() {
    #exhaust(.int(in: -10...10).array(length: 0...20)) { array in
        let sorted = array.sorted()
        for i in sorted.indices.dropLast() {
            #expect(sorted[i] <= sorted[i + 1])
        }
    }
}
```

When the closure contains `#expect`, `#require`, or multiple statements, Exhaust automatically treats any assertion failure or thrown error as a counterexample. During reduction, assertion failures are suppressed so that test output stays clean. Once the minimal counterexample is found, the closure runs one final time with native `#expect`/`#require` reporting, so the failure message you see in the test log describes the reduced value.

`#require` works for optional unwrapping. When a function under test returns an optional, unwrap it with `#require` and assert on the non-nil value:

```swift
@Test func lookupFindsInsertedKey() {
    let gen = #gen(.asciiString(length: 1...10), .int(in: -100...100))
    #exhaust(gen) { key, value in
        var store = MyStore()
        store.insert(key: key, value: value)
        let retrieved = try #require(store.lookup(key))
        #expect(retrieved == value)
    }
}
```

You can also throw errors directly. Any thrown error counts as a failure:

```swift
#exhaust(gen) { value in
    if value.isInvalid {
        throw ValidationError()
    }
}
```

> [!Tip]
> The property closure may be called thousands of times during coverage, sampling, and reduction. Keep it as fast as possible: avoid disk I/O, network calls, and expensive setup.

## Settings

| Setting | Default | Effect |
|---|---|---|
| `.budget(.quick)` | — | 100 coverage rows, 100 random samples. |
| `.budget(.standard)` | default | 200 coverage rows, 200 random samples. |
| `.budget(.thorough)` | — | 600 coverage rows, 600 random samples. |
| `.budget(.extensive)` | — | 2,000 coverage rows, 2,000 random samples. |
| `.budget(.custom(...))` | — | Explicit values for coverage and sampling budgets. |
| `.budget(.thorough * 3)` | — | Scale any preset with `*` or `/`. |
| `.replay(seed)` | — | Deterministic reproduction from a failure report seed (for example `.replay("8DZR69-7")`). Also accepts a raw `UInt64`. |
| `reflecting: value` | `nil` | Skip generation; reflect the given value and reduce it (see [Reflecting known values](GEN-building-generators.md#reflecting-known-values)). Passed as a named parameter, not a setting. |
| `.visualize` | off | Prints the choice tree before and after reduction as a Unicode visualisation. |
| `.onReport(closure)` | — | Registers a closure that receives an `ExhaustReport` after the test completes. See [Run statistics](#run-statistics). |
| `.collectOpenPBTStats` | off | Collects per-example statistics in [OpenPBTStats](https://tyche-pbt.github.io/tyche-extension/) JSON Lines format. See [Test observability](#test-observability). |
| `.includeDiff` | off | Includes a structural diff between the original failing value and the reduced counterexample in the failure output. |
| `.suppress(.issueReporting)` | — | Silences issue reporting. Use when asserting on the return value directly. `.suppress(.logs)` silences console output. `.suppress(.all)` for a completely silent run. |
| `.log(.debug)` | `.error` | Sets the minimum log level for this test run. Only messages at or above the level are emitted. |
| `.parallel(N)` | off | Splits the random sampling phase across N parallel GCD lanes. Same seed, same counterexample regardless of lane count. Has no effect with `.replay`. |

## Ordered coverage of problematic values

Testing happens in two phases. Before random sampling begins, Exhaust systematically tests problematic values and parameter interactions. Bugs cluster around specific values: off-by-one errors at range edges, sign confusion at zero crossings, special-case handling of NaN and empty collections, timezone transitions that shift timestamps by an hour. Random sampling can take thousands of iterations to reach these values by chance. Exhaust tests them deliberately.

For each generator parameter, Exhaust draws from a catalogue of problematic values: min, max, and values near the edges for integers; NaN, infinities, and denormals for floats; DST transitions and epoch points for dates; known-troublesome Unicode scalars for characters; lengths 0, 1, and 2 for collections. These values are combined pairwise across parameters using a [covering array](https://onlinelibrary.wiley.com/doi/epdf/10.1002/stvr.393), so that every pair of problematic values from different parameters appears in at least one test case.

The covering array is a delivery mechanism, not the source of bug-finding power. Classical t-way testing covers every combination of parameter values from a configuration space. Exhaust uses the same algorithm for a different purpose: ensuring that every pairwise combination of *problematic values* — the values bugs cluster around — is tested together.

A NIST study of faults in Mozilla and Apache found that most faults involved interactions among just two to six conditions (Kuhn and Reilly, [An Investigation of the Applicability of Design of Experiments to Software Testing](https://csrc.nist.gov/publications/detail/journal-article/2002/an-investigation-of-the-applicability-of-design-of-experiments-to-software-testing), NASA/IEEE SEW 2002). This motivates the pairwise combination strategy: if faults emerge from small groups of interacting parameters, testing every pair of problematic values catches the interactions that matter. 

A function that overflows at `Int.max + 1` fails only when one parameter is at its maximum and the other is at least 1. Neither value alone triggers the bug. The covering array guarantees the pair is tested.

Exhaust defaults to pairwise (t=2) coverage, but will go up to t=4 for smaller domains where the higher-strength arrays fit within the coverage budget. The coverage rows in the budget table control how many of these problematic-value combinations Exhaust tests before moving to random sampling.

In the rare case where the generator's total domain is small enough to fit within the coverage budget, Exhaust enumerates it exhaustively and skips random sampling entirely.

## Run statistics

The `.onReport` setting delivers an `ExhaustReport` with timing and invocation data for each phase of the test run. It includes data like per-phase wall-clock times (coverage, generation, reduction, reflection), and total property invocations. Use it to understand where time is spent and whether coverage or reduction budgets need tuning.

```swift
#exhaust(
  gen, 
  .onReport { report in print(report.profilingSummary) }
) { value in
    value.isValid
}
```

## Test observability

The `.collectOpenPBTStats` setting records per-example data in the [OpenPBTStats](https://dl.acm.org/doi/fullHtml/10.1145/3654777.3676407) JSON Lines format and attaches it to the test run. You can inspect the attached `.jsonl` file with the [Tyche](https://tyche-pbt.github.io/tyche-extension/) data inspector to visualise input distributions, sample breakdowns, and individual test examples.

```swift
#exhaust(gen, .collectOpenPBTStats) { value in
    value.isValid
}
```

Each line records the example's pass/fail status, a `customDump` representation, and complexity features derived automatically from the choice tree. Filter rejections from CGS or rejection sampling are surfaced as `gave_up` entries.

The attachment is recorded via Swift Testing's `Attachment` API, or via `XCTAttachment` when running under XCTest. Contract tests support `.collectOpenPBTStats` through `ContractSettings`.

### Why this matters

A property test that passes does not mean the generator is good. It may mean the generator never reaches the interesting part of the input space. OpenPBTStats data helps you answer three questions that passing tests hide:

1. **How many inputs were actually valid?** If a large proportion of generated values are discarded by filters, the generator is wasting its budget on rejected samples. A high `gave_up` count signals that the generator needs restructuring or that CGS tuning should be enabled.
2. **How are values distributed?** Complexity features reveal whether generated values cluster around simple cases or spread across the domain. A generator that always produces small arrays or zero-heavy integers may miss bugs that only appear at scale. Visualising the `complexity_mean` distribution in Tyche can expose these blind spots.
3. **Are any regions of the input space missing?** By inspecting individual examples and their features, you can check whether problematic values, large inputs, and negative cases all appear. If an important region is absent, the generator or its filter predicates may need adjustment.

Tyche renders these signals as interactive charts: sample breakdowns, feature distributions, and per-example drill-down. This lets you diagnose generator quality visually rather than reading thousands of lines of test output.

For a lighter-weight check that runs as part of your test suite, [`#examine`](EXAMINE-generator-testing.md) lets you assert on generator quality — correctness, coverage, and distribution — without external tooling.
