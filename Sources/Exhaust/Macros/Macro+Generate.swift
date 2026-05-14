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
