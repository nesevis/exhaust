# Exhaust

[![Tests](https://github.com/nesevis/exhaust/actions/workflows/test.yml/badge.svg)](https://github.com/nesevis/exhaust/actions/workflows/test.yml)
[![Tests (Linux)](https://github.com/nesevis/exhaust/actions/workflows/test-linux.yml/badge.svg)](https://github.com/nesevis/exhaust/actions/workflows/test-linux.yml)
[![Tests (Windows)](https://github.com/nesevis/exhaust/actions/workflows/test-windows.yml/badge.svg)](https://github.com/nesevis/exhaust/actions/workflows/test-windows.yml)
[![Swift 6.3+](https://img.shields.io/badge/Swift-6.3%2B-orange)](https://swift.org)
[![SPM](https://img.shields.io/badge/Swift%20Package%20Manager-compatible-brightgreen)](https://swift.org/package-manager/)

[![Platforms](https://img.shields.io/badge/Platforms-macOS%2010.15%2B%20%7C%20iOS%2013%2B%20%7C%20tvOS%2013%2B%20%7C%20watchOS%206%2B%20%7C%20visionOS%201%2B%20%7C%20Linux%20%7C%20Windows-blue)](https://swift.org/platform-support/)

# Find the bugs you didn't think of.

Exhaust is a testing library for Swift. It integrates with Swift Testing and XCTest, runs in your existing test target, and executes in milliseconds.

Describe what your code should do, and Exhaust checks that claim across hundreds of inputs. When it finds a failure, it reduces it to the minimal counterexample.

```swift
@Test func mySortProducesAscendingOrder() {
    #exhaust(.int().array(length: 0...100)) { array in
        let result = mySort(array)
        let expected = array.sorted()
        #expect(result == expected)
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

Here, a concurrent spec test found a race in a non-atomic counter and reduced six operations to three:

```
Concurrent spec failure (found via random sampling)

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

Exhaust is built on [reflective generators](https://dl.acm.org/doi/10.1145/3607842): generators that are inspectable data structures rather than opaque closures. This foundation enables:

- **Edge cases first**: Before random sampling begins, Exhaust systematically tests the values that bugs cluster around. This catalogue of *problematic values* covers range limits and zero crossings, NaN, empty collections, timezone transitions, troublesome Unicode. These are combined pairwise. Because the generator's structure is inspectable, Exhaust can analyse its parameters and their domains; because it's replayable, these values can be targeted directly. Random sampling would take thousands of iterations to reach them by chance.

- **Minimal counterexamples**: When a property fails, Exhaust reduces the failing input to the minimal counterexample that still triggers the failure. Reduction works for every type without custom logic, and because the reducer understands how values relate to each other, it finds [smaller counterexamples](https://github.com/jlink/shrinking-challenge/blob/main/pbt-libraries/exhaust/README.md) than most other reducers.

- **Filters that don't time out**: Most similar libraries implement `.filter` by generating values and discarding those that fail the predicate. When valid values are sparse, this can appear to hang. Exhaust analyses the generator, measures which choices lead toward valid outputs, and reweights accordingly, a technique called Choice Gradient Sampling (CGS). While the generated values still have to pass the predicate, they are much more likely to after tuning the generator.

## Guides

New to property-based testing? **[Getting Started](https://nesevis.github.io/exhaust/documentation/exhaust/gettingstarted)** walks you from your first `#exhaust` call through generators, properties, and reading failure reports.

Want the model rather than a tutorial? **[Conceptual Overview](https://nesevis.github.io/exhaust/documentation/exhaust/conceptualoverview)** maps Exhaust's vocabulary and how the pieces fit together.

Testing a stateful system? **[State Machine Testing](https://nesevis.github.io/exhaust/documentation/exhaust/statemachinetesting)** covers generating command sequences, model-based oracles, and concurrent interleaving.

Using Swift Testing? **[Swift Testing Integration](https://nesevis.github.io/exhaust/documentation/exhaust/swifttestingintegration)** covers suite and test traits, how `#expect` and `#require` work inside property closures, and how failures surface in the test runner. Using XCTest? **[XCTest Compatibility](https://nesevis.github.io/exhaust/documentation/exhaust/xctestcompatibility)** covers what works, what doesn't, and the differences.

Exhaust's entry points are six macros. `#gen` builds generators; the rest consume them:

| Macro | Purpose |
|---|---|
| [`#gen(…)`](https://nesevis.github.io/exhaust/documentation/exhaust/buildinggenerators) | Build generators from primitives, structs, enums, and recursive types. |
| [`#gen(MyType.self, from:)`](https://nesevis.github.io/exhaust/documentation/exhaust/buildinggenerators#Synthesising-generators-from-Decodable-types) | Synthesise a generator from a `Decodable` type and example JSON or a `Codable` instance. |
| [`#exhaust(gen) {…}`](https://nesevis.github.io/exhaust/documentation/exhaust/propertytesting) | Test a property and report a minimal counterexample on failure. |
| [`#explore(gen, directions:) {…}`](https://nesevis.github.io/exhaust/documentation/exhaust/directedexploration) | Test a property with per-direction coverage guarantees. |
| [`#explore(gen, time:) {…}`](https://nesevis.github.io/exhaust/documentation/exhaust/coverageguidedfuzzing) | Coverage-guided fuzzing with a wall-clock time budget. |
| [`#execute(MySpec.self, …)`](https://nesevis.github.io/exhaust/documentation/exhaust/statemachinetesting) | Run a spec test against a stateful system. |
| [`#execute(MySpec.self, time:)`](https://nesevis.github.io/exhaust/documentation/exhaust/coverageguidedfuzzing#Fuzzing-a-state-machine-spec-with-execute(time:)) | Coverage-guided fuzzing over command sequences. |
| [`try #example(gen)`](https://nesevis.github.io/exhaust/documentation/exhaust/buildinggenerators#Generating-test-data-with-example) | Generate test data from your generators. |
| [`#examine(gen) {…}`](https://nesevis.github.io/exhaust/documentation/exhaust/generatortesting) | Test your generators: correctness, coverage, and distribution quality. |

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

- Swift 6.3+ (Xcode 26+)
- macOS 10.15+, iOS 13+, Mac Catalyst 13+, tvOS 13+, watchOS 6+, visionOS 1+, Linux, Windows
- Cooperative concurrent spec testing (`@StateMachine(.tasks)`) requires macOS 15+, iOS 18+, tvOS 18+, watchOS 11+, visionOS 2+ (no version requirement on Linux and Windows)
- Sequential and preemptive spec testing (`@StateMachine(.sequential)`, `@StateMachine(.threads)`) have no additional availability requirements

> [!NOTE]
> Exhaust is under active development. Some APIs may change before the 1.0 release.
