// Operations for controlling and accessing the size parameter in generators.
// The size parameter is used to control the complexity and scale of generated values.

extension Gen {
    /// Retrieves the raw size parameter without a backward comap.
    ///
    /// Internal callers that need the raw size operation should use this. All public-facing
    /// size access goes through ``getSize(_:)`` which wraps the result in a `._bound` with
    /// `backward: { _ in 100 }`, giving the reducer a usable default.
    static func rawGetSize() -> ReflectiveGenerator<UInt64> {
        .impure(operation: .getSize) { result in
            if let typedResult = result as? UInt64 {
                return .pure(typedResult)
            }
            throw GeneratorError.typeMismatch(
                expected: "\(UInt64.self)",
                actual: String(describing: type(of: result))
            )
        }
    }
}

public extension Gen {
    /// Retrieves the current size parameter and feeds it into a generator-producing closure.
    ///
    /// The size parameter controls how complex generated values should be. It typically starts small and grows as tests progress, allowing the system to find simple counterexamples first before exploring more complex cases. The closure receives the current size (1-100) and returns a generator to run.
    ///
    /// Internally, this wraps the size lookup in a backward comap of 100, so that the reducer always sees the full range when reducing through size-dependent generators.
    ///
    /// - Parameter forward: A closure that receives the current size and returns a generator.
    /// - Returns: A generator that produces the result of the size-dependent inner generator.
    static func getSize<Output>(
        _ forward: @escaping (UInt64) -> ReflectiveGenerator<Output>
    ) -> ReflectiveGenerator<Output> {
        rawGetSize()._bound(forward: forward, backward: { _ in 100 })
    }

    /// Creates a generator with a temporarily modified size parameter.
    ///
    /// This combinator allows you to override the current size parameter for a specific generator and its nested generators. This is useful when you need to:
    /// - Generate smaller nested structures to avoid exponential growth
    /// - Create test cases with specific size requirements
    /// - Control recursion depth in complex data structures
    /// - Generate collections of a specific scale regardless of the global size
    ///
    /// The size modification only affects the provided generator and any generators it calls internally. Once the resized generator completes, the original size parameter is restored.
    ///
    /// - Parameters:
    ///   - newSize: The size parameter to use for the nested generator
    ///   - generator: The generator to run with the modified size
    /// - Returns: A generator that runs with the specified size parameter
    /// - Note: Size handling may need refinement in future versions
    static func resize<Output>(
        _ newSize: UInt64,
        _ generator: ReflectiveGenerator<Output>
    ) -> ReflectiveGenerator<Output> {
        liftF(.resize(newSize: newSize, next: generator.erase()))
    }
}
