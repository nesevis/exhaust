# \#example

Generate test data from a generator without running a property test.

## Overview

`#example` produces values from a generator for use as test fixtures, prototypes, or snapshot inputs. A single value generates at size 50 on the 0-to-100 scale. A seed from a failure report reproduces the exact value that iteration generated.

```swift
let person = try #example(personGen)
let people = try #example(personGen, count: 100, seed: 42)
let failing = try #example(personGen, seed: "5QF8M2-3")
```

| Parameter | Description |
|---|---|
| `gen` | The generator to produce values from. |
| `count` | Number of values to generate (array overload). |
| `seed` | Optional ``ReplaySeed`` for deterministic output. Accepts a raw `UInt64` or a string from a failure report. |

Returns a single value or an array of values.

For more context, see <doc:BuildingGenerators#Generating-test-data-with-example>.
