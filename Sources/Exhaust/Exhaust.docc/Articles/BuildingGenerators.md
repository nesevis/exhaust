# Building generators

Exhaust builds generators with the `#gen` macro. Each generator is an inspectable data structure that Exhaust can run forward to produce values, replay for deterministic reproduction, and, with bidirectional transforms, run backward to reconstruct a known value's choices. Reduction, screening of problematic values, and filter optimisation all follow from inspection.

If you're new to Exhaust, start with <doc:GettingStarted>. This page covers the main generator concepts.

## Three modes

Every generator records the choices it makes during generation: which branch of a `oneOf`, which integer from a range, how many elements in an array. Exhaust operates on these recorded choices in three modes:

- **Generation (forward)**: the generator is interpreted to produce a value, recording every choice along the way. This is the normal path during test execution.
- **Replay**: a recorded sequence of choices is fed back to reproduce the exact same value, powering deterministic reproduction via `.replay(seed)`.
- **Reflection (backward)**: given a concrete value, the generator is run in reverse to recover the choices that could have produced it. `#exhaust(…, reflecting:)` uses those choices to start reduction. Reflection requires bidirectional transforms (see [Bidirectional transforms](#bidirectional-transforms)).

## Primitives

`#gen` wraps built-in types into reflective generators:

```swift
let ints = #gen(.int(in: -100...100))
let bools = #gen(.bool())
let strings = #gen(.string(length: 1...50))
```

Generators without an explicit range use size scaling: Exhaust starts small and ramps up across the test run. An explicit range is sampled uniformly from the first run; pass `scaling:` to ramp within it (`.int(in: 0...1000, scaling: .linear)`).

> Note:
> Additional generators are available for dates, UUIDs, SIMD vectors, decimals, and more.

## Collections

```swift
let arrays = #gen(.int().array(length: 0...10))
let sets = #gen(.int().set(count: 1...5))
let lookup = #gen(.dictionary(.asciiString(), .int(), count: 1...5))
```

Arrays preserve their generated sequence structure, so `#exhaust(…, reflecting:)` can start reduction from a concrete array when its element generator supports reflection. Sets and dictionaries are forward-only because constructing them discards draw order and may collapse duplicate elements or keys. Exhaust still replays and reduces their generated counterexamples from the recorded choices.

## Optionals

`.optional()` wraps a generator so it sometimes produces `nil`. The weights control the ratio; the defaults produce `nil` roughly 20% of the time:

```swift
let maybe = #gen(.int(in: 0...10).optional())
let nilHeavy = #gen(.int(in: 0...10).optional(someWeight: 1, noneWeight: 3))
```

## Ranges

`.closedRange` and `.range` draw two bounds from an element generator and sort them, so every produced range is well-formed by construction. Both work with any `Comparable` bound (integers, doubles, dates) and are fully reflectable: the backward pass extracts the bounds.

```swift
let spans = #gen(.closedRange(.int(in: 0...100)))    // ClosedRange<Int>
let windows = #gen(.range(.double(in: 0...1)))       // Range<Double>, empty when bounds collide
```

## Choice

`.oneOf` selects between alternative generators, evenly or by weight. `.element(from:)` picks from a fixed collection, which is the idiomatic way to cover a `CaseIterable` enum:

```swift
let direction = #gen(.oneOf(.just("north"), .just("south"), .just("east"), .just("west")))
let pet = #gen(.oneOf(weighted: (3, catGen), (1, dogGen)))
let suit = #gen(.element(from: Suit.allCases))
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

When Exhaust can synthesise the backward mapping (extracting struct properties by label, or validating an enum case and extracting its associated values), it inserts a `mapped` transform and the generator is fully reflectable. A qualified static factory call has the same source shape as an enum case, so it still generates values but reflection rejects its non-enum output. When Exhaust cannot synthesise the backward mapping, the generator remains forward-only. Generation and reduction still work, but reflection from a concrete value cannot pass backward through the composition. See [Bidirectional transforms](#bidirectional-transforms) for the full picture.

## Synthesising generators from Decodable types

Synthesised generators build a working generator from example JSON or an existing `Codable` instance. They need no composition closure, manual field threading, or access to the type's initialiser. They run roughly three times slower per iteration than hand-written generators, and they have no knowledge of domain constraints such as valid ranges, inter-field relationships, or invariants that the type's consumers rely on.

For uncomplicated types you own, synthesis gets you testing quickly. When you want control over the values it generates, replace it with a hand-written generator. For types you don't own or can't construct directly, synthesis may be the only practical option. The JSON overloads construct values through `init(from:)`, so you never need access to the type's initialiser.

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

Exhaust decodes the JSON once to discover the type's field structure, then builds a generator with one sub-generator per field. The JSON values are scaffolding: they make the discovery pass work but do not constrain the generator's output. Once built, the generator is a normal `ReflectiveGenerator` that produces arbitrary values, reduces counterexamples, and gets the same screening as any hand-written generator.

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

The two JSON overloads require only `Decodable`. The instance overload requires `Codable`: Exhaust encodes the instance to JSON first, then runs it back through the same discovery decode, so the type has to support both directions.

### What gets a full generator

These types produce full generators with size scaling and problematic-value screening:

- **Primitives**: all signed and unsigned integer types, `Bool`, `Float`, `Double`, `String`, and `Character`.
- **Foundation types**: `Date`, `UUID`, `URL`, `Data`, `Decimal`, and `CGFloat`.
- **`CaseIterable` types**: even-weighted picks across every case.
- **`Optional`, `Array`, `Set`, and `Dictionary`**: full generators whose presence, length, and contents vary, as long as the element type or the wrapped, key, and value types are supported.
- **Nested `Decodable` types**: a field whose type is another `Decodable` struct is discovered recursively and rebuilt through its own initialiser. The same applies to the element of an array or set and the value of a dictionary. Exhaust reads the element's shape from a representative entry in the example.

Top-level containers work too. A leaf or collection type passed directly, such as `#gen([Item].self, from: "[…]")`, synthesises a generator whose elements are discovered from the example, whether the element is a primitive or a nested `Decodable` type.

### What falls back to a constant

Some fields fall back to a constant from the example, pinned with `.just(decodedValue)`. This covers non-`CaseIterable` `RawRepresentable` enums, collections whose example is empty (no element to discover from), and values decoded through patterns the synthesiser does not model (manual element-by-element unkeyed decoding and class inheritance via a super decoder). A hand-written `init(from:)` that branches still generates correctly when the example exercises that path. A generated value that takes an unexercised branch is pinned for that sample, with a deduplicated warning. The generator still works, but pinned fields do not vary across iterations.

> Tip:
> Run `#examine` on a synthesised generator to see which fields are fully generated and which are pinned:
> ```swift
> let report = #examine(gen, .samples(50))
> // Output includes:
> //   Correctness: reflection skipped (synthesized generator)
> //   Pinned fields: 1 field could not be synthesized (constant value from example JSON)
> ```

### Limitations

Synthesised generators are forward-only, so `#exhaust(…, reflecting:)` cannot decompose a concrete value through them. Exhaust still reduces counterexamples found during generation because the reducer operates on the recorded choices.

## Generating test data with #example

`#example` generates values from your generators outside of property tests. This is a fast way to produce test data, prototypes, and snapshot inputs:

```swift
let person = try #example(personGen)
let people = try #example(personGen, count: 100, seed: 42)
```

`#example` is throwing because generator synthesis can fail at runtime for types whose `Decodable` conformance has invariants that preclude random generation. The single-value form generates at size 50 on Exhaust's 0-to-100 size scale. The `count` form runs the same interpreter as `#exhaust`'s sampling phase, so with the same seed the values match that phase one for one. A seed accepts a raw number or a string copied from a failure report: `#example(gen, seed: "5QF8M2-3")` recreates exactly the value that iteration generated.

## Recursive generators

Some domains are naturally recursive: trees, nested JSON, abstract syntax trees. `.recursive` defines generators that reference themselves, with a depth range to keep things finite:

```swift
indirect enum JSONValue: Equatable {
    case null
    case int(Int)
    case array([JSONValue])
}

let jsonGen = #gen(.recursive(baseValue: .null, depthRange: 0...5) { recurse, remaining in
    .oneOf(weighted:
        (2, .just(.null)),
        (2, .int(in: 0...99).map { JSONValue.int($0) }),
        (remaining, recurse().array(length: 0...3).map { JSONValue.array($0) })
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
    return stdlib == custom
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

Reflection treats a filter as transparent. `#exhaust(…, reflecting:)` can decompose a supplied value even when it does not satisfy the predicate. Values produced during generation and candidates materialised during reduction still pass the predicate.

You can select the strategy explicitly:

```swift
// Default: generator tuning via CGS (same as .auto)
let balanced = bstGen.filter { $0.isBalanced }

// Pure rejection sampling, with no tuning
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

`#gen` uses `mapped` automatically when it can synthesise a backward mapping. For structs it extracts properties by label, and for enum cases it validates the case and extracts associated values. For custom transformations where Exhaust cannot infer the reverse, you can provide it explicitly.

`bound` is the bidirectional equivalent of `.bind` (`.flatMap`). The `backward` function is a comap: given the final output, it extracts the inner value that was used to select the dependent generator. This enables reflection through the bind. Without `backward`, Exhaust can generate and reduce but cannot reflect a concrete value backward through the dependency.

### Reflectable vs forward-only

| Capability | Reflectable (`mapped`/`bound`) | Forward-only (`.map`/`.bind`) |
|---|---|---|
| `#exhaust` (generation + reduction) | Yes | Yes |
| `#exhaust(…, reflecting: value)` | Yes | No |
| `#example` | Yes | Yes |
| `#examine` (domain coverage + round-trip) | Yes | Domain coverage only |
| Problematic-value screening | Yes | Yes |

A generator is fully reflectable only when every operation on the relevant path supports reflection. Primitive factories support reflection, and `mapped` and `bound` preserve it when their backward closures can recover the required inputs. A `.map`, `.bind`, or factory documented as forward-only blocks reflection at that point. Set, dictionary, generated-slice, and shuffle factories are common examples because their outputs do not retain enough information to recover their inputs.

> Important:
> Forward-only transforms do not affect generation, replay, problematic-value screening, or reduction from choices recorded during generation. They prevent `#exhaust(…, reflecting:)` from feeding a known value backward through that part of the generator. Use `.map` and `.bind` when that reflection path is unnecessary.

## Reflecting known values

Sometimes you already have a failing value from a bug report, production log, or test fixture and want to find the minimal version that still fails. `#exhaust(…, reflecting:)` skips generation, reflects your value through the generator, and reduces it:

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

Exhaust decomposes the value into generator choices, then reduces those choices to find the minimal counterexample. Every operation on the reflected path must support reflection. Some operations are permissive, so successful reflection means that Exhaust found a usable choice tree rather than proving that the generator could have produced the value.
