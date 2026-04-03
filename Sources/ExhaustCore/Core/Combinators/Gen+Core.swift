// Core fundamental operations for the generator combinators.
// These operations form the building blocks for more complex generator behavior.

public enum Gen {}

public extension Gen {
    /// Lifts a reflective operation into a generator with type-safe result handling.
    ///
    /// This is the fundamental operation that bridges between raw reflective operations and type-safe generators. It handles the unsafe casting and error reporting when the reflection system returns unexpected types.
    ///
    /// - Parameter operation: The low-level reflective operation to lift
    /// - Returns: A generator that executes the operation and validates the result type
    static func liftF<Output>(
        _ operation: ReflectiveOperation
    ) -> ReflectiveGenerator<Output> {
        .impure(operation: operation) { result in
            if let typedResult = result as? Output {
                return .pure(typedResult)
            }
            throw Interpreters.ReflectionError.reflectedNil(
                type: String(describing: Output.self),
                resultType: String(describing: result.self)
            )
        }
    }

    /// Applies a pruning operation to a generator.
    ///
    /// Pruning is used during reduction to eliminate branches that don't contribute to the final result. This optimization helps make property-based testing more efficient by focusing on relevant test cases.
    ///
    /// - Parameter generator: The generator to apply pruning to
    /// - Returns: A generator with pruning applied
    static func prune<Output>(
        _ generator: ReflectiveGenerator<Output>
    ) -> ReflectiveGenerator<Output> {
        liftF(.prune(next: generator.erase()))
    }

    /// Applies a contravariant transformation to a generator's input during reflection.
    ///
    /// This is the fundamental operation for transforming inputs in the backward direction during reflection. It allows a generator expecting one input type to work with a different input type via a transformation function.
    ///
    /// - Parameters:
    ///   - transform: A function that transforms the new input type to the expected input type
    ///   - generator: The generator to apply the transformation to
    /// - Returns: A generator that accepts the new input type
    static func contramap<NewInput, Output>(
        _ transform: @escaping (NewInput) throws -> some Any,
        _ generator: ReflectiveGenerator<Output>
    ) -> ReflectiveGenerator<Output> {
        .impure(operation: ReflectiveOperation.contramap(
            // This is where the backwards pass happens
            transform: {
                // Handle optional inputs
                guard let input = $0 as? NewInput else {
                    throw Interpreters.ReflectionError.contramapWasWrongType
                }
                return try transform(input) as Any
            },
            next: generator.erase()
        )) { result in
            if let typed = result as? Output {
                // Backward pass - direct value
                return .pure(typed)
            }
            if let optional = result as? Output?, optional == nil {
                throw Interpreters.ReflectionError.reflectedNil(
                    type: String(describing: Output.self),
                    resultType: String(describing: type(of: result))
                )
            }
            throw GeneratorError.typeMismatch(
                expected: String(describing: Output.self),
                actual: String(describing: type(of: result))
            )
        }
    }

    /// Applies a contravariant transformation with optional failure handling.
    ///
    /// This is a specialized version of `contramap` that combines transformation with pruning.
    /// If the transformation returns nil, the generator branch is pruned during reflection.
    /// This is useful for generators that should only succeed under certain conditions.
    ///
    /// - Parameters:
    ///   - transform: A function that transforms the input, returning nil to indicate failure
    ///   - generator: The generator to apply the transformation to
    /// - Returns: A generator that prunes on transformation failure
    static func comap<NewInput, Output>(
        _ transform: @escaping (NewInput) throws -> (some Any)?,
        _ generator: ReflectiveGenerator<Output>
    ) -> ReflectiveGenerator<Output> {
        contramap(transform, prune(generator))
    }
}
