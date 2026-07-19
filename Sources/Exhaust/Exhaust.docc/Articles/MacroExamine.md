# \#examine

Validate a generator's correctness and measure how well it explores its domain.

## Overview

`#examine` generates samples, checks that each value round-trips through reflection, and reports coverage of numeric ranges, branches, sequence lengths, and character space.

```swift
let report = #examine(personGen, .samples(500))
#expect(report.numericCoverage.allSatisfy { $0.decilesCovered >= 7 })
```

| Parameter | Description |
|---|---|
| `gen` | The generator to validate. |
| `settings` | Variadic ``ExamineSettings`` values: budget, severity, replay, suppression. |
| `replayCheck` | Optional trailing closure comparing two replayed values for determinism. |

Returns an ``ExamineReport`` with correctness results and coverage metrics.

For the full guide, see <doc:GeneratorTesting>.
