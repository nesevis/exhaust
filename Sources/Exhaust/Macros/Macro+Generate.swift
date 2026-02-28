/// Constructs a `ReflectiveGenerator` from one or more generators and a transform closure.
///
/// When the closure body is a struct or class initializer call with labeled arguments
/// that map 1:1 to the closure parameters, the macro automatically synthesizes a
/// Mirror-based backward mapping, producing a fully bidirectional generator. Using
/// `Mirror` allows the backward pass to work regardless of property access control.
///
/// When backward inference is not possible (complex expressions, multi-statement bodies),
/// the macro falls back to a forward-only `.map` and emits a warning explaining why.
///
/// Both named parameters and shorthand parameters (`$0`, `$1`, …) are supported for
/// bidirectional mapping — the labels come from the call-site argument labels, while
/// the shorthand indices provide the positional correspondence to generators.
///
/// ## Single Generator
/// ```swift
/// let personGen = #gen(nameGen) { name in
///     Person(name: name)
/// }
/// // Expands to: Gen.contramap({ _mirrorExtract($0, label: "name") }, nameGen.map { ... })
/// ```
///
/// ## Multiple Generators
/// ```swift
/// let personGen = #gen(nameGen, ageGen) { name, age in
///     Person(name: name, age: age)
/// }
/// // Expands to: Gen._macroZip(nameGen, ageGen, labels: ["name", "age"], forward: { ... })
/// ```
///
/// ## Shorthand Parameters
/// ```swift
/// let personGen = #gen(nameGen, ageGen) { Person(name: $0, age: $1) }
/// // Expands to: Gen._macroZip(nameGen, ageGen, labels: ["name", "age"], forward: { ... })
/// ```
@_spi(ExhaustInternal) import ExhaustCore

@freestanding(expression)
public macro gen<each T, R>(
    _ generators: repeat ReflectiveGenerator<each T>,
    transform: (repeat each T) -> R,
) -> ReflectiveGenerator<R> = #externalMacro(module: "ExhaustMacros", type: "GenerateMacro")

/// Composes one or more generators without a transform closure.
///
/// A single generator is passed through unchanged. Multiple generators are
/// combined with `Gen.zip`, producing a tuple generator.
///
/// ```swift
/// let intGen: ReflectiveGenerator<Int> = #gen(.int())
/// let pairGen: ReflectiveGenerator<(Int, String)> = #gen(.int(), .string())
/// ```
@freestanding(expression)
public macro gen<each T>(
    _ generators: repeat ReflectiveGenerator<each T>,
) -> ReflectiveGenerator<(repeat each T)> = #externalMacro(module: "ExhaustMacros", type: "GenerateMacro")
