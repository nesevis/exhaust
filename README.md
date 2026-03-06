# Exhaust

Property-based testing for Swift, built on reflective generators.

Exhaust aims to make property-based testing — inclusive of automatic test case reduction — as fast and simple to write as a unit test.

```swift
@Test func arraySortIsIdempotent() {
    #exhaust(.int().array(length: 0...100)) { array in
        array.sorted() == array.sorted().sorted()
    }
}
```

If the property fails, Exhaust automatically reduces the counterexample to its minimal reproducible form.

## Quick Start

### Generators

The `#gen` macro is the entry point for building generators. It provides built-in generators for common types:

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

### Composing Generators

The `#gen` macro composes multiple generators and will attempt to synthesize a bidirectional mapping for reflection:

```swift
struct Person: Equatable {
    let name: String
    let age: Int
}

let personGen = #gen(.string(length: 1...20), .int(in: 0...120)) { name, age in
    Person(name: name, age: age)
}
```

### Running Properties

`#exhaust` runs the property and reports a minimal counterexample, or passes silently:

```swift
#exhaust(personGen) { person in
    person.age >= 0 && person.age <= 120
}
```

Configure with settings:

```swift
#exhaust(personGen, .maxIterations(5000), .shrinkBudget(.slow)) { person in
    person.age >= 0
}
```

### How `#exhaust` Tests

`#exhaust` runs up to two phases, each with its own iteration budget:

**Phase 1: Structured coverage** (default budget: 100 iterations)

Before any random sampling, `#exhaust` analyzes the generator's structure to select the best systematic strategy:

1. **Exhaustive enumeration** — If the generator is composed entirely of small finite domains (booleans, enums, bounded ranges ≤256 values) and the total space fits within the coverage budget, every combination is tested. No random phase follows.

2. **t-way covering arrays** — If the total space is too large for exhaustive enumeration but all parameters are finite, `#exhaust` uses the IPOG algorithm to build a covering array guaranteeing that every t-tuple of parameter values appears in at least one test case. IPOG starts at pairwise (t=2) and increases strength as long as the array fits within the budget.

3. **Boundary value coverage** — If some parameters have large ranges (e.g., `.int(in: 0...10000)`), `#exhaust` synthesizes boundary value representatives for each parameter — `{min, min+1, midpoint, max-1, max, 0}` for integers, special IEEE 754 values for floats — and builds a covering array over those boundary values. This guarantees that every pairwise combination of boundary values is tested.

4. **Skip** — If the generator uses size-scaled operations (`.int()` without a range), `getSize`/`resize`, or has more than 20 parameters, structured coverage is skipped entirely.

The analysis works by running the generator through `ValueAndChoiceTreeInterpreter` with `materializePicks` enabled, producing a `ChoiceTree` that captures every random decision. Walking this tree extracts the parameter model — an approach that sees through bind chains and other opaque compositions that would defeat a static generator walk.

**Phase 2: Random sampling** (default budget: 100 iterations)

After structured coverage completes (unless exhaustive), `#exhaust` runs random sampling for the full `maxIterations` budget. The two budgets are additive — structured coverage does not consume random iterations.

If either phase finds a failing value, `#exhaust` immediately reduces it to a minimal counterexample using the `Reducer`.

**Settings:**

| Setting | Default | Effect |
|---|---|---|
| `.maxIterations(n)` | 100 | Random sampling budget |
| `.coverageBudget(n)` | 100 | Structured coverage budget |
| `.randomOnly` | off | Skip structured coverage entirely |
| `.shrinkBudget(.fast/.slow)` | `.fast` | Reduction thoroughness |
| `.replay(seed)` | — | Deterministic reproduction |

### Sampling

Use `#sample` for quick value generation outside of property tests:

```swift
let person = #sample(personGen)
let people = #sample(personGen, count: 100, seed: 42)
```

### Filter Strategies

Generators with validity constraints can use different strategies to satisfy them:

```swift
// Automatic (default) — selects a strategy based on generator structure
let evenGen = #gen(.int().filter { $0 % 2 == 0 })

// Explicit strategy selection for generators with known sparse validity
let bstGen = #gen(binarySearchTree.filter(.choiceGradientSampling) { isValidBST($0) })
```

### Distribution Tracking

Classify generated values to verify your generator covers the cases you care about:

```swift
let classified = #gen(.int().classify(
    ("negative", { $0 < 0 }),
    ("zero",     { $0 == 0 }),
    ("positive", { $0 > 0 })
))
```

### Validating Generators

Verify that a generator's reflection round-trip and replay determinism are working correctly:

```swift
@Test func personGeneratorIsHealthy() {
    let personGen = #gen(.string(length: 1...20), .int(in: 0...120)) { name, age in
        Person(name: name, age: age)
    }
    personGen.validate()
}
```

`.validate()` generates 200 samples (configurable), checks that each value can be reflected back into a choice sequence and replayed deterministically, and reports failures as test issues.

## Architecture

### Freer Monad Foundation

Every generator in Exhaust is a value of type `ReflectiveGenerator<T>`, which is a type alias for `FreerMonad<ReflectiveOperation, T>`:

```swift
enum FreerMonad<Operation, Value> {
    case pure(Value)
    indirect case impure(operation: Operation, continuation: (Any) throws -> FreerMonad<Operation, Value>)
}
```

This reifies the generator's structure as an inspectable data tree rather than an opaque closure. The same generator can be *interpreted* in multiple ways — forward (generate values), backward (reflect on values), or replay (recreate from recorded choices) — which is what makes automatic test case reduction possible without custom reduction functions.

The `ReflectiveOperation` enum defines 12 primitive operations:

| Operation | Role |
|---|---|
| `pick` | Weighted choice between sub-generators |
| `chooseBits` | Bounded random value via bit patterns |
| `contramap` | Contravariant lens for bidirectional mapping |
| `prune` | Handles partial lens failure |
| `sequence` | Stack-safe collection generation |
| `zip` | Parallel composition of generators |
| `just` | Constant value |
| `getSize` / `resize` | Size parameter for complexity scaling |
| `filter` | Validity predicate (triggers CGS optimization) |
| `classify` | Distribution statistics |
| `unique` | Deduplication |

### Interpreters

The freer monad representation enables multiple interpretations of the same generator:

| Interpreter | Direction | Purpose |
|---|---|---|
| `ValueInterpreter` | Forward | Produce values from randomness |
| `ValueAndChoiceTreeInterpreter` | Forward | Produce values + record all choices as a `ChoiceTree` |
| `OnlineCGSInterpreter` | Forward | Generate with per-site fitness sampling for Choice Gradient tuning |
| `Reflect` | Backward | Decompose a value into the choices that could produce it |
| `Replay` | Replay | Recreate a value deterministically from a `ChoiceTree` |
| `Materialize` | Replay | Recreate a value from a `ChoiceTree` + `ChoiceSequence`, with relaxed structural matching |
| `Reducer` | Reduction | Reduce a failing choice sequence to its minimal form |

### Choice Trees and Sequences

When a value is generated, Exhaust records every random decision as a hierarchical `ChoiceTree`. This tree can be flattened to a `ChoiceSequence` for mutation and reduction. The dual representation enables both structural manipulation (operating on the tree) and efficient comparison (operating on the flat sequence).

### Test Case Reduction

The `Reducer` implements a 12-pass reduction system that operates on the principle of reducing *the random choices*, not the value itself. This means reduction is type-agnostic and validity-preserving — the generator guarantees that every candidate satisfies the same structural invariants as the original.

Passes include branch promotion and pivoting (operating on the `ChoiceTree`), adaptive span deletion, value simplification via binary search, cross-container redistribution, sibling reordering, and speculative delete-and-repair. All candidates are evaluated against a shortlex ordering to ensure monotonic progress toward minimal counterexamples.

Two budget profiles are available: `.fast` (default, ~500 probes) for tight feedback loops, and `.slow` (~2500 probes) for thorough minimization.

### Combinatorial Coverage

When `#exhaust` can determine a generator's parameter structure — the number of independent random decisions and the domain of each — it uses that information to select a systematic testing strategy before any random sampling begins.

`ChoiceTreeAnalysis` performs this analysis by running the generator once through `ValueAndChoiceTreeInterpreter` with `materializePicks` enabled, which evaluates all branches of every `pick` operation. The resulting `ChoiceTree` is walked to extract a parameter model:

- **Finite parameters** — `chooseBits` with explicit ranges ≤256 values, or `pick` between pure branches
- **Boundary parameters** — `chooseBits` with large explicit ranges, synthesized down to boundary value representatives
- **Sequence parameters** — explicit constant-scaled lengths (capped at `{0, 1, 2}`) plus up to 2 element slots

The parameter model feeds the IPOG covering array generator (Lei & Kacker, ECBS 2007), which builds a compact test suite guaranteeing that every t-tuple of parameter values appears in at least one row. Each row is converted to a `ChoiceTree` and replayed through the generator using the same replay infrastructure used for shrinking.

This approach composes two complementary techniques from the NIST combinatorial testing literature (SP 800-142): boundary value analysis selects *which values* to test per parameter, and t-way combination ensures *interactions* between those values are covered.

### Choice Gradient Sampling

When a generator has a validity constraint (via `.filter`), many random inputs may be invalid. Choice Gradient Sampling (CGS) addresses this by learning which choices at each `pick` site lead to valid outputs.

Exhaust's `ChoiceGradientTuner` implements a three-stage offline pipeline:

1. **Online CGS warmup** — Runs the generator through derivative-based fitness sampling, accumulating per-site, per-choice fitness data
2. **Weight baking** — Converts fitness data into static pick weights using fitness sharing (niche-count redistribution) to prevent overcommitting to dominant choices
3. **Adaptive smoothing** — Per-site entropy analysis applies higher temperature at bottleneck sites to preserve diversity

After tuning, all subsequent generation uses the cheap `ValueAndChoiceTreeInterpreter` with baked weights — same quality signal, orders of magnitude cheaper per sample.

## Inspirations

Exhaust draws on three main lines of research:

### Goldstein, "Property-Based Testing for the People" (UPenn, 2024)

The theoretical foundation. Goldstein's dissertation establishes that generators built on a freer monad can be interpreted bidirectionally — the same generator that produces random values can also *parse* a value back into the random choices that could have produced it. This "parsing randomness" insight, combined with Brzozowski derivatives applied to generators, yields the Choice Gradient Sampling algorithm. Exhaust implements this architecture faithfully: the `FreerMonad` + `ReflectiveOperation` representation, the forward/backward/replay interpreter triangle, and the derivative-based CGS core all trace directly to Goldstein's formalization.

Where Exhaust extends the dissertation: the offline CGS pipeline with fitness sharing, the reification of `filter`/`classify`/`unique` into the operation set, and the 12-pass `Reducer` for efficient test case reduction.

### Hypothesis (MacIver & Donaldson, [ECOOP 2020](https://drops.dagstuhl.de/storage/00lipics/lipics-vol166-ecoop2020/LIPIcs.ECOOP.2020.13/LIPIcs.ECOOP.2020.13.pdf))

The ergonomic and reduction model. Hypothesis pioneered "internal test-case reduction" — the insight that reducing *the random choices* rather than the *output value* makes reduction type-agnostic and automatically validity-preserving. Exhaust's `Reducer` builds on this foundation with more structurally informed passes that exploit the `ChoiceTree`/`ChoiceSequence` dual representation — Exhaust's answer to Hypothesis's bracketed bit strings, preserving hierarchical structure for more targeted manipulation.

### Tjoa et al., "Tuning Random Generators" (OOPSLA, 2025)

Algorithmic insight into offline generator tuning. This paper frames generator tuning as an optimization problem over symbolic weights, using objective functions (specification entropy, target distributions, validity) optimized via gradient descent on a probabilistic programming language (Loaded Dice). Key ideas that informed Exhaust's approach:

- **Specification entropy** as the right objective for generators with validity constraints — maximizing diversity *within* the valid output space, not overall
- **Offline tuning as a one-time cost** amortized across many test runs
- **The tension between diversity and validity** — tuning for diversity alone produces invalid outputs; tuning for validity alone collapses to trivial cases; specification entropy resolves the tradeoff

Exhaust's `ChoiceGradientTuner` addresses the same problem with a different mechanism: rather than compiling to BDDs and differentiating symbolically, it uses online CGS warmup to gather fitness data empirically, then bakes weights with fitness sharing to prevent the diversity collapse that Tjoa et al. address with regularization.

## Requirements

- Swift 6.2+
- macOS 26+, iOS 13+, tvOS 13+, watchOS 6+

## Installation

Add to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/chriskolbu/exhaust.git", from: "0.1.0"),
]
```

Then add `Exhaust` as a dependency of your test target:

```swift
.testTarget(
    name: "MyTests",
    dependencies: ["Exhaust"]
)
```
