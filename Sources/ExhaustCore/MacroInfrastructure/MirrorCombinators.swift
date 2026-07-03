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
                guard let value = _mirrorExtract(output, label: label) else {
                    throw ReflectionError.contramapWasWrongType
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
                    throw ReflectionError.contramapWasWrongType
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

        let zipNode: AnyGenerator = .impure(
            operation: .zip(erased),
            continuation: { .pure($0) }
        )

        // The macro expands an initializer call to the forward closure and derives the backward from the same member labels, so the pair inverts by construction of the expansion and the `.isomorph` guarantee holds without user involvement.
        return Gen.liftF(.transform(
            kind: .isomorph(
                forward: { anyValues in
                    let values = anyValues as! [Any]
                    var index = 0
                    func next<Element>(_: Element.Type) -> Element {
                        defer { index += 1 }
                        return values[index] as! Element
                    }
                    return forward((repeat next((each T).self)))
                },
                backward: { output in
                    // Reflection probes pick branches against a shared final output, so a mismatched value is a normal rejection. Throw instead of trapping.
                    guard let typed = output as? NewOutput,
                          let values = Self._mirrorExtractAll(typed, labels: labels)
                    else {
                        throw ReflectionError.contramapWasWrongType
                    }
                    return values
                },
                inputType: [Any].self,
                outputType: NewOutput.self
            ),
            inner: zipNode
        )).wrapped
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

        let zipNode: AnyGenerator = .impure(
            operation: .zip(erased),
            continuation: { .pure($0) }
        )

        // The macro expands an enum case constructor to the forward closure and a pattern match over the same case to the backward, so the pair inverts by construction of the expansion. A `nil` from the pattern match means the value is a different case: a normal rejection during pick-branch probing, surfaced as a throw.
        return Gen.liftF(.transform(
            kind: .isomorph(
                forward: { anyValues in
                    let values = anyValues as! [Any]
                    var index = 0
                    func next<Element>(_: Element.Type) -> Element {
                        defer { index += 1 }
                        return values[index] as! Element
                    }
                    return forward((repeat next((each T).self)))
                },
                backward: { output in
                    guard let typed = output as? NewOutput,
                          let values = backward(typed)
                    else {
                        throw ReflectionError.contramapWasWrongType
                    }
                    return values
                },
                inputType: [Any].self,
                outputType: NewOutput.self
            ),
            inner: zipNode
        )).wrapped
    }

    // MARK: - Scalar conversion overloads

    /// Scalar conversion for `BinaryInteger` → `BinaryInteger` (for example `UInt64` → `Int`).
    ///
    /// The `SendableMetatype` constraints let the reified `mapped(forward:backward:)` capture the generic metatypes in its `@Sendable` transform closures without a strict-concurrency diagnostic. Every standard numeric type satisfies them.
    static func _macroMapScalar<Input: BinaryInteger & SendableMetatype, Output: BinaryInteger & SendableMetatype>(
        _ generator: ReflectiveGenerator<Input>,
        forward: @Sendable @escaping (Input) -> Output
    ) -> ReflectiveGenerator<Output> {
        generator.mapped(forward: forward, backward: { Input($0) })
    }

    /// Scalar conversion for `BinaryFloatingPoint` → `BinaryFloatingPoint` (for example `Double` → `Float`).
    ///
    /// See the `BinaryInteger` overload for why the `SendableMetatype` constraints are present.
    static func _macroMapScalar<Input: BinaryFloatingPoint & SendableMetatype, Output: BinaryFloatingPoint & SendableMetatype>(
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
