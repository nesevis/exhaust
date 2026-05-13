/// Combines ``RefGen`` generators through a transform closure, synthesizing a bidirectional backward mapping when possible.
///
/// Behaves identically to ``gen(_:transform:)`` but operates on ``RefGen`` values.
///
/// ```swift
/// let personGen = #refGen(nameGen, ageGen) { name, age in
///     Person(name: name, age: age)
/// }
/// ```
@freestanding(expression)
public macro refGen<each GeneratedValue, TransformedValue>(
    _ generators: repeat RefGen<each GeneratedValue>,
    transform: (repeat each GeneratedValue) -> TransformedValue
) -> RefGen<TransformedValue> = #externalMacro(module: "ExhaustMacros", type: "GenerateMacro")

/// Wraps a single ``RefGen`` expression, enabling dot-syntax (for example `.int(in: 0...100)`).
///
/// ```swift
/// let gen = #refGen(.int(in: 0...100))
/// ```
@freestanding(expression)
public macro refGen<GeneratedValue>(
    _ generator: RefGen<GeneratedValue>
) -> RefGen<GeneratedValue> = #externalMacro(module: "ExhaustMacros", type: "GenerateMacro")

/// Combines multiple ``RefGen`` generators into a tuple without transformation.
///
/// ```swift
/// let pair = #refGen(.int(in: 0...10), .asciiString(length: 1...5))
/// ```
@freestanding(expression)
public macro refGen<each GeneratedValue>(
    _ generators: repeat RefGen<each GeneratedValue>
) -> RefGen<(repeat each GeneratedValue)> = #externalMacro(module: "ExhaustMacros", type: "GenerateMacro")
