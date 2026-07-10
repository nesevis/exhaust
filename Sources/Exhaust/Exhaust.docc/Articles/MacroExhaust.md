# \#exhaust

Test a property across generated values and report a minimal counterexample on failure.

## Overview

`#exhaust` runs a property closure against hundreds of generated inputs in two phases: screening of problematic values (pairwise), then random sampling. The first failure is reduced to a minimal counterexample.

```swift
#exhaust(personGen, .budget(.thorough)) { person in
    #expect(person.age >= 0)
}
```

The property closure returns `Bool` (true means pass) or `Void` with `#expect`/`#require` assertions. Async closures are supported with `await`.

| Parameter | Description |
|---|---|
| `gen` | The generator to draw inputs from. |
| `reflecting:` | A concrete value to reduce instead of searching. Skips screening and sampling. |
| `settings` | Variadic ``PropertySettings`` values: budget, replay, parallelism, suppression. |
| `property` | Closure checked against each generated value. |

Returns the reduced counterexample on failure, or `nil` if all cases pass.

For the full guide, see <doc:PropertyTesting>.
