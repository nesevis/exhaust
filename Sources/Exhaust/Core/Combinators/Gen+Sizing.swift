/// Operations for controlling and accessing the size parameter in generators.
/// The size parameter is used to control the complexity and scale of generated values.
@_spi(ExhaustInternal) import ExhaustCore

public extension Gen {
    /// Retrieves the current size parameter controlling generator complexity.
    ///
    /// The size parameter is a fundamental concept in property-based testing that controls
    /// how complex the generated values should be. It typically starts small and grows
    /// as tests progress, allowing the system to find simple counterexamples first before
    /// exploring more complex cases.
    ///
    /// Common uses:
    /// - Controlling array/collection lengths
    /// - Setting bounds for numeric ranges
    /// - Determining recursion depth in tree structures
    /// - Scaling the complexity of generated data structures
    ///
    /// - Returns: A generator that produces the current size parameter as a UInt64
    @inlinable
    static func getSize() -> ReflectiveGenerator<UInt64> {
        .impure(operation: .getSize) { result in
            if let typedResult = result as? UInt64 {
                return .pure(typedResult)
            }
            throw GeneratorError.typeMismatch(
                expected: "\(UInt64.self)",
                actual: String(describing: type(of: result)),
            )
        }
    }

    /// Creates a generator with a temporarily modified size parameter.
    ///
    /// This combinator allows you to override the current size parameter for a specific
    /// generator and its nested generators. This is useful when you need to:
    /// - Generate smaller nested structures to avoid exponential growth
    /// - Create test cases with specific size requirements
    /// - Control recursion depth in complex data structures
    /// - Generate collections of a specific scale regardless of the global size
    ///
    /// The size modification only affects the provided generator and any generators
    /// it calls internally. Once the resized generator completes, the original size
    /// parameter is restored.
    ///
    /// - Parameters:
    ///   - newSize: The size parameter to use for the nested generator
    ///   - generator: The generator to run with the modified size
    /// - Returns: A generator that runs with the specified size parameter
    /// - Note: Size handling may need refinement in future versions
    @inlinable
    static func resize<Output>(
        _ newSize: UInt64,
        _ generator: ReflectiveGenerator<Output>,
    ) -> ReflectiveGenerator<Output> {
        liftF(.resize(newSize: newSize, next: generator.erase()))
    }
}
