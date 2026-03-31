# Exhaust

[![Swift 6.2+](https://img.shields.io/badge/Swift-6.2%2B-orange)](https://swift.org)
[![Platforms](https://img.shields.io/badge/Platforms-macOS%2015%20%7C%20iOS%2018%20%7C%20Mac%20Catalyst%2018%20%7C%20tvOS%2018%20%7C%20visionOS%202%20%7C%20watchOS%2011-blue)](https://developer.apple.com)
[![SPM](https://img.shields.io/badge/Swift%20Package%20Manager-compatible-brightgreen)](https://swift.org/package-manager/)

## Why `#expect` when you can `#exhaust`?

Exhaust is a property-based testing framework for Swift. Instead of writing individual test cases by hand, you describe the rules your code must obey and let Exhaust find the violations.

- **Structured coverage** — boundary values and parameter interactions are tested systematically before random sampling begins, so edge cases are covered by design rather than luck.
- **Automatic reduction** — when a failure is found, Exhaust reduces it to the smallest possible counterexample, typically within 100ms. No custom shrink functions needed.
- **Contract testing** — generate random sequences of commands against a stateful system and verify that invariants hold after every step.
- **Inspectable generators** — generators are data structures, not opaque closures. The framework runs them forward to generate, backward to decompose, and replays them for deterministic reproduction.

Exhaust works in two modes:

- **Property tests** — generate values and check that a rule holds: `#exhaust(generator) { value in Bool }`.
- **Contract tests** — generate sequences of interactions against a stateful system and verify that nothing breaks: `#exhaust(MyContract.self, commandLimit: 20)`.

```swift
@Test func arraySortIsIdempotent() {
    #exhaust(.int().array(length: 0...100)) { array in
        array.sorted() == array.sorted().sorted()
    }
}
```

If the property fails, Exhaust finds a counterexample and automatically reduces it to its minimal form. Here's what that looks like:

```
Property failed (iteration 3/200, seed 8DZR69)
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

Reproduce: .replay("8DZR69")
```

Exhaust found a five-element counterexample and reduced it to two elements — the minimal case that violates the property.

## Table of Contents

- [Installation](#installation)
- [Macros at a Glance](#macros-at-a-glance)
- [Building Generators](#building-generators)
- [Composing Generators](#composing-generators)
- [Recursive Generators](#recursive-generators)
- [Running Properties](#running-properties)
  - [Using `#expect` and `#require`](#using-expect-and-require)
  - [Run Statistics](#run-statistics)
- [Reflecting and Reducing Known Values](#reflecting-and-reducing-known-values)
- [Quick Examples](#quick-examples)
- [Filters and Classification](#filters-and-classification)
- [Validating Generators](#validating-generators)
- [Contract Testing](#contract-testing)
- [How It Works](#how-it-works)
- [Requirements](#requirements)

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

### Macros at a Glance

| Macro | Purpose |
|---|---|
| `#gen(...)` | Build a generator from primitives, with automatic bidirectional mapping |
| `#exhaust(gen) { ... }` | Test a property and report a minimal counterexample on failure |
| `#exhaust(Spec.self, ...)` | Run a contract test against a stateful system |
| `#example(gen)` | Generate values outside of tests — for prototyping and snapshots |
| `#examine(gen)` | Validate that a generator round-trips correctly through reflection and replay |

## Building Generators

The `#gen` macro is the entry point for building generators. It wraps built-in primitives into reflective generators that Exhaust can inspect, replay, and reduce:

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

> [!Note]
> Additional generators are available for dates, UUIDs, SIMD vectors, decimals, and more.

## Composing Generators

Real code doesn't test integers in isolation — you need structured values. The `#gen` macro composes multiple generators and attempts to automatically synthesize a bidirectional mapping:

```swift
struct Person: Equatable {
    let name: String
    let age: Int
}

let personGen = #gen(.string(length: 1...20), .int(in: 0...120)) { name, age in
    Person(name: name, age: age)
}
```

## Recursive Generators

Some domains are naturally recursive — trees, nested JSON, abstract syntax trees. `.recursive` lets you define generators that reference themselves, with a depth limit to keep things finite:

```swift
indirect enum JSONValue: Equatable {
    case null
    case int(Int)
    case array([JSONValue])
}

let jsonGen: ReflectiveGenerator<JSONValue> = .recursive(base: .null, maxDepth: 5) { recurse, remaining in
    .oneOf(weighted:
        (2, .just(.null)),
        (2, ReflectiveGenerator<Int>.int(in: 0...99).map { JSONValue.int($0) }),
        (Int(remaining), recurse().array(length: 0...3).map { JSONValue.array($0) })
    )
}
```

At each level, `remaining` counts down from `maxDepth`, and `recurse()` produces a generator for the next level. When depth is exhausted, only the base case is used. The `weighted` parameter biases toward leaves so that generated trees stay manageable, while `remaining` naturally reduces branching as recursion deepens.

Recursive generators are fully transparent to reflection and reduction — Exhaust can shrink a deeply nested tree down to its minimal failing subtree.

## Running Properties

`#exhaust` tests a property across generated values and reports a minimal counterexample on failure:

```swift
#exhaust(personGen) { person in
    person.age >= 0 && person.age <= 120
}
```

Testing happens in two phases. First, structured coverage analyzes the generator's domain and systematically tests boundary values and parameter interactions — this catches the edge cases that random sampling would need thousands of iterations to find. Then random sampling explores the remaining space. If the generator's total domain fits within the coverage budget, Exhaust performs exhaustive enumeration and skips the random phase entirely.

Configure behavior with settings:

| Setting | Default | Effect |
|---|---|---|
| `.budget(.expedient)` | default | 200 coverage rows, 200 random samples, fast reduction. |
| `.budget(.expensive)` | — | 500 coverage rows, 500 random samples, fast reduction. |
| `.budget(.exorbitant)` | — | 2000 coverage rows, 2000 random samples, slow reduction. |
| `.budget(.custom(...))` | — | Explicit values for coverage, sampling, and reduction budgets. |
| `.randomOnly` | off | Skip structured coverage, use only random sampling. |
| `.replay(seed)` | — | Deterministic reproduction of a specific run. Accepts a raw `UInt64` or a Crockford Base32 string (for example `.replay("8DZR69")`). |
| `.reflecting(value)` | — | Skip generation; reflect the given value and reduce it (see [Reflecting and Reducing Known Values](#reflecting-and-reducing-known-values)). |
| `.visualize` | off | Prints the choice tree before and after reduction as a Unicode visualization — useful for understanding how Exhaust represents and shrinks your generator. |
| `.onReport(closure)` | — | Registers a closure that receives an `ExhaustReport` after the test completes. See [Run Statistics](#run-statistics). |

### Using `#expect` and `#require`

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

When the closure contains `#expect`, `#require`, or multiple statements, `#exhaust` automatically switches to a mode that treats any assertion failure or thrown error as a counterexample. During reduction, assertion failures are suppressed so that test output stays clean. Once the minimal counterexample is found, the closure runs one final time with native `#expect`/`#require` reporting, so the failure message you see in the test log describes the reduced value.

`#require` works for optional unwrapping:

```swift
@Test func parsedValueIsPositive() {
    #exhaust(#gen(.string(length: 1...5, alphabet: .decimalDigits))) { digits in
        let number = try #require(Int(digits))
        #expect(number > 0)
    }
}
```

You can also throw errors directly — any thrown error counts as a failure:

```swift
#exhaust(gen) { value in
    if value.isInvalid {
        throw ValidationError()
    }
}
```

The `Bool`-returning form still works. `#exhaust` decides which path to use based on the closure body: single-expression closures that return `Bool` use the predicate path, everything else uses the assertion path.

### Run Statistics

The `.onReport` setting delivers an `ExhaustReport` with timing and invocation data for each phase of the test run. It includes per-phase wall-clock times (coverage, generation, reduction, reflection), total property invocations, materialization counts during reduction, and per-encoder probe breakdowns. Use it to understand where time is spent and whether coverage or reduction budgets need tuning.

```swift
#exhaust(gen, .onReport { report in
    print(report.phaseSummary)
}) { value in
    value.isValid
}
```

## Reflecting and Reducing Known Values

Sometimes you already have a failing value — from a bug report, a production log, or a test fixture — and want to find the simplest version that still fails. The `.reflecting` setting skips generation, reflects your value through the generator, and reduces it:

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

Exhaust decomposes the value into the generator choices that could have produced it, then reduces those choices to find the minimal counterexample. This works with any generator, including composed ones — no custom reduction logic required.

### `mapped` and `bound`

Reflection requires that transformations be reversible. `.map` is forward-only — Exhaust can still generate and reduce with it, but it can't reflect a concrete value backward through a `.map` closure. When you need full bidirectional support, use `mapped(forward:backward:)` instead:

```swift
let celsius = #gen(.double(in: -273.15...1000.0))
    .mapped(
        forward: { $0 * 9/5 + 32 },
        backward: { ($0 - 32) * 5/9 }
    )
```

The `#gen` macro uses `mapped` automatically when it can synthesize a backward mapping — for structs it extracts properties by label, and for enum cases it uses pattern matching. For custom transformations where Exhaust can't infer the reverse, provide it explicitly.

`bound` is the bidirectional equivalent of `.bind` (`.flatMap`). Note that `.bind` is less commonly bidirectional than `.map` — the dependent generator often can't be reversed — but when it is, prefer `bound` for the same reasons.

### Reflectable vs. Forward-Only

| Capability | Reflectable (`mapped`/`bound`) | Forward-only (`.map`/`.bind`) |
|---|---|---|
| `#exhaust` (generation + reduction) | Yes | Yes |
| `#exhaust(..., .reflecting(value))` | Yes | No |
| `#example` | Yes | Yes |
| `#examine` (round-trip validation) | Yes | No |
| Structured coverage | Yes | Yes |

Generators built entirely from `#gen` primitives and `mapped`/`bound` are fully reflectable. Adding a `.map` or `.bind` makes the generator forward-only at that point — generation and reduction still work, but reflection from a concrete value cannot pass backward through the forward-only closure.

## Quick Examples

Use `#example` to generate values outside of property tests — useful for prototyping and snapshot tests:

```swift
let person = #example(personGen)
let people = #example(personGen, count: 100, seed: 42)
```

## Filters and Classification

Add validity constraints with `.filter`:

```swift
let evenGen = #gen(.int().filter { $0 % 2 == 0 })
```

Most property-based testing frameworks implement filters as rejection sampling — generate a value, test the predicate, throw it away and retry if it fails. This works when the valid region is large, but becomes impractical when valid values are sparse (balanced trees, well-formed inputs, values satisfying multiple constraints).

Exhaust takes a different approach by default. Because generators are inspectable data structures, the framework can analyze the generator's branching points and measure how often each branch leads to a value that satisfies the predicate. It then reweights the branches to favor valid outputs before generation begins — a technique called Choice Gradient Sampling (CGS). The result is that filtered generators produce valid values efficiently even when the acceptance rate under rejection sampling would be vanishingly small.

You can select the strategy explicitly:

```swift
// Default: generator tuning via CGS (same as .auto)
let balanced = bstGen.filter { $0.isBalanced }

// Pure rejection sampling — no tuning, just retry
let small = #gen(.int().filter(.rejectionSampling) { $0 < 10 })
```

| Strategy | Behavior |
|---|---|
| `.auto` | Default. Currently selects `.choiceGradientSampling`. |
| `.rejectionSampling` | Generate-and-discard. Simple and predictable, but slow when valid values are sparse. |
| `.probeSampling` | Probes each branching point to measure how often each choice satisfies the predicate, then biases weights before generation begins. One-shot analysis. |
| `.choiceGradientSampling` | Online derivative sampling that conditions branch weights on upstream choices, with fitness sharing to maintain output diversity. Best for recursive generators. |

Track value distributions with `.classify`:

```swift
let classified = #gen(.int().classify(
    ("negative", { $0 < 0 }),
    ("zero",     { $0 == 0 }),
    ("positive", { $0 > 0 })
))
```

## Validating Generators

A subtle bug in a generator — a backward mapping that doesn't round-trip, or a replay that produces a different value — can cause confusing failures that look like property violations but are really generator issues. This is a common source of frustration with property-based testing frameworks. `#examine` catches these problems early:

```swift
@Test func personGeneratorIsHealthy() {
    #examine(personGen)
}
```

`#examine` generates 200 samples (configurable), checks that each value round-trips through reflection and replays deterministically, and reports failures as test issues.

## Contract Testing

Property tests verify pure functions, but much of real-world code is stateful — databases, caches, network sessions, UI controllers. Contract testing generates random sequences of operations against a stateful system and checks that invariants hold after every step. When something breaks, Exhaust reduces the trace to the shortest command sequence that reproduces the failure.

Define your system under test, the commands that operate on it, and the rules it must obey:

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
    #exhaust(CounterSpec.self, commandLimit: 10)
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

### Bundles

Some commands need to reference entities created by earlier commands — deleting a user that was previously created, or closing an account that was previously opened. `Bundle<T>` provides this capability:

```swift
@Contract
struct DatabaseSpec {
    let userIDs = Bundle<UserID>()

    @Command(weight: 3, #gen(.string(length: 1...20)), #gen(.int(in: 18...65)))
    mutating func createUser(name: String, age: Int) {
        let id = db.createUser(name: name, age: age)
        userIDs.add(id)
    }

    @Command(weight: 2)
    mutating func deleteUser() {
        guard let id = userIDs.draw(at: 0) else { throw skip() }
        db.deleteUser(id: id)
    }
}
```

`add()` stores a value in the bundle. `draw(at:)` retrieves one without removing it, and `consume(at:)` retrieves and removes it for exclusive-use patterns. When the bundle is empty, `draw` and `consume` return `nil` — use `throw skip()` to indicate the command's precondition isn't met.

### Async Contracts

When your system under test is an actor, uses `async` methods, or interacts with async APIs, mark the relevant `@Command` or `@Invariant` methods as `async`. The macro detects this and generates an `AsyncContractSpec` conformance automatically — no separate macro or annotation needed.

```swift
@Contract
struct AccountSpec {
    @Model var expected: Decimal = 0
    @SUT var account = BankAccount()

    @Invariant
    func balanceMatches() async -> Bool {
        await account.balance == expected
    }

    @Command(weight: 3, #gen(.int(in: 1...1000)))
    mutating func deposit(amount: Int) async throws {
        expected += Decimal(amount)
        await account.deposit(amount)
    }

    @Command(weight: 1)
    mutating func close() async throws {
        guard expected > 0 else { throw skip() }
        expected = 0
        await account.close()
    }
}
```

Run it the same way — the test function must be `async`:

```swift
@Test func accountBehavior() async {
    await #exhaust(AccountSpec.self, commandLimit: 15)
}
```

Sync and async commands can be mixed freely in the same contract.

### Settings

Contract tests accept the same settings as `#exhaust` (`.budget`, `.replay`, `.randomOnly`), plus:

| Setting | Default | Effect |
|---|---|---|
| `commandLimit:` | (required) | Maximum number of commands per test iteration. |
| `.argumentAwareCoverage` | off | Include command argument values in coverage domain construction. |

## How It Works

Generators in Exhaust are inspectable data structures, not opaque closures. This is the key design decision that powers everything else — structured coverage, automatic reduction, reflection, and deterministic replay all fall out of being able to inspect and manipulate generator structure.

The framework supports three execution modes:

- **Generation (forward)** — the generator is interpreted to produce a value, recording every choice made along the way. This is the normal path during test execution.
- **Reflection (backward)** — given a concrete value, the generator is run in reverse to recover the choices that could have produced it. This is what powers `.reflecting` and automatic reduction without custom shrink functions.
- **Replay** — a recorded sequence of choices is fed back to reproduce the exact same value, powering deterministic reproduction via `.replay(seed)`.

Reduction operates on the recorded sequences and trees of choices rather than the output value, making it type-agnostic and preserving all generator invariants.

## Requirements

- Swift 6.2+
- macOS 15+, iOS 18+, Mac Catalyst 18+, tvOS 18+, visionOS 2+, watchOS 11+
