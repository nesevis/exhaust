// Core fundamental operations for the generator combinators.
// These operations form the building blocks for more complex generator behavior.

/// Namespace for generator factory methods and combinators.
///
/// ``Gen`` provides a unified entry point to all generator construction. Import `Exhaust` and use `Gen.int(in:)`, `Gen.string()`, `Gen.pick(choices:)`, and so on, or use the ``#gen(_:transform:)`` macro for composing generators from existing ones.
package enum Gen {
    /// Computes a process-stable per-site fingerprint from source-location components.
    ///
    /// Folds the file identifier's UTF-8 bytes with a Fibonacci-hashing multiply-add (using ``Xoshiro256/goldenRatioConstant``), then mixes in the line and column through ``Xoshiro256/deriveSeed(from:at:)``. UTF-8 bytes and that arithmetic are reproducible across process launches, unlike `String.hashValue`, which SipHash randomizes per launch — so the same call site yields the same fingerprint every run, a prerequisite for using it as a CGS tuning seed and as a cross-process cache key. The multiply-add spreads distinct files across the full 64-bit range (the cross-file discrimination `String.hashValue` used to provide), while folding the components separately removes the transposition collision of the previous additive `hash &+ line &+ column` form, where for example `(line: 10, column: 5)` and `(line: 5, column: 10)` mapped to the same value.
    package static func sourceFingerprint(
        fileID: StaticString,
        line: UInt,
        column: UInt = 0
    ) -> UInt64 {
        var accumulator: UInt64 = 0
        if fileID.hasPointerRepresentation {
            fileID.withUTF8Buffer { bytes in
                for byte in bytes {
                    accumulator = Xoshiro256.fold(accumulator, mixing: UInt64(byte))
                }
            }
        } else {
            accumulator = UInt64(fileID.unicodeScalar.value)
        }
        accumulator = Xoshiro256.deriveSeed(from: accumulator, at: UInt64(line))
        return Xoshiro256.deriveSeed(from: accumulator, at: UInt64(column))
    }
}

package extension Gen {
    /// Injects a ``ReflectiveOperation`` into the ``FreerMonad`` spine as a single impure step.
    ///
    /// Entry point for building new combinators: every generator primitive bottoms out in a `liftF` call. The continuation casts the interpreter's `Any` result back to `Output` and throws ``GeneratorError/typeMismatch`` on failure (which indicates a framework bug, not user error).
    ///
    /// - Parameter operation: The low-level reflective operation to lift.
    /// - Returns: A generator that executes the operation and validates the result type.
    static func liftF<Output>(
        _ operation: ReflectiveOperation
    ) -> Generator<Output> {
        .impure(operation: operation) { result in
            if let typedResult = result as? Output {
                return .pure(typedResult)
            }
            throw GeneratorError.typeMismatch(
                expected: String(describing: Output.self),
                actual: String(describing: type(of: result))
            )
        }
    }

    /// Wraps a generator with a prune marker that tells the reflection interpreter to abandon this branch when a preceding ``contramap`` returns nil.
    ///
    /// Separate from ``contramap`` because the two responsibilities are distinct: contramap transforms the input, prune decides whether to continue. Merging them would force every contramap to handle the nil case even when failure is impossible. Use ``comap(_:_:)`` when you need both in a single call.
    ///
    /// - Parameter generator: The generator to wrap with a prune marker.
    /// - Returns: A generator that can be pruned during reflection.
    static func prune<Output>(
        _ generator: Generator<Output>
    ) -> Generator<Output> {
        liftF(.prune(next: generator.erase()))
    }

    /// Attaches a total backward transformation for reflection.
    ///
    /// Use contramap when the backward mapping always succeeds — for example, extracting a stored property or casting between related types. When the mapping can fail (returning nil to reject a reflection branch), use ``comap(_:_:)`` instead, which pairs the contramap with a ``prune``.
    ///
    /// - Parameters:
    ///   - transform: A function that extracts the inner generator's input from the outer type.
    ///   - generator: The generator to attach the backward transformation to.
    /// - Returns: A generator that applies `transform` during the reflection backward pass.
    static func contramap<NewInput, Output>(
        _ transform: @escaping (NewInput) throws -> some Any,
        _ generator: Generator<Output>
    ) -> Generator<Output> {
        .impure(operation: ReflectiveOperation.contramap(
            // This is where the backwards pass happens
            transform: {
                // Handle optional inputs
                guard let input = $0 as? NewInput else {
                    throw ReflectionError.contramapWasWrongType
                }
                return try transform(input) as Any
            },
            next: generator.erase()
        )) { result in
            if let typed = result as? Output {
                // Backward pass - direct value
                return .pure(typed)
            }
            throw GeneratorError.typeMismatch(
                expected: String(describing: Output.self),
                actual: String(describing: type(of: result))
            )
        }
    }

    /// Attaches a partial backward transformation that prunes on failure.
    ///
    /// Combines ``contramap`` with ``prune``: when `transform` returns nil, the reflection interpreter abandons this branch and tries alternatives. Use this when the backward mapping is partial — for example, when reflecting on an enum case that only matches one branch of a ``pick``.
    ///
    /// - Parameters:
    ///   - transform: A function that extracts the inner generator's input, returning nil to reject the branch.
    ///   - generator: The generator to attach the backward transformation to.
    /// - Returns: A generator that prunes during reflection when the transform returns nil.
    static func comap<NewInput, Output>(
        _ transform: @escaping (NewInput) throws -> (some Any)?,
        _ generator: Generator<Output>
    ) -> Generator<Output> {
        let contramapped: Generator<Output> = liftF(.contramap(
            transform: {
                guard let input = $0 as? NewInput else {
                    throw ReflectionError.contramapWasWrongType
                }
                return try transform(input)
            },
            next: generator.erase()
        ))
        return prune(contramapped)
    }
}
