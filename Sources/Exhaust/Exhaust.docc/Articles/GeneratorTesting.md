# Testing your generators

A passing property test gives no signal about whether the generator explored its domain well or clustered in a narrow slice. `#examine` answers both correctness and coverage questions in a single call.

## What #examine checks

```swift
@Test func profileGeneratorIsHealthy() {
    #examine(profileGen)
}
```

`#examine` generates 200 samples (configurable), checks that each value roundtrips through the generator's backward pass (reflection), and records how well the generator covers its numeric ranges, branches, sequence lengths, and character space:

```
#examine: 200 samples, 0.115ms/sample
  Correctness: 200/200 reflection
  Unique: 200/200
  Coverage:
    UInt: [••••••••• ] 9/10 deciles (min: 18, max: 120, mean: 69.94)
    Sequences: [••••••••••] 10/10 deciles (min: 0, max: 100, mean: 50.35)
    Characters: 100% (of 95 code points)
    Characters: 3% (of 291108 code points)
  Filters:
    YourFile.swift:125: 85% (CGS, 35 discarded)
  Example:
    └── group
        ├── string(length: 18) 0...100
        ├── string(length: 83) 0...100
        └── choice(unsigned: 72) 0...120
```

> Tip:
> `10/10 deciles` means the generator spread across its entire range. `3/10` means it clustered and is worth investigating.
>
> Clustering usually means the scaling doesn't match the range width. Pass a `scaling:` parameter to adjust. For example, `.int(in: 0...1000)` defaults to no scaling (uniform), but `.int(in: 0...1000, scaling: .linear)` ramps from small values upward. Collection lengths accept the same parameter: `.array(length: 0...100, scaling: .constant)` disables ramping and samples the full length range uniformly from the start.

### Correctness checks

- **Reflection round-trip**: each generated value is reflected back through the generator and the recovered choice tree is compared against the generation tree. A mismatch indicates a bug in a `mapped` or `bound` backward function, or a lossy mapping (such as unordered sets or dictionaries where reflection cannot recover the original element order). Forward-only generators (those using `.map` or `.bind` without a backward direction) are reported. Synthesised generators skip this check automatically.
- **Replay determinism** (opt-in): when a trailing comparison closure is provided, each sample's choice tree is replayed twice and the two values are compared using the closure. A mismatch indicates non-determinism in the generator or its output type.
- **Filter health**: for filtered generators, the acceptance rate and CGS tuning effectiveness are reported.

### Providing a replay check

`#examine` operates on choice trees, not on your output values. By default it does not inspect generated values at all. When you want to verify that your type doesn't introduce non-determinism (for example, a stored `UUID()` or a non-deterministic closure inside `.map`), provide a trailing comparison closure:

```swift
@Test func profileGeneratorReplaysDeterministically() {
    #examine(profileGen, .budget(200)) { lhs, rhs in
        lhs.name == rhs.name && lhs.age == rhs.age
    }
}
```

Each sample is replayed twice from its choice tree and the two values are passed to your closure. A `false` return records a failure. When provided, the report includes replay statistics in the correctness line:

```
Correctness: 200/200 reflection, 200/200 replay
```

Without the closure, no replay determinism check runs and the replay column is omitted.

### Coverage metrics

- **Numeric ranges**: how many deciles of each numeric parameter's range were hit.
- **Branches**: the proportion of `oneOf` branches that appeared in the sample.
- **Sequence lengths**: how well the generator covered its allowed length ranges.
- **Character space**: the proportion of the character set that appeared in string generators.

## Asserting on coverage

The returned `ExamineReport` exposes coverage metrics as assertable properties, so you can enforce quality thresholds on generator fixtures:

```swift
@Test func profileGeneratorCoversItsRange() {
    let report = #examine(profileGen, .budget(500))
    #expect(report.numericCoverage.allSatisfy { $0.decilesCovered >= 7 })
    #expect(report.branchCoverage >= 0.9)
}
```

Correctness checks (reflection round-trip, filter health) can fail the test. Coverage metrics populate the report but never fail on their own. Assert on the properties that matter to you.

## Settings

| Setting | Default | Effect |
|---|---|---|
| `.budget(N)` | 200 | Number of samples to generate and validate. Takes a plain `Int`, unlike the other macros' budgets. |
| `.replay(seed)` | — | Deterministic validation run. Accepts a raw `UInt64` or an encoded seed string. |
| `.severity(.warning)` | `.error` | Default severity for all checks. `.error` fails the test, `.warning` reports without failing, `.silent` only populates the report. |
| `.reflection(.warning)` | inherits | Severity override for reflection round-trip failures. |
| `.filterHealth(.warning)` | inherits | Severity override for filter validity failures (a validity rate below 5% fails the check). |
| `.suppress(.issueReporting)` | — | Silences issue reporting; assert on the returned `ExamineReport` instead. `.suppress(.logs)` and `.suppress(.all)` also available. |
