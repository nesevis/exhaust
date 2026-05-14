public extension __ExhaustRuntime {
    /// Maps a single generator with a forward transform and Mirror-based backward extraction.
    ///
    /// This is **macro infrastructure** — it exists solely as an expansion target for the `#gen` macro when a single generator is combined with an initializer/enum-case call.
    static func _macroMap<Input, Output>(
        _ generator: ReflectiveGenerator<Input>,
        label: String,
        forward: @Sendable @escaping (Input) -> Output
    ) -> ReflectiveGenerator<Output> {
        Gen.contramap(
            { (output: Output) throws -> Any in
                guard let value = Self._mirrorExtract(output, label: label) else {
                    throw Interpreters.ReflectionError.contramapWasWrongType
                }
                return value
            },
            generator.gen.map(forward)
        ).wrapped
    }

    /// Maps a single generator with a failable backward closure for extraction.
    ///
    /// This is **macro infrastructure** for enum case generators. The backward closure uses pattern matching to extract associated values, returning `nil` when the enum value doesn't match the expected case.
    static func _macroMap<Input, Output>(
        _ generator: ReflectiveGenerator<Input>,
        backward: @Sendable @escaping (Output) -> Input?,
        forward: @Sendable @escaping (Input) -> Output
    ) -> ReflectiveGenerator<Output> {
        Gen.contramap(
            { (output: Output) throws -> Input in
                guard let input = backward(output) else {
                    throw Interpreters.ReflectionError.contramapWasWrongType
                }
                return input
            },
            generator.gen.map(forward)
        ).wrapped
    }

    /// Zips multiple generators with a forward transform and Mirror-based backward extraction.
    ///
    /// This is **macro infrastructure** — it exists solely as an expansion target for the `#gen` macro when multiple generators are combined with a labeled initializer call.
    static func _macroZip<each T, NewOutput>(
        _ generators: repeat ReflectiveGenerator<each T>,
        labels: [String],
        forward: @Sendable @escaping ((repeat each T)) -> NewOutput
    ) -> ReflectiveGenerator<NewOutput> {
        var erased: ContiguousArray<AnyGenerator> = []
        erased.reserveCapacity(5)
        for generator in repeat each generators {
            erased.append(generator.gen.erase())
        }

        let impure: Generator<[Any]> = .impure(
            operation: .zip(erased),
            continuation: { .pure($0 as! [Any]) }
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
            guard let values = Self._mirrorExtractAll(output, labels: labels) else {
                throw Interpreters.ReflectionError.contramapWasWrongType
            }
            return values
        }

        return Gen.contramap(backwardToArray, impure.map(forwardFromArray)).wrapped
    }

    /// Zips multiple generators with a failable backward closure for extraction.
    ///
    /// This is **macro infrastructure** for enum case generators with multiple associated values.
    static func _macroZip<each T, NewOutput>(
        _ generators: repeat ReflectiveGenerator<each T>,
        backward: @Sendable @escaping (NewOutput) -> [Any]?,
        forward: @Sendable @escaping ((repeat each T)) -> NewOutput
    ) -> ReflectiveGenerator<NewOutput> {
        var erased: ContiguousArray<AnyGenerator> = []
        erased.reserveCapacity(5)
        for generator in repeat each generators {
            erased.append(generator.gen.erase())
        }

        let impure: Generator<[Any]> = .impure(
            operation: .zip(erased),
            continuation: { .pure($0 as! [Any]) }
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

        return Gen.contramap(backwardToArray, impure.map(forwardFromArray)).wrapped
    }

    // MARK: - Scalar conversion overloads

    /// Scalar conversion for `BinaryInteger` → `BinaryInteger` (for example `UInt64` → `Int`).
    static func _macroMapScalar<Input: BinaryInteger, Output: BinaryInteger>(
        _ generator: ReflectiveGenerator<Input>,
        forward: @Sendable @escaping (Input) -> Output
    ) -> ReflectiveGenerator<Output> {
        generator.mapped(forward: forward, backward: { Input($0) })
    }

    /// Scalar conversion for `BinaryFloatingPoint` → `BinaryFloatingPoint` (for example `Double` → `Float`).
    static func _macroMapScalar<Input: BinaryFloatingPoint, Output: BinaryFloatingPoint>(
        _ generator: ReflectiveGenerator<Input>,
        forward: @Sendable @escaping (Input) -> Output
    ) -> ReflectiveGenerator<Output> {
        generator.mapped(forward: forward, backward: { Input($0) })
    }

    /// Unconstrained fallback — forward-only when no numeric protocol matches.
    static func _macroMapScalar<Input, Output>(
        _ generator: ReflectiveGenerator<Input>,
        forward: @Sendable @escaping (Input) -> Output
    ) -> ReflectiveGenerator<Output> {
        generator.map(forward)
    }

    // MARK: - Zip forwarding

    /// Forwarding wrapper for `Gen.zip`, used by macro expansion for the no-closure multi-generator overload.
    static func __zip<each T>(
        _ generators: repeat ReflectiveGenerator<each T>
    ) -> ReflectiveGenerator<(repeat each T)> {
        Gen.zip(repeat (each generators).gen).wrapped
    }
}
