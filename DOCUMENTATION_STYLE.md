# Documentation Style Guide

## Comment Types

| Syntax | Purpose | Appears in DocC |
|--------|---------|-----------------|
| `///` | API documentation on declarations (types, methods, properties, enum cases) | Yes |
| `// MARK: -` + `//` | Implementation notes, bit layouts, design rationale | No |
| `//` inline | Brief clarification of a single line or block | No |

- Never use `/** */`. The codebase uses `///` exclusively.
- Every `public` and `@_spi(ExhaustInternal)` declaration must have a `///` doc comment.
- `internal` declarations in ExhaustCore: doc comment required on types and non-trivial methods.
- `private`/`fileprivate`: recommended for anything non-trivial (10+ lines or non-obvious behavior).

## Public API (Exhaust Module)

Audience: Swift developers writing property-based tests. They may not know what a Freer Monad is.

### Summary Line

One sentence, present tense, starts with a verb. Describes what the generator produces, not how it works internally. Ends with a period.

```swift
/// Generates arbitrary `Int128` values from two `UInt64` halves.
```

### Discussion

Optional — add when behavior is non-obvious. Plain language. Explain what the user observes, not the internal mechanism. Do not use contractions in summary lines; contractions are acceptable in discussion paragraphs.

```swift
/// Generates dates within the given range, spaced by `interval`.
///
/// Dates are quantized to integral multiples of the interval relative to the range's lower bound. The `timeZone` parameter controls which DST transitions boundary analysis includes.
```

### Code Examples

Required for every generator factory method. Use the `#gen(...)` macro form when one exists. Keep examples to three to five lines.

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

Document what the generator does, the same as any other factory method. An IDE user hovering over an overload should see a useful description, not just "this is an overload." No code example needed if the primary method already has one.

```swift
/// Generates arbitrary integers within the given range.
```

## Internal API (ExhaustCore Module)

Audience: Maintainers who understand the Freer Monad, ChoiceTree, and interpreter architecture.

### Summary Line

One sentence. Technical terminology is expected — ChoiceTree, VACTI, CGS, choice sequence, shortlex, bid pattern are all fine without explanation.

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
6. **Code references**: Double backticks for symbol references in doc comments (``ReflectiveGenerator``). Single backticks for inline code literals in discussion text (`UInt64`).
7. **Punctuation**: All summary lines and list items end with a period.
8. **No hard line breaks in doc comments**: Do not insert line breaks to wrap prose in `///` comments. Write each sentence or logical clause as a continuous line. The IDE and rendered documentation handle wrapping — hard breaks cause awkward double-wrapping at narrow widths.

## What NOT to Document

Do not add `///` doc comments to:

- Trivial `Equatable`, `Hashable`, `Sendable` conformances with no custom logic.
- Computed properties that mirror a stored property.
- Protocol requirement implementations where the protocol's own documentation is sufficient.
- Private helper functions under three lines called from a single site (use inline `//` if needed).
- Boilerplate file headers (`// File.swift // Module //`).

Always document:

- Every `public` declaration, no exceptions.
- Every `@_spi(ExhaustInternal)` declaration.
- Any `private` function longer than 10 lines or with non-obvious behavior.
- Any `@unchecked Sendable` conformance (explain why it is safe).

## MARK Convention

Always use `// MARK: -` (with the dash) for visual separation. Explanatory prose after a MARK uses plain `//`, not `///`.
