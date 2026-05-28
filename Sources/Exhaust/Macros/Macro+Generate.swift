import Foundation

/// Combines generators through a transform closure, synthesizing a bidirectional backward mapping when possible.
///
/// When the closure body is a struct or class initializer call with labeled arguments that map one-to-one to the closure parameters, the macro synthesizes a `Mirror`-based backward mapping automatically. When backward inference is not possible (complex expressions, multi-statement bodies), the macro falls back to a forward-only `.map` and emits a warning explaining why.
///
/// Both named parameters and shorthand parameters (`$0`, `$1`, and so on) are supported.
///
/// ```swift
/// let personGen = #gen(nameGen, ageGen) { name, age in
///     Person(name: name, age: age)
/// }
/// // or with shorthand:
/// let personGen = #gen(nameGen, ageGen) { Person(name: $0, age: $1) }
/// ```
@freestanding(expression)
public macro gen<each GeneratedValue, TransformedValue>(
    _ generators: repeat ReflectiveGenerator<each GeneratedValue>,
    transform: (repeat each GeneratedValue) -> TransformedValue
) -> ReflectiveGenerator<TransformedValue> = #externalMacro(module: "ExhaustMacros", type: "GenerateMacro")

/// Wraps a single generator expression, enabling dot-syntax (for example `.int(in: 0...100)`).
///
/// This overload passes the generator through unchanged. Use it when implicit member syntax is more convenient than spelling out the full ``Gen`` type name.
///
/// ```swift
/// let gen = #gen(.int(in: 0...100))
/// ```
@freestanding(expression)
public macro gen<GeneratedValue>(
    _ generator: ReflectiveGenerator<GeneratedValue>
) -> ReflectiveGenerator<GeneratedValue> = #externalMacro(module: "ExhaustMacros", type: "GenerateMacro")

/// Combines multiple generators into a tuple without transformation.
///
/// Use this overload when the generated values are consumed directly as a tuple rather than mapped through a constructor. For struct or class construction, prefer the overload that accepts a `transform` closure so the macro can synthesize a backward mapping.
///
/// ```swift
/// let pair = #gen(.int(in: 0...10), .asciiString(length: 1...5))
/// ```
@freestanding(expression)
public macro gen<each GeneratedValue>(
    _ generators: repeat ReflectiveGenerator<each GeneratedValue>
) -> ReflectiveGenerator<(repeat each GeneratedValue)> = #externalMacro(module: "ExhaustMacros", type: "GenerateMacro")

/// Synthesises a generator from a `Decodable` type and example JSON data.
///
/// Runs `T.init(from:)` once against the provided JSON to discover the type's decode call pattern, then builds a ``ReflectiveGenerator`` that produces arbitrary values of type `T`. The resulting generator is a normal ``ReflectiveGenerator`` — all interpreters, the reducer, and coverage analysis treat it identically to a hand-written generator. Use this overload when writing generators for a large number existing types would be impractical.
///
/// ## What Gets a Full Generator
///
/// Types conforming to ``ExhaustGenerable`` (all integer types, `Bool`, `Float`, `Double`, `String`, `Character`, `Date`, `UUID`, `URL`, `Data`, `Decimal`, `CGFloat`) produce full generators with size scaling, boundary analysis, and shrinking support. `Optional`, `Array`, `Dictionary`, and `Set` produce full generators when their element types conform. `CaseIterable` enums produce even-weighted picks across all cases.
///
/// ## What Falls Back to `.just`
///
/// Types the decoder cannot synthesise a generator for — non-`CaseIterable` `RawRepresentable` enums, types with hand-written `init(from:)` that branch on decoded values, and any other type not covered above — fall back to `.just(decodedValue)`, pinning the field to the constant value from the example JSON. The generator still works; those fields simply do not vary across iterations.
///
/// ## Limitations
///
/// The generator is forward-only. Reflection is not supported — ``#examine`` will report a forward-only warning on the top-level map. Reduction still works because the reducer operates on the choice sequence, not reflected values.
///
/// The ``ReflectiveGenerator/isSynthesized`` flag is set to `true` on the returned generator. Diagnostic tools can check this flag to identify `.just` nodes that represent fields the decoder could not generate.
///
/// - Note: Synthesized generators are approximately twice as slow per iteration as hand-written generators for the same type. The overhead comes from reconstructing each value through `init(from: Decoder)` — the only available construction path for types defined outside the test target — rather than calling the memberwise initializer directly. For hot-path benchmarks or large iteration counts, consider writing a generator by hand.
///
/// ```swift
/// let gen = try #gen(Person.self, from: jsonData)
///
/// #exhaust(gen) { person in
///     person.age >= 0
/// }
/// ```
///
/// - Parameters:
///   - type: The `Decodable` type to synthesise a generator for.
///   - data: Example JSON data whose structure matches `T`. The values are used only during the discovery pass and do not constrain the generator's output.
/// - Returns: A ``ReflectiveGenerator`` that produces arbitrary values of type `T`.
@freestanding(expression)
public macro gen<T: Decodable>(
    _ type: T.Type,
    from data: Data
) -> ReflectiveGenerator<T> = #externalMacro(module: "ExhaustMacros", type: "GenerateFromDecodableMacro")

/// Synthesises a generator from a `Codable` instance by encoding it to JSON and discovering the decode pattern.
///
/// Encodes the instance with `JSONEncoder`, then runs `T.init(from:)` once against the resulting JSON to discover the type's decode call pattern and build a ``ReflectiveGenerator`` that produces arbitrary values of type `T`. The resulting generator is a normal ``ReflectiveGenerator`` — all interpreters, the reducer, and coverage analysis treat it identically to a hand-written generator. Use this when you already have an instance (for example, from a factory method or test fixture) and want a generator without writing out JSON.
///
/// ## What Gets a Full Generator
///
/// Types conforming to ``ExhaustGenerable`` (all integer types, `Bool`, `Float`, `Double`, `String`, `Character`, `Date`, `UUID`, `URL`, `Data`, `Decimal`, `CGFloat`) produce full generators with size scaling, boundary analysis, and shrinking support. `Optional`, `Array`, `Dictionary`, and `Set` produce full generators when their element types conform. `CaseIterable` enums produce even-weighted picks across all cases.
///
/// ## What Falls Back to `.just`
///
/// Types the decoder cannot synthesise a generator for — non-`CaseIterable` `RawRepresentable` enums, types with hand-written `init(from:)` that branch on decoded values, and any other type not covered above — fall back to `.just(decodedValue)`, pinning the field to the constant value from the encoded instance. The generator still works; those fields simply do not vary across iterations.
///
/// ## Limitations
///
/// The generator is forward-only. Reflection is not supported — ``#examine`` will report a forward-only warning on the top-level map. Reduction still works because the reducer operates on the choice sequence, not reflected values.
///
/// The ``ReflectiveGenerator/isSynthesized`` flag is set to `true` on the returned generator. Diagnostic tools can check this flag to identify `.just` nodes that represent fields the decoder could not generate.
///
/// - Note: Synthesized generators are approximately twice as slow per iteration as hand-written generators for the same type. The overhead comes from reconstructing each value through `init(from: Decoder)` — the only available construction path for types defined outside the test target — rather than calling the memberwise initializer directly. For hot-path benchmarks or large iteration counts, consider writing a generator by hand.
///
/// ```swift
/// let example = Person(name: "Alice", age: 30, active: true)
/// let gen = try #gen(from: example)
///
/// #exhaust(gen) { person in
///     person.age >= 0
/// }
/// ```
///
/// - Parameter instance: A `Codable` value whose type and structure determine the generator. The field values are used only during the discovery pass and do not constrain the generator's output.
/// - Returns: A ``ReflectiveGenerator`` that produces arbitrary values of the same type.
@freestanding(expression)
public macro gen<T: Codable>(
    from instance: T
) -> ReflectiveGenerator<T> = #externalMacro(module: "ExhaustMacros", type: "GenerateFromCodableInstanceMacro")

/// Synthesises a generator from a `Decodable` type and an example JSON string.
///
/// Runs `T.init(from:)` once against the provided JSON to discover the type's decode call pattern, then builds a ``ReflectiveGenerator`` that produces arbitrary values of type `T`. The resulting generator is a normal ``ReflectiveGenerator`` — all interpreters, the reducer, and coverage analysis treat it identically to a hand-written generator. Use this overload when writing generators for a large number of existing types would be impractical.
///
/// ## What Gets a Full Generator
///
/// Types conforming to ``ExhaustGenerable`` (all integer types, `Bool`, `Float`, `Double`, `String`, `Character`, `Date`, `UUID`, `URL`, `Data`, `Decimal`, `CGFloat`) produce full generators with size scaling, boundary analysis, and shrinking support. `Optional`, `Array`, `Dictionary`, and `Set` produce full generators when their element types conform. `CaseIterable` enums produce even-weighted picks across all cases.
///
/// ## What Falls Back to `.just`
///
/// Types the decoder cannot synthesise a generator for — non-`CaseIterable` `RawRepresentable` enums, types with hand-written `init(from:)` that branch on decoded values, and any other type not covered above — fall back to `.just(decodedValue)`, pinning the field to the constant value from the JSON. The generator still works; those fields simply do not vary across iterations.
///
/// ## Limitations
///
/// The generator is forward-only. Reflection is not supported — ``#examine`` will report a forward-only warning on the top-level map. Reduction still works because the reducer operates on the choice sequence, not reflected values.
///
/// The ``ReflectiveGenerator/isSynthesized`` flag is set to `true` on the returned generator. Diagnostic tools can check this flag to identify `.just` nodes that represent fields the decoder could not generate.
///
/// - Note: Synthesized generators are approximately twice as slow per iteration as hand-written generators for the same type. The overhead comes from reconstructing each value through `init(from: Decoder)` — the only available construction path for types defined outside the test target — rather than calling the memberwise initializer directly. For hot-path benchmarks or large iteration counts, consider writing a generator by hand.
///
/// ```swift
/// let gen = try #gen(Person.self, from: """
///     {"name": "Alice", "age": 30, "active": true}
///     """)
///
/// #exhaust(gen) { person in
///     person.age >= 0
/// }
/// ```
///
/// - Parameters:
///   - type: The `Decodable` type to synthesise a generator for.
///   - string: Example JSON string whose structure matches `T`. The values are used only during the discovery pass and do not constrain the generator's output.
/// - Returns: A ``ReflectiveGenerator`` that produces arbitrary values of type `T`.
@freestanding(expression)
public macro gen<T: Decodable>(
    _ type: T.Type,
    from string: String
) -> ReflectiveGenerator<T> = #externalMacro(module: "ExhaustMacros", type: "GenerateFromDecodableMacro")
