/// Constructs a ``ReflectiveGenerator`` from one or more component generators and a transform closure.
///
/// When the closure body is a struct or class initializer call with labeled arguments that map one-to-one to the closure parameters, the macro automatically synthesizes a `Mirror`-based backward mapping, producing a fully bidirectional generator. Using `Mirror` allows the backward pass to work regardless of property access control.
///
/// When backward inference is not possible (complex expressions, multi-statement bodies), the macro falls back to a forward-only `.map` and emits a warning explaining why.
///
/// Both named parameters and shorthand parameters (`$0`, `$1`, and so on) are supported for bidirectional mapping — the labels come from the call-site argument labels, while the shorthand indices provide the positional correspondence to generators.
///
/// Single generator:
///
/// ```swift
/// let personGen = #gen(nameGen) { name in
///     Person(name: name)
/// }
/// ```
///
/// Multiple generators:
///
/// ```swift
/// let personGen = #gen(nameGen, ageGen) { name, age in
///     Person(name: name, age: age)
/// }
/// ```
///
/// Shorthand parameters:
///
/// ```swift
/// let personGen = #gen(nameGen, ageGen) { Person(name: $0, age: $1) }
/// ```
import ExhaustCore

@freestanding(expression)
public macro gen<each GeneratedValue, TransformedValue>(
    _ generators: repeat ReflectiveGenerator<each GeneratedValue>,
    transform: (repeat each GeneratedValue) -> TransformedValue
) -> ReflectiveGenerator<TransformedValue> = #externalMacro(module: "ExhaustMacros", type: "GenerateMacro")

/// Passes a single generator through unchanged.
///
/// This concrete overload avoids the parameter-pack return type `(repeat each GeneratedValue)` which wraps a single `GeneratedValue` in a spurious tuple.
///
/// ```swift
/// let intGen: ReflectiveGenerator<Int> = #gen(.int())
/// ```
@freestanding(expression)
public macro gen<GeneratedValue>(
    _ generator: ReflectiveGenerator<GeneratedValue>
) -> ReflectiveGenerator<GeneratedValue> = #externalMacro(module: "ExhaustMacros", type: "GenerateMacro")

/// Composes two or more generators without a transform closure, combining them with `Gen.zip` to produce a tuple generator.
///
/// ```swift
/// let pairGen: ReflectiveGenerator<(Int, String)> = #gen(.int(), .string())
/// ```
@freestanding(expression)
public macro gen<each GeneratedValue>(
    _ generators: repeat ReflectiveGenerator<each GeneratedValue>
) -> ReflectiveGenerator<(repeat each GeneratedValue)> = #externalMacro(module: "ExhaustMacros", type: "GenerateMacro")
