# Building generators

Exhaust builds generators with the `#gen` macro. Each generator is an inspectable data structure that Exhaust can run forward to produce values, backward to reflect known values, and replay for deterministic reproduction. Reduction, edge case coverage, and filter optimisation follow from this design.

If you're new to Exhaust, start with [Getting Started](GETTING_STARTED.md). This page covers the main generator concepts.

- [Three modes](#three-modes)
- [Primitives](#primitives)
- [Collections](#collections)
- [Choice](#choice)
- [Composing generators](#composing-generators)
- [Synthesising generators from Decodable types](#synthesising-generators-from-decodable-types)
- [Generating test data with `#example`](#generating-test-data-with-example)
- [Recursive generators](#recursive-generators)
- [Metamorphic testing](#metamorphic-testing)
- [Filters and classification](#filters-and-classification)
- [Bidirectional transforms](#bidirectional-transforms)
- [Reflecting known values](#reflecting-known-values)

## Three modes

Every generator records the choices it makes during generation: which branch of a `oneOf`, which integer from a range, how many elements in an array. Exhaust operates on these recorded choices in three modes:

- **Generation (forward)**: the generator is interpreted to produce a value, recording every choice along the way. This is the normal path during test execution.
- **Reflection (backward)**: given a concrete value, the generator is run in reverse to recover the choices that could have produced it. This powers `reflecting:` and automatic [reduction](REDUCTION.md) without custom reduction functions.
- **Replay**: a recorded sequence of choices is fed back to reproduce the exact same value, powering deterministic reproduction via `.replay(seed)`.

## Primitives

`#gen` wraps built-in types into reflective generators:

```swift
let ints = #gen(.int(in: -100...100))
let bools = #gen(.bool())
let strings = #gen(.string(length: 1...50))
```

Generators without an explicit range use size scaling: Exhaust starts small and increases complexity across the test run.

> [!Note]
> Additional generators are available for dates, UUIDs, SIMD vectors, decimals, and more.

## Collections

```swift
let arrays = #gen(.int().array(length: 0...10))
let sets = #gen(.int().set(count: 1...5))
```

## Choice

```swift
let direction = #gen(.oneOf(.just("north"), .just("south"), .just("east"), .just("west")))
```

## Composing generators

Real code tests structured values. Exhaust composes multiple generators and attempts to automatically synthesise a bidirectional mapping from a trailing closure.

```swift
struct Person: Equatable {
    let name: String
    let age: Int
}

let personGen = #gen(.string(length: 1...20), .int(in: 0...120)) { name, age in
    Person(name: name, age: age)
}
```

When Exhaust can synthesise the backward mapping (extracting struct properties by label, or pattern-matching enum cases), it inserts a `mapped` transform and the generator is fully reflectable. When it cannot, the generator remains forward-only. Generation and reduction still work, but reflection from a concrete value cannot pass backward through the composition. See [Bidirectional transforms](#bidirectional-transforms) for the full picture.

## Synthesising generators from Decodable types

Writing generators by hand scales well for a handful of types. When you have many types that already conform to `Codable`, you can skip the manual work and let Exhaust build a generator from an example value.

```swift
struct Person: Codable {
    let name: String
    let age: Int
    let active: Bool
}

let gen = try #gen(Person.self, from: """
    {
      "name": "Chris", 
      "age": 42, 
      "active": true
    }
    """)
```

Exhaust decodes the JSON once to discover the type's field structure, then builds a generator with one sub-generator per field. The JSON values are scaffolding: they make the discovery pass work but do not constrain the generator's output. Once built, the generator is a normal `ReflectiveGenerator` that produces arbitrary values, reduces counterexamples, and gets edge case coverage like any hand-written generator.

Three overloads accept different input shapes:

```swift
// From a JSON `String`:
let gen = try #gen(Person.self, from: jsonString)

// From JSON `Data`:
let gen = try #gen(Person.self, from: jsonData)

// From an existing `Codable` instance:
let example = Person(name: "Chris", age: 42, active: true)
let gen = try #gen(from: example)
```

### What gets a full generator

Primitive types: all integer types, `Bool`, `Float`, `Double`, `String`, `Character`, `Date`, `UUID`, `URL`, `Data`, `Decimal`, `CGFloat` produce full generators with size scaling and boundary analysis. `Optional`, `Array`, `Dictionary`, and `Set` produce full generators when their element types are supported. `CaseIterable` types produce even-weighted picks across all cases.

### What falls back to a constant

Types the synthesiser cannot handle (non-`CaseIterable` enums, types with hand-written `init(from:)` that branch on decoded values) fall back to `.just(decodedValue)`, pinning the field to the constant value from the example JSON or instance. The generator still works, but those fields do not vary across iterations.

> [!Tip]
> Run `#examine` on a synthesised generator to see which fields are fully generated and which are pinned:
> ```swift
> let report = #examine(gen, .samples(50))
> // Output includes:
> //   Correctness: reflection skipped (synthesised generator)
> //   Pinned fields: 1 field could not be synthesised (constant value from example JSON)
> ```

### Limitations

Synthesised generators are forward-only. Reflection is not supported, so `reflecting:` cannot decompose a concrete value backward through a synthesised generator. Reduction still works because the reducer operates on the generator's choices, not output values.

> [!Note]
> Synthesised generators are at least three times slower per iteration than hand-written generators, because each value is reconstructed through `init(from: Decoder)`. More importantly, they have no knowledge of domain constraints, like valid ranges, inter-field relationships, or other invariants that the type's consumers rely on. 
>
> A hand-written generator encodes these constraints directly, producing values that exercise the interesting parts of the domain rather than all possible values. Treat synthesised generators as a starting point, not a replacement for domain-aware generators on types that matter.

## Generating test data with `#example`

`#example` generates values from your generators outside of property tests. This is a fast way to produce test data, prototypes, and snapshot inputs:

```swift
let person = #example(personGen)
let people = #example(personGen, count: 100, seed: 42)
```

`#example` generates values at size 50 on Exhaust's 0-to-100 complexity scale. Specifying a `seed` makes the output deterministic. Specifying `count` generates multiple values.

## Recursive generators

Some domains are naturally recursive: trees, nested JSON, abstract syntax trees. `.recursive` defines generators that reference themselves, with a depth range to keep things finite:

```swift
indirect enum JSONValue: Equatable {
    case null
    case int(Int)
    case array([JSONValue])
}

let jsonGen = #gen(.recursive(base: .null, depthRange: 0...5) { recurse, remaining in
    .oneOf(weighted:
        (2, .just(.null)),
        (2, .int(in: 0...99).map { JSONValue.int($0) }),
        (Int(remaining), recurse().array(length: 0...3).map { JSONValue.array($0) })
    )
})
```

At each level, `remaining` counts down from the maximum depth, and `recurse()` produces a generator for the next level. When depth is exhausted, only the base case is used. The `weighted` parameter biases toward leaves so that generated trees stay manageable, while `remaining` naturally reduces branching as recursion deepens.

The depth itself is drawn from `depthRange` as a reducible choice. The reducer can collapse entire subtrees by driving the depth toward the range's lower bound. Recursive generators are fully transparent to reflection and reduction.

## Metamorphic testing

Metamorphic testing checks relationships between outputs: if you transform the input in a known way, the output should change in a predictable way. The `.metamorph` combinator separates input setup from the property itself, the same way Arrange/Act/Assert separates a unit test.

Without `metamorph`, setup and assertion are interleaved in the property closure:

```swift
#exhaust(.int().array(length: 0...100)) { array in
    let stdlib = array.sorted()
    let custom = mySort(array)
    stdlib == custom
}
```

With `metamorph`, input preparation moves to the generator and the property reads as a pure assertion:

```swift
let gen = #gen(.int().array(length: 0...100))
    .metamorph({ $0.sorted() }, { mySort($0) })

#exhaust(gen) { (original, stdlib, custom) in
    stdlib == custom
}
```

The original value is always at tuple position zero, followed by the transformed copies. Transforms can return different types. `{ $0.count }` alongside `{ $0.sorted() }` produces a tuple of `(original, Int, [Int])`.

Each transform receives its own independently generated copy, identical in value but separate objects, safe to mutate independently. This means transforms can call mutating methods or hold references without affecting each other, which makes `metamorph` safe for reference types and in-place algorithms. When a failure is found, Exhaust reduces the original value and all transformed copies follow automatically.

## Filters and classification

Add validity constraints with `.filter`:

```swift
let evenGen = #gen(.int().filter { $0 % 2 == 0 })
```

Most property-based testing frameworks implement filters as rejection sampling: generate a value, test the predicate, throw it away and retry if it fails. This works when the valid region is large, but becomes impractical when valid values are sparse (balanced trees, well-formed inputs, values satisfying multiple constraints).

Because generators are inspectable data structures, Exhaust can analyse the generator's branching points and measure how often each branch leads to a value that satisfies the predicate. It then reweights the branches to favour valid outputs before generation begins, a technique called Choice Gradient Sampling (CGS). Filtered generators produce valid values efficiently even when the acceptance rate under rejection sampling would be vanishingly small.

You can select the strategy explicitly:

```swift
// Default: generator tuning via CGS (same as .auto)
let balanced = bstGen.filter { $0.isBalanced }

// Pure rejection sampling — no tuning, just retry
let small = #gen(.int().filter(.rejectionSampling) { $0 < 10 })
```

| Strategy | Behaviour |
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

## Bidirectional transforms

Reflection requires that transformations be reversible. `.map` is forward-only. Exhaust can still generate and reduce with it, but it cannot reflect a concrete value backward through a `.map` closure. When you need full bidirectional support, use `mapped(forward:backward:)`:

```swift
let celsius = #gen(.double(in: -273.15...1000.0))
    .mapped(
        forward: { $0 * 9/5 + 32 },
        backward: { ($0 - 32) * 5/9 }
    )
```

`#gen` uses `mapped` automatically when it can synthesise a backward mapping. For structs it extracts properties by label, and for enum cases it uses pattern matching. For custom transformations where Exhaust cannot infer the reverse, you can provide it explicitly.

`bound` is the bidirectional equivalent of `.bind` (`.flatMap`). The `backward` function is a comap: given the final output, it extracts the inner value that was used to select the dependent generator. This enables reflection through the bind. Without `backward`, Exhaust can generate and reduce but cannot reflect a concrete value backward through the dependency.

### Reflectable vs forward-only

| Capability | Reflectable (`mapped`/`bound`) | Forward-only (`.map`/`.bind`) |
|---|---|---|
| `#exhaust` (generation + reduction) | Yes | Yes |
| `#exhaust(..., reflecting: value)` | Yes | No |
| `#example` | Yes | Yes |
| `#examine` (coverage + round-trip) | Yes | Coverage only |
| Edge case coverage | Yes | Yes |

Generators built entirely from `#gen` primitives and `mapped`/`bound` are fully reflectable. Adding a `.map` or `.bind` makes the generator forward-only at that point. Reflection from a concrete value cannot pass backward through the forward-only closure.

> [!Important]
> Forward-only transforms do not affect generation or reduction. A generator with `.map` still generates values, still gets edge case coverage, and still reduces counterexamples to their smallest form. The only capability lost is `reflecting:` — feeding a known value backward through the generator. If you do not need reflection, `.map` and `.bind` work exactly as well as their bidirectional counterparts.

## Reflecting known values

Sometimes you already have a failing value — from a bug report, a production log, or a test fixture — and want to find the simplest version that still fails. The `reflecting:` parameter skips generation, reflects your value through the generator, and reduces it:

```swift
@Test func minimiseBugReport() {
    let gen = #gen(.int().array(length: 3...30))
    let fromBugReport = [1337, 80085, 69, 67]

    #exhaust(gen, reflecting: fromBugReport) {
        #expect(Set($0).count < 3)
    }
    // Reduces to [-1, 0, 1]
}
```

Exhaust decomposes the value into the generator choices that could have produced it, then reduces those choices to find the minimal counterexample. This works with any reflectable generator, including composed ones.
