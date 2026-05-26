# Testing your generators

A passing property test gives no signal about whether the generator explored its domain well or clustered in a narrow slice. `#examine` answers both correctness and coverage questions in a single call.

## What `#examine` checks

```swift
@Test func personGeneratorIsHealthy() {
    #examine(personGen)
}
```

`#examine` generates 200 samples (configurable), checks that each value roundtrips through reflection and replays deterministically. Additionally it records quantitative data about how well the generator covers its numeric ranges, branches, sequence lengths, and character space:

```
#examine: 200 samples, 0.064ms/sample
  Correctness: 200/200 reflection, 200/200 replay
  Unique: 200/200
  Coverage:
    UInt: [••••••••• ] 9/10 deciles (min: 20, max: 120, mean: 69.19)
    Sequences: [••••••••••] 10/10 deciles (min: 0, max: 95, mean: 26.07)
    Characters: 100% (of 95 code points)
    Characters: 2% (of 291108 code points)
  Filters:
    YourFile.swift:125: 83% (CGS, 40 discarded)
  Example:
    └── group
        ├── string(length: 42) 0...55
        ├── string(length: 2) 0...55
        └── choice(unsigned: 81) 0...120
```

> [!Tip]
> `10/10 deciles` means the generator spread across its entire range. `3/10` means it clustered and is worth investigating.
>
> These types of issues can usually be resolved by changing the `scaling` parameter of your generator.

### Correctness checks

- **Reflection round-trip**: each generated value is reflected back through the generator and the recovered choices are compared against the originals. A mismatch indicates a bug in a `mapped` or `bound` backward function.
- **Replay determinism**: the recorded choices are replayed and the resulting value is compared against the original. A mismatch indicates non-determinism in the generator, or a lossy mapping (such as unordered sets or dictionaries).
- **Filter health**: for filtered generators, the acceptance rate and CGS tuning effectiveness are reported.

### Coverage metrics

- **Numeric ranges**: how many deciles of each numeric parameter's range were hit.
- **Branches**: the proportion of `oneOf` branches that appeared in the sample.
- **Sequence lengths**: how well the generator covered its allowed length ranges.
- **Character space**: the proportion of the character set that appeared in string generators.

## Asserting on coverage

The returned `ExamineReport` exposes coverage metrics as assertable properties, so you can enforce quality thresholds on generator fixtures:

```swift
@Test func personGeneratorCoversItsRange() {
    let report = #examine(personGen, .samples(500))
    #expect(report.numericCoverage.allSatisfy { $0.decilesCovered >= 7 })
    #expect(report.branchCoverage >= 0.9)
}
```

Correctness checks (reflection roundtrip, replay determinism, filter health) can fail the test. Coverage metrics populate the report but never fail on their own. Assert on the properties that matter to you.
