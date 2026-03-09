# Exhaust

[![Swift 6.2+](https://img.shields.io/badge/Swift-6.2%2B-orange)](https://swift.org)
[![Platforms](https://img.shields.io/badge/Platforms-macOS%2026%20%7C%20iOS%2013%20%7C%20tvOS%2013%20%7C%20watchOS%206-blue)](https://developer.apple.com)
[![SPM](https://img.shields.io/badge/Swift%20Package%20Manager-compatible-brightgreen)](https://swift.org/package-manager/)

## Why `#expect` when you can `#exhaust`?

Exhaust is a property-based testing framework for Swift. Instead of writing individual test cases by hand, you describe the rules your code must obey and let Exhaust find the violations. It tests in two phases — combinatorial analysis of boundary values and parameter interactions first, then random sampling — so edge cases are covered systematically rather than by luck. When a failure is found, Exhaust automatically reduces it to the smallest possible counterexample, usually within 100ms.

Test values against properties with `#exhaust(generator) { value in Bool }`, or test stateful systems with `@Contract` — define commands, invariants, and postconditions, and Exhaust generates minimal failing sequences of interactions.

```swift
@Test func arraySortIsIdempotent() {
    #exhaust(.int().array(length: 0...100)) { array in
        array.sorted() == array.sorted().sorted()
    }
}
```

If the property fails, Exhaust finds a counterexample and automatically reduces it to its minimal form. Here's what that looks like:

```
Property failed (iteration 3/100, seed 8837201)
  array.sorted() == array.sorted().sorted()

Counterexample:
  [1, 0]

Reduction diff:
  [
-   3,
-   1,
-   2,
-   5,
+   1,
    0,
  ]

Property invoked: 47 times

Reproduce: .replay(8837201)
```

Exhaust found a five-element counterexample and reduced it to two elements — the minimal case that violates the property.

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
    dependencies: ["Exhaust"]
)
```

## Building Generators

The `#gen` macro builds generators from built-in primitives:

```swift
// Primitives
let ints = #gen(.int(in: -100...100))
let bools = #gen(.bool())
let strings = #gen(.string(length: 1...50))

// Collections
let arrays = #gen(.int().array(length: 0...10))
let sets = #gen(.int().set(count: 1...5))

// Choice
let direction = #gen(.oneOf(.just("north"), .just("south"), .just("east"), .just("west")))
```

Additional generators are available for dates, UUIDs, SIMD vectors, decimals, and more.

## Composing Generators

The `#gen` macro composes multiple generators and automatically synthesizes a bidirectional mapping:

```swift
struct Person: Equatable {
    let name: String
    let age: Int
}

let personGen = #gen(.string(length: 1...20), .int(in: 0...120)) { name, age in
    Person(name: name, age: age)
}
```

## Running Properties

`#exhaust` tests a property across generated values and reports a minimal counterexample on failure:

```swift
#exhaust(personGen) { person in
    person.age >= 0 && person.age <= 120
}
```

Structured coverage runs first, testing boundary values and parameter interactions systematically. Random sampling follows.

Configure behavior with settings:

| Setting | Default | Effect |
|---|---|---|
| `.maxIterations(n)` | 100 | Random sampling budget |
| `.coverageBudget(n)` | 100 | Structured coverage budget |
| `.coverageBudget(.fast/.slow)` | `.fast` | Reduction thoroughness |
| `.randomOnly` | off | Skip structured coverage |
| `.replay(seed)` | — | Deterministic reproduction |

## Reflecting and Reducing Known Values

Sometimes you already have a failing value — from a bug report, a log, or a test fixture — and want Exhaust to reduce it. The `.reflecting` setting skips generation, reflects your value through the generator, and reduces it:

```swift
@Test func minimizeBugReport() {
    let gen = #gen(.int().array(length: 3...30))
    let fromBugReport = [1337, 80085, 69, 67]

    #exhaust(gen, .reflecting(fromBugReport)) {
        Set($0).count < 3
    }
    // Reduces to [0, -1, 1]
}
```

Exhaust decomposes the value into the generator choices that could have produced it, then reduces those choices to find the minimal counterexample. This works with any reflective generator, including composed ones — no custom reduction logic required.

## Quick Extraction

Use `#extract` to generate values outside of property tests — useful for prototyping and snapshot tests:

```swift
let person = #extract(personGen)
let people = #extract(personGen, count: 100, seed: 42)
```

## Filters and Classification

Add validity constraints with `.filter`. Exhaust selects a strategy automatically based on generator structure:

```swift
let evenGen = #gen(.int().filter { $0 % 2 == 0 })
```

Track value distributions with `.classify`:

```swift
let classified = #gen(.int().classify(
    ("negative", { $0 < 0 }),
    ("zero",     { $0 == 0 }),
    ("positive", { $0 > 0 })
))
```

## Validating Generators

Verify that a generator's reflection and replay are working correctly with `#examine`:

```swift
@Test func personGeneratorIsHealthy() {
    #examine(personGen)
}
```

`#examine` generates 200 samples (configurable), checks that each value round-trips through reflection and replays deterministically, and reports failures as test issues.

## Contract Testing

`@Contract` tests stateful systems by generating random sequences of commands and checking that invariants hold after every step. Define your system under test, the commands that operate on it, and the rules it must obey — Exhaust generates command sequences, finds violations, and reduces them to minimal failing traces.

```swift
@Contract
struct CounterSpec {
    @Model var expected: Int = 0
    @SUT var counter = Counter(capacity: 5)

    @Invariant
    func valueMatchesModel() -> Bool {
        counter.value == expected
    }

    @Command(weight: 3)
    mutating func increment() throws {
        expected = (expected + 1) % 5
        counter.increment()
    }

    @Command(weight: 1)
    mutating func reset() throws {
        expected = 0
        counter.reset()
    }
}
```

Run the contract with `#exhaust`:

```swift
@Test func counterObeysSpec() {
    #exhaust(CounterSpec.self, .sequenceLength(3...10))
}
```

Exhaust generates sequences of `increment` and `reset` commands, executes them against the `Counter`, and checks `valueMatchesModel` after each step. If the counter diverges from the model, the trace is reduced to the shortest command sequence that reproduces the failure.

### Markers

| Marker | Purpose |
|---|---|
| `@SUT` | The system under test. |
| `@Model` | Optional reference state to compare against the SUT. |
| `@Command(weight:, generators...)` | An operation on the SUT. Weight controls how often it is chosen. Generator arguments produce the command's parameters. |
| `@Invariant` | A boolean check run after every command. |

Commands can also assert postconditions inline with `try check(condition, "message")`, and skip inapplicable states with `throw skip()`.

### Settings

| Setting | Default | Effect |
|---|---|---|
| `.sequenceLength(range)` | `3...10` | Number of commands per test iteration. |

## How It Works

Generators in Exhaust are inspectable data structures, not opaque closures. This means the framework can run them forward to generate values, backward to decompose a value into the choices that produced it, and replay to reproduce results deterministically. Automatic test case reduction works by reducing the recorded choices rather than the output value, so reduction is type-agnostic and preserves generator invariants without any custom reduction logic.

## Requirements

- Swift 6.2+
- macOS 26+, iOS 13+, tvOS 13+, watchOS 6+
