# Date Generator for Exhaust

## Context

Exhaust has no Foundation type generators yet. `Date` is a common type in property-based tests, but requires care: dates must be absolute (never relative to `Date.now`) to keep assertions deterministic.

This adds a `Date` generator built on `Int64` (integral seconds) mapped bidirectionally to `Date`, with a required `interval` parameter that controls granularity.

## Design

### New type: `DateSpan`

A `Comparable` enum representing calendar-meaningful durations. Used for range bounds (relative to an anchor date), the symmetric `within:of:` convenience, and the required `interval` parameter.

```swift
public enum DateSpan: Comparable {
    case seconds(Int)
    case minutes(Int)
    case hours(Int)
    case days(Int)
    case weeks(Int)
    case months(Int)
    case years(Int)
}
```

**Key properties and conformances:**

- `var offsetInSeconds: Int` — converts any case to seconds. All cases are simple multiplications: seconds(1), minutes(60), hours(3600), days(86400), weeks(604800), months(2592000 = 30 days), years(31536000 = 365 days). Used for `Comparable` ordering and for computing `Int64` range bounds.
- `Comparable` conformance via `offsetInSeconds`, enabling `ClosedRange<DateSpan>` (e.g. `.hours(-5) ... .hours(5)`). Cross-case ranges are allowed.

Lives alongside the generator in `Sources/Exhaust/Conformances/ReflectiveGenerator+Date.swift`.

### Generator API

Three overloads:

```swift
public extension ReflectiveGenerator {
    /// Generates dates at `interval` steps within an absolute date range.
    static func date(
        between range: ClosedRange<Date>,
        interval: DateSpan
    ) -> ReflectiveGenerator<Date>

    /// Generates dates within a relative span range of an anchor, at `interval` steps.
    /// Example: .date(in: .hours(-5) ... .hours(5), of: anchor, interval: .minutes(15))
    static func date(
        in range: ClosedRange<DateSpan>,
        of anchor: Date,
        interval: DateSpan
    ) -> ReflectiveGenerator<Date>

    /// Generates dates within a symmetric span of an anchor, at `interval` steps.
    /// Example: .date(within: .days(30), of: anchor, interval: .hours(1))
    static func date(
        within span: DateSpan,
        of anchor: Date,
        interval: DateSpan
    ) -> ReflectiveGenerator<Date>
}
```

### Implementation

**`date(between:interval:)`** — the core overload:

1. `precondition(range.lowerBound <= range.upperBound)` — validate range ordering
2. Resolve range bounds to `Int64` seconds since reference date (`Int64(range.lowerBound.timeIntervalSinceReferenceDate)`)
3. Resolve interval to `Int64` seconds (e.g. `.hours(1)` → `3600`)
4. Compute `lowerBound / intervalSeconds` and `upperBound / intervalSeconds` → `Int64` domain for `Gen.choose(in:)`
5. Apply `.mapped(forward:backward:)`:
   - Forward: `Int64 * intervalSeconds` → `Date(timeIntervalSinceReferenceDate: Double(...))`
   - Backward: `date.timeIntervalSinceReferenceDate` → round to nearest interval → divide by intervalSeconds → `Int64`

**`date(in:of:interval:)`** — the relative range overload:

1. `precondition(range.lowerBound <= range.upperBound)` — validate span ordering
2. Compute lower/upper dates: `anchor + range.lowerBound.offsetInSeconds`, `anchor + range.upperBound.offsetInSeconds`
2. Construct `ClosedRange<Date>` from the resolved bounds
3. Delegate to `date(between:interval:)`

**`date(within:of:interval:)`** — the symmetric convenience:

1. Negate the span for the lower bound, use as-is for upper bound
2. Delegate to `date(in: negatedSpan ... span, of: anchor, interval: interval)`

### Why Int64 under the hood

- Integral seconds → clean shrunk counterexamples (no `978307200.00000023`)
- `Int64` range of seconds covers ±292 billion years — more than enough
- Interval divides the domain further, giving the shrinker a smaller choice space
- `Gen.choose(in: ClosedRange<Int64>)` already exists via `BitPatternConvertible`

## Files to create/modify

| File | Action |
|------|--------|
| `Sources/Exhaust/Conformances/ReflectiveGenerator+Date.swift` | **Create** — `DateSpan` enum + all three generator overloads |
| `Tests/ExhaustTests/Generators/DateGeneratorTests.swift` | **Create** — tests |

### Existing code to reuse

- `Gen.choose(in: ClosedRange<Int64>)` — `Sources/ExhaustCore/Core/Combinators/Gen+Choice.swift`
- `.mapped(forward:backward:)` — `Sources/Exhaust/Core/ReflectiveGenerator+Combinators.swift`
- `bool()` generator — `Sources/Exhaust/Conformances/ReflectiveGenerator+Miscellaneous.swift` (reference pattern)

## Future considerations

- Shorthand conveniences for common intervals (TBD)
- Additional Foundation generators (UUID, CGFloat, SIMD) could follow the same pattern
- Component-based generator (year/month/day/hour/minute/second composed independently) as an alternative to interval-based

## Verification

1. `swift build` — confirm compilation
2. `swift test --filter Date` — run the new tests
3. Verify shrinking produces clean integral-second dates
