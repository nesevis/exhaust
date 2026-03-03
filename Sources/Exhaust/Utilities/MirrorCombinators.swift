@_spi(ExhaustInternal) import ExhaustCore

public extension __ExhaustRuntime {
    /// Maps a single generator with a forward transform and Mirror-based backward extraction.
    ///
    /// This is **macro infrastructure** — it exists solely as an expansion target for the
    /// `#gen` macro when a single generator is combined with an initializer/enum-case call.
    /// It must be `public` because macro expansions emit code at the call site.
    ///
    /// ## Why this exists
    ///
    /// The generator argument needs its own type-inference context so that dot-syntax
    /// expressions (e.g. `.int()`) resolve against `ReflectiveGenerator<Input>` rather
    /// than the macro's return type `ReflectiveGenerator<Output>`.
    ///
    /// - Parameters:
    ///   - generator: The input generator.
    ///   - label: The Mirror child label for backward extraction.
    ///   - forward: The user's transform closure.
    /// - Returns: A bidirectional generator that can be reflected backward via Mirror.
    static func _macroMap<Input, Output>(
        _ generator: ReflectiveGenerator<Input>,
        label: String,
        forward: @escaping (Input) -> Output,
    ) -> ReflectiveGenerator<Output> {
        Gen.contramap(
            { _mirrorExtract($0, label: label) },
            generator.map(forward),
        )
    }

    /// Maps a single generator with a failable backward closure for extraction.
    ///
    /// This is **macro infrastructure** for enum case generators. The backward closure
    /// uses pattern matching to extract associated values, returning `nil` when the
    /// enum value doesn't match the expected case. This enables `pick` to prune
    /// non-matching branches during reflection.
    ///
    /// The pattern-matching approach is inspired by
    /// [swift-case-paths](https://github.com/pointfreeco/swift-case-paths)
    /// by Point-Free, which uses `guard case let` for enum associated value extraction.
    ///
    /// - Parameters:
    ///   - generator: The input generator.
    ///   - backward: Failable extraction closure. Returns `nil` for non-matching cases.
    ///   - forward: The user's transform closure.
    /// - Returns: A bidirectional generator with case-discriminating backward mapping.
    static func _macroMap<Input, Output>(
        _ generator: ReflectiveGenerator<Input>,
        backward: @escaping (Output) -> Input?,
        forward: @escaping (Input) -> Output,
    ) -> ReflectiveGenerator<Output> {
        Gen.contramap(
            { (output: Output) throws -> Input in
                guard let input = backward(output) else {
                    throw Interpreters.ReflectionError.contramapWasWrongType
                }
                return input
            },
            generator.map(forward),
        )
    }

    /// Zips multiple generators with a forward transform and Mirror-based backward extraction.
    ///
    /// This is **macro infrastructure** — it exists solely as an expansion target for the
    /// `#gen` macro when multiple generators are combined with a labeled initializer call.
    /// It must be `public` because macro expansions emit code at the call site (in the
    /// user's module), but it is not intended for direct use.
    ///
    /// ## Why this exists
    ///
    /// `Gen.zip(a, b).mapped(forward:backward:)` requires the `backward` closure to
    /// return the zip's tuple type (e.g. `(String, Int)`). The `#gen` macro doesn't have
    /// type information — it only knows argument labels — so it can't synthesize typed
    /// casts for each tuple element. This function sidesteps the problem by operating
    /// entirely at the `[Any]` level: the backward pass uses `Mirror` to extract child
    /// values by label into `[Any]`, and the forward pass reconstructs the typed tuple
    /// via parameter pack iteration over the `[Any]` array.
    ///
    /// - Parameters:
    ///   - generators: The generators to zip, one per struct/class init parameter.
    ///   - labels: Argument labels from the initializer call, ordered to match generator
    ///     position. Used by Mirror to extract the corresponding property values in the
    ///     backward pass.
    ///   - forward: The user's transform closure (e.g. `{ name, age in Person(name: name, age: age) }`).
    /// - Returns: A bidirectional generator that can be reflected backward via Mirror.
    static func _macroZip<each T, NewOutput>(
        _ generators: repeat ReflectiveGenerator<each T>,
        labels: [String],
        forward: @escaping ((repeat each T)) -> NewOutput,
    ) -> ReflectiveGenerator<NewOutput> {
        var erased: ContiguousArray<ReflectiveGenerator<Any>> = []
        erased.reserveCapacity(5)
        for generator in repeat each generators {
            erased.append(generator.erase())
        }

        let impure: ReflectiveGenerator<[Any]> = .impure(
            operation: .zip(erased),
            continuation: { .pure($0 as! [Any]) },
        )

        let forwardFromArray: ([Any]) -> NewOutput = { values in
            var index = 0
            func next<U>(_: U.Type) -> U {
                defer { index += 1 }
                return values[index] as! U
            }
            return forward((repeat next((each T).self)))
        }

        let backwardToArray: (NewOutput) -> [Any] = { output in
            _mirrorExtractAll(output, labels: labels)
        }

        return Gen.contramap(backwardToArray, impure.map(forwardFromArray))
    }

    /// Zips multiple generators with a failable backward closure for extraction.
    ///
    /// This is **macro infrastructure** for enum case generators with multiple
    /// associated values. The backward closure uses pattern matching to extract
    /// associated values, returning `nil` when the enum value doesn't match.
    ///
    /// The pattern-matching approach is inspired by
    /// [swift-case-paths](https://github.com/pointfreeco/swift-case-paths)
    /// by Point-Free, which uses `guard case let` for enum associated value extraction.
    ///
    /// - Parameters:
    ///   - generators: The generators to zip, one per associated value.
    ///   - backward: Failable extraction closure. Returns `nil` for non-matching cases.
    ///     Values must be in generator order.
    ///   - forward: The user's transform closure.
    /// - Returns: A bidirectional generator with case-discriminating backward mapping.
    static func _macroZip<each T, NewOutput>(
        _ generators: repeat ReflectiveGenerator<each T>,
        backward: @escaping (NewOutput) -> [Any]?,
        forward: @escaping ((repeat each T)) -> NewOutput,
    ) -> ReflectiveGenerator<NewOutput> {
        var erased: ContiguousArray<ReflectiveGenerator<Any>> = []
        erased.reserveCapacity(5)
        for generator in repeat each generators {
            erased.append(generator.erase())
        }

        let impure: ReflectiveGenerator<[Any]> = .impure(
            operation: .zip(erased),
            continuation: { .pure($0 as! [Any]) },
        )

        let forwardFromArray: ([Any]) -> NewOutput = { values in
            var index = 0
            func next<U>(_: U.Type) -> U {
                defer { index += 1 }
                return values[index] as! U
            }
            return forward((repeat next((each T).self)))
        }

        let backwardToArray: (NewOutput) throws -> [Any] = { output in
            guard let values = backward(output) else {
                throw Interpreters.ReflectionError.contramapWasWrongType
            }
            return values
        }

        return Gen.contramap(backwardToArray, impure.map(forwardFromArray))
    }

    // MARK: - Scalar conversion overloads

    /// Scalar conversion for `BinaryInteger` → `BinaryInteger` (e.g. `UInt64` → `Int`).
    ///
    /// This is **macro infrastructure** — the `#gen` macro emits calls to `_macroMapScalar`
    /// for single-generator, unlabeled-argument closures like `{ Int($0) }`. Swift's overload
    /// resolution picks the most constrained matching overload at compile time.
    @inlinable
    static func _macroMapScalar<Input: BinaryInteger, Output: BinaryInteger>(
        _ generator: ReflectiveGenerator<Input>,
        forward: @escaping (Input) -> Output,
    ) -> ReflectiveGenerator<Output> {
        generator.mapped(forward: forward, backward: { Input($0) })
    }

    /// Scalar conversion for `BinaryFloatingPoint` → `BinaryFloatingPoint` (e.g. `Double` → `Float`).
    @inlinable
    static func _macroMapScalar<Input: BinaryFloatingPoint, Output: BinaryFloatingPoint>(
        _ generator: ReflectiveGenerator<Input>,
        forward: @escaping (Input) -> Output,
    ) -> ReflectiveGenerator<Output> {
        generator.mapped(forward: forward, backward: { Input($0) })
    }

    /// Unconstrained fallback — forward-only when no numeric protocol matches.
    @inlinable
    static func _macroMapScalar<Input, Output>(
        _ generator: ReflectiveGenerator<Input>,
        forward: @escaping (Input) -> Output,
    ) -> ReflectiveGenerator<Output> {
        generator.map(forward)
    }

    // MARK: - Zip forwarding

    /// Forwarding wrapper for `Gen.zip`, used by macro expansion for the no-closure
    /// multi-generator overload (e.g. `#gen(a, b)` with no trailing closure).
    static func __zip<each T>(
        _ generators: repeat ReflectiveGenerator<each T>,
    ) -> ReflectiveGenerator<(repeat each T)> {
        Gen.zip(repeat each generators)
    }
}
