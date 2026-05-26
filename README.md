# Exhaust

[![Tests](https://github.com/nesevis/exhaust/actions/workflows/test.yml/badge.svg)](https://github.com/nesevis/exhaust/actions/workflows/test.yml)
[![Swift 6.2+](https://img.shields.io/badge/Swift-6.2%2B-orange)](https://swift.org)
[![SPM](https://img.shields.io/badge/Swift%20Package%20Manager-compatible-brightgreen)](https://swift.org/package-manager/)

[![Platforms](https://img.shields.io/badge/Platforms-macOS%2010.15%2B%20%7C%20iOS%2013%2B%20%7C%20tvOS%2013%2B%20%7C%20watchOS%206%2B%20%7C%20visionOS%201%2B-blue)](https://developer.apple.com)

# Find the bugs you didn't think of.

Exhaust is a testing library for Swift. It integrates with Swift Testing and XCTest, runs in your existing test target, and executes in milliseconds.

Describe what your code should do, and Exhaust checks that claim across hundreds of inputs. When it finds a failure, it reduces it to the smallest counterexample.

```swift
@Test func mySortProducesAscendingOrder() {
    #exhaust(.int().array(length: 0...100)) { array in
        let sorted = mySort(array)
        #expect(sorted == sorted.sorted())
    }
}
```

```
Counterexample:
  [
    [0]: 1,
    [1]: 0
  ]

Property invoked: 31 times

Reproduce: .replay("8SYM3KW758FWP-3")
```

Exhaust found an input that `mySort` fails to sort and reduced it to two elements: the shortest array that demonstrates the bug.

For stateful systems, which is to say those where bugs emerge from sequences of operations rather than within single function calls, Exhaust generates command sequences and checks invariants after each step. 

Here, a concurrent contract test found a race in a non-atomic counter and reduced six operations to three:

```
Concurrent contract failure (found via random sampling)

Reduced from 6 to 3 commands.

Sequential prefix:
  1. increment

Lane A:
  1A. increment

Lane B:
  1B. increment

Execution trace:
  1. increment (prefix)
  2. 1A increment (started)
  3. 1A increment (suspended)
  4. 1B increment (completed) ✗ invariant 'matchesModel'

Reproduce: .replay("7MK2N9-4")
```

The reducer drove the first `increment` into the sequential prefix, leaving two concurrent increments as the minimal race.

## What makes Exhaust different

Exhaust is built on [reflective generators](https://dl.acm.org/doi/10.1145/3607842): generators as inspectable data structures rather than opaque closures. The library runs them forward to generate values, backward to reflect known values, and replays them for deterministic reproduction. Three things follow from this foundation:

- **Edge cases first**: Before random sampling begins, Exhaust systematically tests values that bugs cluster around: range boundaries, zero crossings, NaN, empty collections, timezone transitions, funky unicode. These are combined in pairwise order. Random sampling would take thousands of iterations to reach these values by chance.

- **Minimal counterexamples**: When a property fails, Exhaust reduces the failing input to the smallest counterexample that still triggers the failure. Reduction operates on the generator's recorded choices rather than the output value, so it works for every type without custom reduction logic. Because the generator's structure is inspectable, the reducer understands how values relate to each other — which are independent, which are entangled through dependencies — and finds [smaller counterexamples](https://github.com/jlink/shrinking-challenge/blob/main/pbt-libraries/exhaust/README.md) than most other reducers.

- **Filters that don't time out**: Most similar libraries implement `.filter` by generating values and discarding those that fail the predicate. When valid values are sparse, this can appear to hang. Exhaust analyses the generator, measures which choices lead toward valid outputs, and reweights accordingly, a technique called Choice Gradient Sampling (CGS).

## Guides

New to property-based testing? **[Getting Started](docs/GETTING_STARTED.md)** walks you from your first `#exhaust` call through generators, properties, and reading failure reports.

Testing a stateful system? **[Contract Testing](docs/CONTRACT_TESTING.md)** covers generating command sequences, model-based oracles, and concurrent interleaving.

Exhaust's entry points are five macros. `#gen` builds generators; the rest consume them:

| Macro | Purpose |
|---|---|
| [`#gen(…)`](docs/GEN.md) | Build generators from primitives, structs, enums, and recursive types. |
| [`#exhaust(gen) {…}`](docs/EXHAUST.md) | Test a property and report a minimal counterexample on failure. |
| [`#exhaust(Spec.self, …)`](docs/EXHAUST.md#contract-invocation) | Run a contract test against a stateful system. |
| [`#explore(gen, directions:) {…}`](docs/EXPLORE.md) | Test a property with per-direction coverage guarantees. |
| [`#example(gen)`](docs/GEN.md#example) | Generate test data from your generators. |
| [`#examine(gen)`](docs/EXAMINE.md) | Test your generators: correctness, coverage, and distribution quality. |

## Installation

Add Exhaust to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/nesevis/exhaust.git", from: "0.1.0"),
]
```

Then add it as a dependency of your test target:

```swift
.testTarget(
    name: "MyTests",
    dependencies: [.product(name: "Exhaust", package: "exhaust")]
)
```

## Requirements

- Swift 6.2+ (Xcode 26+)
- macOS 10.15+, iOS 13+, Mac Catalyst 13+, tvOS 13+, watchOS 6+, visionOS 1+
- Cooperative concurrent contract testing (`@Contract` + `.concurrent`) requires macOS 15+, iOS 18+, tvOS 18+, watchOS 11+, visionOS 2+
- Preemptive concurrent contract testing (`@ConcurrentContract`) has no additional availability requirements

> [!NOTE]
> Exhaust is under active development. Some APIs may change before the 1.0 release.
