// Core fundamental operations for the generator combinators.
// These operations form the building blocks for more complex generator behavior.

/// Namespace for generator factory methods and combinators.
///
/// ``Gen`` provides a unified entry point to all generator construction. Import `Exhaust` and use `Gen.int(in:)`, `Gen.string()`, `Gen.pick(choices:)`, and so on, or use the ``#gen(_:transform:)`` macro for composing generators from existing ones.
package enum Gen {
    /// Set by the generation pipeline to signal that ``.filter`` is being constructed during interpretation (inside a bind continuation) rather than at top level. When true, ``.filter`` defers CGS tuning to the interpreter's fingerprint-keyed cache instead of tuning eagerly.
    @TaskLocal package static var isInterpreting: Bool = false
}

package extension Gen {
    /// Lifts a reflective operation into a generator with type-safe result handling.
    ///
    /// Wraps a ``ReflectiveOperation`` in a type-safe generator by injecting it into the ``FreerMonad`` spine as an impure step. The returned generator handles the unsafe casting and reports an error when the reflection system returns an unexpected type.
    ///
    /// - Parameter operation: The low-level reflective operation to lift.
    /// - Returns: A generator that executes the operation and validates the result type.
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
    /// - Parameter generator: The generator to apply pruning to.
    /// - Returns: A generator with pruning applied.
    static func prune<Output>(
        _ generator: ReflectiveGenerator<Output>
    ) -> ReflectiveGenerator<Output> {
        liftF(.prune(next: generator.erase()))
    }

    /// Applies a contravariant transformation to a generator's input during reflection.
    ///
    /// Attaches a backward transformation that the reflection interpreter applies when walking the generator in reverse. This allows a generator expecting one input type to work with a different input type via a transformation function.
    ///
    /// - Parameters:
    ///   - transform: A function that transforms the new input type to the expected input type.
    ///   - generator: The generator to apply the transformation to.
    /// - Returns: A generator that accepts the new input type.
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
    /// This is a specialized version of ``contramap`` that combines transformation with pruning.
    /// If the transformation returns nil, the generator branch is pruned during reflection.
    /// This is useful for generators that should only succeed under certain conditions.
    ///
    /// - Parameters:
    ///   - transform: A function that transforms the input, returning nil to indicate failure.
    ///   - generator: The generator to apply the transformation to.
    /// - Returns: A generator that prunes on transformation failure.
    static func comap<NewInput, Output>(
        _ transform: @escaping (NewInput) throws -> (some Any)?,
        _ generator: ReflectiveGenerator<Output>
    ) -> ReflectiveGenerator<Output> {
        contramap(transform, prune(generator))
    }
}
