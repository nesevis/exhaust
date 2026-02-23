/// Constructs a `ReflectiveGenerator` from one or more generators and a transform closure.
///
/// When the closure body is a struct or class initializer call with labeled arguments
/// that map 1:1 to the closure parameters, the macro automatically synthesizes a
/// backward mapping using property access, producing a fully bidirectional generator
/// via `.mapped(forward:backward:)`.
///
/// When backward inference is not possible (complex expressions, shorthand parameters,
/// multi-statement bodies), the macro falls back to a forward-only `.map` and emits
/// a warning explaining why.
///
/// ## Single Generator
/// ```swift
/// let personGen = #generate(nameGen) { name in
///     Person(name: name)
/// }
/// // Expands to: nameGen.mapped(forward: { name in Person(name: name) }, backward: { $0.name })
/// ```
///
/// ## Multiple Generators
/// ```swift
/// let personGen = #generate(nameGen, ageGen) { name, age in
///     Person(name: name, age: age)
/// }
/// // Expands to: Gen.zip(nameGen, ageGen).mapped(
/// //     forward: { name, age in Person(name: name, age: age) },
/// //     backward: { ($0.name, $0.age) }
/// // )
/// ```
@freestanding(expression)
public macro generate<each T, R>(
    _ generators: repeat ReflectiveGenerator<each T>,
    transform: (repeat each T) -> R
) -> ReflectiveGenerator<R> = #externalMacro(module: "ExhaustMacros", type: "GenerateMacro")
