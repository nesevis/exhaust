# \#examine

Validate a generator's correctness and measure how well it explores its domain.

## Overview

`#examine` generates samples, checks reflection unless configured to skip it, and reports coverage of numeric ranges, branches, sequence lengths, and character space.

```swift
let report = #examine(personGen, .samples(500))
#expect(report.numericCoverage.allSatisfy { $0.decilesCovered >= 7 })
```

| Parameter | Description |
|---|---|
| `gen` | The generator to validate. |
| `settings` | Variadic ``ExamineSettings`` values: sample count, reflection policy, default and per-check severity, replay, and suppression. |
| `replayCheck` | Optional trailing closure comparing two replayed values for determinism. |

Returns an ``ExamineReport`` with correctness results and coverage metrics.

Use `.skipReflection` when a generator intentionally cannot recover choice trees from its output:

```swift
#examine(dictionaryGen, .skipReflection) { first, second in
    first == second
}
```

Generation, coverage, filter health, and the optional replay check still run. `.reflection(.silent)` runs reflection and retains its failures in the report while suppressing issue output.

For the full guide, see <doc:GeneratorTesting>.
