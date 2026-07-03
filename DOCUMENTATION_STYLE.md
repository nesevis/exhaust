# Documentation Style Guide

## Comment Types

| Syntax | Purpose | Appears in DocC |
|--------|---------|-----------------|
| `///` | API documentation on declarations (types, methods, properties, enum cases) | Yes |
| `// MARK: -` + `//` | Implementation notes, bit layouts, design rationale | No |
| `//` inline | Brief clarification of a single line or block | No |

- Never use `/** */`. The codebase uses `///` exclusively.
- Every `public` declaration must have a `///` doc comment.
- `internal` declarations in ExhaustCore: doc comment required on types and non-trivial methods.
- `private`/`fileprivate`: recommended for anything non-trivial (10+ lines or non-obvious behavior).

## Public API (Exhaust Module)

Audience: Swift developers writing property-based tests. They may not know what a Freer Monad is.

### Tone: Teach, Don't Assert

Public doc comments should help the reader make a decision, not convince them that something is important. Every doc comment answers one or both of: "when do I use this?" and "what happens if I use the wrong thing?"

**Do not** write phrases like "this is the fundamental operation for," "this is essential for," or "this is the key operation that enables." These assert importance without demonstrating it. A reader who does not already understand the concept learns nothing from being told it is key.

**Instead**, show consequences. Explain what the reader gains or loses by choosing this API over an alternative:

```swift
// Bad — asserts importance:
/// This is the fundamental operation for adapting generators to work with different types
/// while preserving the bidirectional capability.

// Good — teaches the decision:
/// Adapts a generator to a new output type while preserving reflection support.
/// Use this when `#gen` cannot synthesize the backward mapping automatically
/// (for example, when the transform involves computation rather than an initializer call).
```

When multiple APIs serve similar purposes (for example `map`, `mapped`, and `#gen` with a closure), the doc comment for each should explain when *this* one is the right choice and what the reader loses by picking a different one. Do not describe the mechanism in isolation — describe the tradeoff.

### Summary Line

One sentence, present tense, starts with a verb. Describes what the generator produces, not how it works internally. Ends with a period. When the API has a natural alternative, the summary line should hint at the distinction.

```swift
/// Generates arbitrary `Int128` values from two `UInt64` halves.
```

### Discussion

Optional — add when behavior is non-obvious. Plain language. Explain what the user observes, not the internal mechanism. Do not use contractions in summary lines; contractions are acceptable in discussion paragraphs.

When an API has consequences the reader might not expect, state them early in the discussion rather than burying them in a note callout. Prefer "without this, X happens" over "this enables X."

```swift
/// Generates dates within the given range, spaced by `interval`.
///
/// Dates are quantized to integral multiples of the interval relative to the range's lower bound. The `timeZone` parameter controls which DST transitions boundary analysis includes.
```

### Code Examples

Required for every generator factory method. Use the `#gen(...)` macro form when one exists. Keep examples to three to five lines. For macros and complex entry points, place examples *before* architecture explanations — the reader should see how to call the API before learning how it works internally.

```swift
/// ```swift
/// let gen = #gen(.date(
///     between: startDate ... endDate,
///     interval: .hours(1)
/// ))
/// ```
```

### Parameters and Returns

Use Swift's `- Parameter name:` / `- Returns:` format. Required when any parameter's purpose is not obvious from its label and type.

```swift
/// - Parameters:
///   - gen: Generator for each array element.
///   - length: The allowed range of array lengths.
///   - scaling: How array length scales with the size parameter. Defaults to `.linear`.
/// - Returns: A generator producing arrays with length in the given range.
```

### Limitations and Caveats

Use `/// - Note:` or `/// - Important:` callouts inside the doc comment. Do not use detached `//` blocks above the extension — those do not appear in generated documentation.

```swift
/// - Note: Shrinking operates on each half independently. Range-constrained and size-scaled generation are not supported.
```

### Convenience Overloads

Document what the generator does, the same as any other factory method. An IDE user hovering over an overload should see a useful description, not just "this is an overload." No code example needed if the primary method already has one. State why the overload exists (for example, "accepts `ClosedRange<Int>` so integer literals resolve without explicit type annotation").

```swift
/// Generates arbitrary integers within the given range.
```

## Internal API (ExhaustCore Module)

Audience: Maintainers who understand the Freer Monad, ChoiceTree, and interpreter architecture.

### Tone: Explain Why, Not What

The reader can see the type signature, the field names, and the case labels. Do not restate them in English. A doc comment that says "stores its identity, kind, position mapping, and parent-child relationships" on a struct with fields `id`, `kind`, `positionRange`, `children`, and `parent` adds nothing.

Instead, explain what the reader *cannot* see from the declaration alone:
- **Why** a design choice was made (why indices instead of pointers, why a class instead of a struct).
- **When** a value takes on a special state (when is `positionRange` nil, and what does that mean for encoders).
- **What invariants** the type relies on that the compiler does not enforce (which fields must stay in sync, what ordering is assumed).

```swift
// Bad — restates the fields:
/// Each node stores its identity, kind with per-kind metadata, position mapping
/// to the flat ChoiceSequence, and parent-child relationships forming the containment tree.

// Good — explains what the reader cannot see:
/// Inactive (unselected) branches have nil position ranges. Encoders must skip
/// these nodes — only nodes with a position range address live entries in the
/// ChoiceSequence.
```

For enum cases, go beyond the case name. Explain the structural role the case plays in the system — what edges it sources, what operations target it, what happens when it changes.

### Summary Line

One sentence. Technical terminology is expected: ChoiceTree, VACTI, CGS, choice sequence, shortlex, bit pattern are all fine without explanation.

```swift
/// Finds the largest contiguous batch of same-depth spans that can be deleted while preserving the property failure.
```

### Discussion

Include algorithm sketches for non-trivial methods. Use callouts for complexity and cross-references:

```swift
/// - Complexity: O(*n* · log *n* · *M*), where *n* is the number of spans and *M* is the cost of a single property invocation.
/// - SeeAlso: ``ChoiceSequence``, ``Reducer``
```

### Structured Sections

For major types only, use `## Heading` inside doc comments to organize conceptual documentation. Follow the existing `ReflectiveOperation` pattern:

```swift
/// ## Forward Pass (Generation)
/// ...
/// ## Backward Pass (Reflection)
/// ...
```

### Implementation Notes

Use `// MARK: -` followed by plain `//` lines for details that are important when reading source but should not appear in DocC. The UUID v4 bit layout comment is the model:

```swift
// MARK: - UUID v4 Bit Layout
//
// Bytes 0-7 (high UInt64, big-endian):
//   bits 63-16: 48 random bits (bytes 0-5)
//   bits 15-12: version nibble = 0x4
//   bits 11-0:  12 random bits (byte 6 low nibble + byte 7)
```

## Grammar and Style

Based on the Apple Style Guide (June 2025), US English:

1. **US English spelling**: "behavior" not "behaviour", "analyze" not "analyse".
2. **Serial (Oxford) comma**: "values, branches, and markers".
3. **No Latin abbreviations**: "for example" not "e.g.", "that is" not "i.e.", "and so on" not "etc."
4. **Present tense, active voice**: "Generates dates within the range" not "This will generate dates".
5. **Numerals**: Spell out zero through nine. Use numerals for 10 and above. Exception: always use numerals in technical contexts (bit widths, array lengths, domain sizes).
6. **Code references**: Double backticks for Exhaust-defined symbol references in doc comments (``ReflectiveGenerator``, ``Gen/choose(in:)``). Single backticks for standard library and system framework types (`Int`, `Double`, `Hashable`, `CharacterSet`) and for inline code literals in discussion text (`UInt64`).
7. **Punctuation**: All summary lines and list items end with a period.
8. **No hard line breaks in comment prose**: Do not insert line breaks to wrap paragraph text in `///` doc comments or `//` implementation notes. Write each sentence or logical clause as a continuous line — do not break lines to fit a character-per-line limit. Hard breaks in prose cause awkward double-wrapping at narrow widths. This does not apply to code examples, tables, diagrams, or other content where visual layout matters.

## What NOT to Document

Do not add `///` doc comments to:

- Trivial `Equatable`, `Hashable`, `Sendable` conformances with no custom logic.
- Computed properties that mirror a stored property.
- Protocol requirement implementations where the protocol's own documentation is sufficient.
- Private helper functions under three lines called from a single site (use inline `//` if needed).
- Boilerplate file headers (`// File.swift // Module //`).

Always document:

- Every `public` declaration, no exceptions.
- Any `private` function longer than 10 lines or with non-obvious behavior.
- Any `@unchecked Sendable` conformance (explain why it is safe).

## MARK Convention

Always use `// MARK: -` (with the dash) for visual separation. Explanatory prose after a MARK uses plain `//`, not `///`.
