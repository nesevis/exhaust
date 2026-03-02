/// Runs a property test on the given generator with optional settings.
///
/// The macro captures the property closure's source code at compile time for
/// inclusion in log output when a counterexample is found.
///
/// ## Trailing closure (source code captured)
/// ```swift
/// let counterexample = #exhaust(personGen, .maxIterations(1000)) { person in
///     person.age >= 0
/// }
/// ```
///
/// ## Function reference (no source capture)
/// ```swift
/// let counterexample = #exhaust(personGen, .replay(42), property: isValid)
/// ```
///
/// - Returns: The shrunk counterexample if the property fails, or `nil` if all iterations pass.
@_spi(ExhaustInternal) import ExhaustCore

@freestanding(expression)
@discardableResult
public macro exhaust<T>(
    _ gen: ReflectiveGenerator<T>,
    _ settings: ExhaustSettings<T>...,
    property: (T) throws -> Bool,
) -> T? = #externalMacro(module: "ExhaustMacros", type: "ExhaustTestMacro")
