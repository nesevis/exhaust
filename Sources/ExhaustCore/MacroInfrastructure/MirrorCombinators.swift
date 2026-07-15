public extension __ExhaustRuntime {
    /// Maps a single generator with a forward transform and Mirror-based backward extraction.
    ///
    /// This is **macro infrastructure** — it exists solely as an expansion target for the `#gen` macro when a single generator is combined with an initializer/enum-case call.
    static func _macroMap<Input, Output>(
        _ generator: ReflectiveGenerator<Input>,
        label: String,
        forward: @Sendable @escaping (Input) -> Output
    ) -> ReflectiveGenerator<Output> {
        // The macro derives the backward from the same member label the forward initializer consumes, so `_mirrorExtract` inverts the forward by construction of the expansion and the `.isomorph` guarantee holds. One transform node replaces the contramap + map sandwich this method emitted previously.
        Gen.liftF(.transform(
            kind: .isomorph(
                forward: { forward($0 as! Input) },
                backward: { output in
                    // Reflection probes pick branches against a shared final output, so a mismatched value is a normal rejection. Throw instead of trapping.
                    guard let typed = output as? Output,
                          let value = _mirrorExtract(typed, label: label)
                    else {
                        throw ReflectionError.contramapWasWrongType
                    }
                    return value
                },
                inputType: Input.self,
                outputType: Output.self
            ),
            inner: generator.gen.erase()
        )).wrapped
    }

    /// Maps a single generator through a qualified enum-case or static-factory call, validating the output shape during reflection.
    ///
    /// Swift syntax cannot distinguish `Pet.cat(value)` from `Factory.make(value)`. The backward path therefore accepts only a runtime enum value whose case name matches `caseName`. Static factories still generate values, but their non-enum outputs reject reflection.
    static func _macroMapEnumCase<Input, Output>(
        _ generator: ReflectiveGenerator<Input>,
        caseName: String,
        forward: @Sendable @escaping (Input) -> Output
    ) -> ReflectiveGenerator<Output> {
        _macroMap(
            generator,
            backward: { output in
                guard let payloadValues = _mirrorExtractEnumCase(
                    output,
                    caseName: caseName,
                    associatedValueCount: 1
                ),
                    payloadValues.count == 1
                else {
                    return nil
                }
                return payloadValues[0] as? Input
            },
            forward: forward
        )
    }

    /// Maps a single generator with a failable backward closure for extraction.
    ///
    /// This is **macro infrastructure** for enum case generators. The backward closure uses pattern matching to extract associated values, returning `nil` when the enum value doesn't match the expected case.
    static func _macroMap<Input, Output>(
        _ generator: ReflectiveGenerator<Input>,
        backward: @Sendable @escaping (Output) -> Input?,
        forward: @Sendable @escaping (Input) -> Output
    ) -> ReflectiveGenerator<Output> {
        // The macro expands an enum case constructor to the forward closure and a pattern match over the same case to the backward, so the pair inverts by construction. A `nil` from the pattern match means a different case: a normal rejection during pick-branch probing, surfaced as a throw.
        Gen.liftF(.transform(
            kind: .isomorph(
                forward: { forward($0 as! Input) },
                backward: { output in
                    guard let typed = output as? Output,
                          let input = backward(typed)
                    else {
                        throw ReflectionError.contramapWasWrongType
                    }
                    return input
                },
                inputType: Input.self,
                outputType: Output.self
            ),
            inner: generator.gen.erase()
        )).wrapped
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

    /// Zips generators through a qualified enum-case or static-factory call, validating the output shape during reflection.
    ///
    /// `parameterOrder` maps generator order to associated-value order. Non-enum factory outputs and other enum cases reject reflection without requiring the macro to synthesize a case pattern that may not compile.
    static func _macroZipEnumCase<each Input, Output>(
        _ generators: repeat ReflectiveGenerator<each Input>,
        caseName: String,
        parameterOrder: [Int],
        forward: @Sendable @escaping ((repeat each Input)) -> Output
    ) -> ReflectiveGenerator<Output> {
        let backward: @Sendable (Output) -> [Any]? = { output in
            guard let payloadValues = _mirrorExtractEnumCase(
                output,
                caseName: caseName,
                associatedValueCount: parameterOrder.count
            ),
                payloadValues.count == parameterOrder.count,
                parameterOrder.allSatisfy(payloadValues.indices.contains)
            else {
                return nil
            }
            return parameterOrder.map { payloadValues[$0] }
        }
        return _macroZip(
            repeat each generators,
            backward: backward,
            forward: forward
        )
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
