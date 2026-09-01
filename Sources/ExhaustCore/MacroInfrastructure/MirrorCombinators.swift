public extension __ExhaustRuntime {
    /// Maps a single generator with a forward transform and Mirror-based backward extraction.
    ///
    /// This is **macro infrastructure**: it exists solely as an expansion target for the `#gen` macro when a single generator is combined with an initializer/enum-case call.
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
        )).wrapped(isReflective: generator.isReflective)
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
        )).wrapped(isReflective: generator.isReflective)
    }

    /// Zips multiple generators with a forward transform and Mirror-based backward extraction.
    ///
    /// This is **macro infrastructure**: it exists solely as an expansion target for the `#gen` macro when multiple generators are combined with a labeled initializer call.
    static func _macroZip<each T, NewOutput>(
        _ generators: repeat ReflectiveGenerator<each T>,
        labels: [String],
        forward: @Sendable @escaping ((repeat each T)) -> NewOutput
    ) -> ReflectiveGenerator<NewOutput> {
        var erased: ContiguousArray<AnyGenerator> = []
        erased.reserveCapacity(5)
        var allReflective = true
        for generator in repeat each generators {
            erased.append(generator.gen.erase())
            allReflective = allReflective && generator.isReflective
        }

        // The macro expands an initializer call to the forward closure and derives the backward from the same member labels, so the pair inverts by construction of the expansion and the `.isomorph` guarantee `Gen.zipped` relies on holds without user involvement.
        return Gen.zipped(
            erased,
            pack: { values in
                var index = 0
                func next<Element>(_: Element.Type) -> Element {
                    defer { index += 1 }
                    return values[index] as! Element
                }
                return forward((repeat next((each T).self)))
            },
            unpack: { output in
                guard let values = Self._mirrorExtractAll(output, labels: labels) else {
                    throw ReflectionError.contramapWasWrongType
                }
                return values
            }
        ).wrapped(isReflective: allReflective)
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
        _macroZip(
            repeat each generators,
            backward: _enumCaseBackward(caseName: caseName, parameterOrder: parameterOrder),
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
        var allReflective = true
        for generator in repeat each generators {
            erased.append(generator.gen.erase())
            allReflective = allReflective && generator.isReflective
        }

        // The macro expands an enum case constructor to the forward closure and a pattern match over the same case to the backward, so the pair inverts by construction of the expansion. A `nil` from the pattern match means the value is a different case: a normal rejection during pick-branch probing, surfaced as a throw.
        return Gen.zipped(
            erased,
            pack: { values in
                var index = 0
                func next<Element>(_: Element.Type) -> Element {
                    defer { index += 1 }
                    return values[index] as! Element
                }
                return forward((repeat next((each T).self)))
            },
            unpack: { output in
                guard let values = backward(output) else {
                    throw ReflectionError.contramapWasWrongType
                }
                return values
            }
        ).wrapped(isReflective: allReflective)
    }

    /// Builds the backward extraction for a qualified enum-case call, shared by every arity.
    ///
    /// Returns `nil` for a value of a different case, a different associated-value count, or a `parameterOrder` that does not address the payload. Each is a normal reflection rejection rather than a programmer error, so the caller turns it into a throw.
    private static func _enumCaseBackward<Output>(
        caseName: String,
        parameterOrder: [Int]
    ) -> @Sendable (Output) -> [Any]? {
        { output in
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
    }

    // MARK: - Arity-Specialised Overloads

    // Concrete-arity overloads that avoid parameter pack expansion and tuple metadata construction.
    // ExhaustCore ships as a precompiled WMO xcframework, so the client cannot monomorphise
    // the variadic versions — every pack expansion runs through the generic runtime. These
    // overloads use individual type parameters and direct positional casts instead.

    // MARK: Arity 2

    static func _macroZip<T0, T1, NewOutput>(
        _ gen0: ReflectiveGenerator<T0>,
        _ gen1: ReflectiveGenerator<T1>,
        labels: [String],
        forward: @Sendable @escaping (T0, T1) -> NewOutput
    ) -> ReflectiveGenerator<NewOutput> {
        let erased: ContiguousArray<AnyGenerator> = [gen0.gen.erase(), gen1.gen.erase()]
        let allReflective = gen0.isReflective && gen1.isReflective

        return Gen.zipped(
            erased,
            pack: { values in forward(values[0] as! T0, values[1] as! T1) },
            unpack: { output in
                guard let values = Self._mirrorExtractAll(output, labels: labels) else {
                    throw ReflectionError.contramapWasWrongType
                }
                return values
            }
        ).wrapped(isReflective: allReflective)
    }

    static func _macroZip<T0, T1, NewOutput>(
        _ gen0: ReflectiveGenerator<T0>,
        _ gen1: ReflectiveGenerator<T1>,
        backward: @Sendable @escaping (NewOutput) -> [Any]?,
        forward: @Sendable @escaping (T0, T1) -> NewOutput
    ) -> ReflectiveGenerator<NewOutput> {
        let erased: ContiguousArray<AnyGenerator> = [gen0.gen.erase(), gen1.gen.erase()]
        let allReflective = gen0.isReflective && gen1.isReflective

        return Gen.zipped(
            erased,
            pack: { values in forward(values[0] as! T0, values[1] as! T1) },
            unpack: { output in
                guard let values = backward(output) else {
                    throw ReflectionError.contramapWasWrongType
                }
                return values
            }
        ).wrapped(isReflective: allReflective)
    }

    static func _macroZipEnumCase<T0, T1, Output>(
        _ gen0: ReflectiveGenerator<T0>,
        _ gen1: ReflectiveGenerator<T1>,
        caseName: String,
        parameterOrder: [Int],
        forward: @Sendable @escaping (T0, T1) -> Output
    ) -> ReflectiveGenerator<Output> {
        _macroZip(
            gen0, gen1,
            backward: _enumCaseBackward(caseName: caseName, parameterOrder: parameterOrder),
            forward: forward
        )
    }

    static func __zip<T0, T1>(
        _ gen0: ReflectiveGenerator<T0>,
        _ gen1: ReflectiveGenerator<T1>
    ) -> ReflectiveGenerator<(T0, T1)> {
        let erased: ContiguousArray<AnyGenerator> = [gen0.gen.erase(), gen1.gen.erase()]
        let allReflective = gen0.isReflective && gen1.isReflective

        return Gen.zipped(
            erased,
            pack: { values in (values[0] as! T0, values[1] as! T1) },
            unpack: { packed in [packed.0 as Any, packed.1 as Any] }
        ).wrapped(isReflective: allReflective)
    }

    // MARK: Arity 3

    static func _macroZip<T0, T1, T2, NewOutput>(
        _ gen0: ReflectiveGenerator<T0>,
        _ gen1: ReflectiveGenerator<T1>,
        _ gen2: ReflectiveGenerator<T2>,
        labels: [String],
        forward: @Sendable @escaping (T0, T1, T2) -> NewOutput
    ) -> ReflectiveGenerator<NewOutput> {
        let erased: ContiguousArray<AnyGenerator> = [gen0.gen.erase(), gen1.gen.erase(), gen2.gen.erase()]
        let allReflective = gen0.isReflective && gen1.isReflective && gen2.isReflective

        return Gen.zipped(
            erased,
            pack: { values in forward(values[0] as! T0, values[1] as! T1, values[2] as! T2) },
            unpack: { output in
                guard let values = Self._mirrorExtractAll(output, labels: labels) else {
                    throw ReflectionError.contramapWasWrongType
                }
                return values
            }
        ).wrapped(isReflective: allReflective)
    }

    static func _macroZip<T0, T1, T2, NewOutput>(
        _ gen0: ReflectiveGenerator<T0>,
        _ gen1: ReflectiveGenerator<T1>,
        _ gen2: ReflectiveGenerator<T2>,
        backward: @Sendable @escaping (NewOutput) -> [Any]?,
        forward: @Sendable @escaping (T0, T1, T2) -> NewOutput
    ) -> ReflectiveGenerator<NewOutput> {
        let erased: ContiguousArray<AnyGenerator> = [gen0.gen.erase(), gen1.gen.erase(), gen2.gen.erase()]
        let allReflective = gen0.isReflective && gen1.isReflective && gen2.isReflective

        return Gen.zipped(
            erased,
            pack: { values in forward(values[0] as! T0, values[1] as! T1, values[2] as! T2) },
            unpack: { output in
                guard let values = backward(output) else {
                    throw ReflectionError.contramapWasWrongType
                }
                return values
            }
        ).wrapped(isReflective: allReflective)
    }

    static func _macroZipEnumCase<T0, T1, T2, Output>(
        _ gen0: ReflectiveGenerator<T0>,
        _ gen1: ReflectiveGenerator<T1>,
        _ gen2: ReflectiveGenerator<T2>,
        caseName: String,
        parameterOrder: [Int],
        forward: @Sendable @escaping (T0, T1, T2) -> Output
    ) -> ReflectiveGenerator<Output> {
        _macroZip(
            gen0, gen1, gen2,
            backward: _enumCaseBackward(caseName: caseName, parameterOrder: parameterOrder),
            forward: forward
        )
    }

    static func __zip<T0, T1, T2>(
        _ gen0: ReflectiveGenerator<T0>,
        _ gen1: ReflectiveGenerator<T1>,
        _ gen2: ReflectiveGenerator<T2>
    ) -> ReflectiveGenerator<(T0, T1, T2)> {
        let erased: ContiguousArray<AnyGenerator> = [gen0.gen.erase(), gen1.gen.erase(), gen2.gen.erase()]
        let allReflective = gen0.isReflective && gen1.isReflective && gen2.isReflective

        return Gen.zipped(
            erased,
            pack: { values in (values[0] as! T0, values[1] as! T1, values[2] as! T2) },
            unpack: { packed in [packed.0 as Any, packed.1 as Any, packed.2 as Any] }
        ).wrapped(isReflective: allReflective)
    }

    // MARK: Arity 4

    static func _macroZip<T0, T1, T2, T3, NewOutput>(
        _ gen0: ReflectiveGenerator<T0>,
        _ gen1: ReflectiveGenerator<T1>,
        _ gen2: ReflectiveGenerator<T2>,
        _ gen3: ReflectiveGenerator<T3>,
        labels: [String],
        forward: @Sendable @escaping (T0, T1, T2, T3) -> NewOutput
    ) -> ReflectiveGenerator<NewOutput> {
        let erased: ContiguousArray<AnyGenerator> = [gen0.gen.erase(), gen1.gen.erase(), gen2.gen.erase(), gen3.gen.erase()]
        let allReflective = gen0.isReflective && gen1.isReflective && gen2.isReflective && gen3.isReflective

        return Gen.zipped(
            erased,
            pack: { values in forward(values[0] as! T0, values[1] as! T1, values[2] as! T2, values[3] as! T3) },
            unpack: { output in
                guard let values = Self._mirrorExtractAll(output, labels: labels) else {
                    throw ReflectionError.contramapWasWrongType
                }
                return values
            }
        ).wrapped(isReflective: allReflective)
    }

    static func _macroZip<T0, T1, T2, T3, NewOutput>(
        _ gen0: ReflectiveGenerator<T0>,
        _ gen1: ReflectiveGenerator<T1>,
        _ gen2: ReflectiveGenerator<T2>,
        _ gen3: ReflectiveGenerator<T3>,
        backward: @Sendable @escaping (NewOutput) -> [Any]?,
        forward: @Sendable @escaping (T0, T1, T2, T3) -> NewOutput
    ) -> ReflectiveGenerator<NewOutput> {
        let erased: ContiguousArray<AnyGenerator> = [gen0.gen.erase(), gen1.gen.erase(), gen2.gen.erase(), gen3.gen.erase()]
        let allReflective = gen0.isReflective && gen1.isReflective && gen2.isReflective && gen3.isReflective

        return Gen.zipped(
            erased,
            pack: { values in forward(values[0] as! T0, values[1] as! T1, values[2] as! T2, values[3] as! T3) },
            unpack: { output in
                guard let values = backward(output) else {
                    throw ReflectionError.contramapWasWrongType
                }
                return values
            }
        ).wrapped(isReflective: allReflective)
    }

    static func _macroZipEnumCase<T0, T1, T2, T3, Output>(
        _ gen0: ReflectiveGenerator<T0>,
        _ gen1: ReflectiveGenerator<T1>,
        _ gen2: ReflectiveGenerator<T2>,
        _ gen3: ReflectiveGenerator<T3>,
        caseName: String,
        parameterOrder: [Int],
        forward: @Sendable @escaping (T0, T1, T2, T3) -> Output
    ) -> ReflectiveGenerator<Output> {
        _macroZip(
            gen0, gen1, gen2, gen3,
            backward: _enumCaseBackward(caseName: caseName, parameterOrder: parameterOrder),
            forward: forward
        )
    }

    static func __zip<T0, T1, T2, T3>(
        _ gen0: ReflectiveGenerator<T0>,
        _ gen1: ReflectiveGenerator<T1>,
        _ gen2: ReflectiveGenerator<T2>,
        _ gen3: ReflectiveGenerator<T3>
    ) -> ReflectiveGenerator<(T0, T1, T2, T3)> {
        let erased: ContiguousArray<AnyGenerator> = [gen0.gen.erase(), gen1.gen.erase(), gen2.gen.erase(), gen3.gen.erase()]
        let allReflective = gen0.isReflective && gen1.isReflective && gen2.isReflective && gen3.isReflective

        return Gen.zipped(
            erased,
            pack: { values in (values[0] as! T0, values[1] as! T1, values[2] as! T2, values[3] as! T3) },
            unpack: { packed in [packed.0 as Any, packed.1 as Any, packed.2 as Any, packed.3 as Any] }
        ).wrapped(isReflective: allReflective)
    }

    // MARK: Arity 5

    static func _macroZip<T0, T1, T2, T3, T4, NewOutput>(
        _ gen0: ReflectiveGenerator<T0>,
        _ gen1: ReflectiveGenerator<T1>,
        _ gen2: ReflectiveGenerator<T2>,
        _ gen3: ReflectiveGenerator<T3>,
        _ gen4: ReflectiveGenerator<T4>,
        labels: [String],
        forward: @Sendable @escaping (T0, T1, T2, T3, T4) -> NewOutput
    ) -> ReflectiveGenerator<NewOutput> {
        let erased: ContiguousArray<AnyGenerator> = [gen0.gen.erase(), gen1.gen.erase(), gen2.gen.erase(), gen3.gen.erase(), gen4.gen.erase()]
        let allReflective = gen0.isReflective && gen1.isReflective && gen2.isReflective && gen3.isReflective && gen4.isReflective

        return Gen.zipped(
            erased,
            pack: { values in forward(values[0] as! T0, values[1] as! T1, values[2] as! T2, values[3] as! T3, values[4] as! T4) },
            unpack: { output in
                guard let values = Self._mirrorExtractAll(output, labels: labels) else {
                    throw ReflectionError.contramapWasWrongType
                }
                return values
            }
        ).wrapped(isReflective: allReflective)
    }

    static func _macroZip<T0, T1, T2, T3, T4, NewOutput>(
        _ gen0: ReflectiveGenerator<T0>,
        _ gen1: ReflectiveGenerator<T1>,
        _ gen2: ReflectiveGenerator<T2>,
        _ gen3: ReflectiveGenerator<T3>,
        _ gen4: ReflectiveGenerator<T4>,
        backward: @Sendable @escaping (NewOutput) -> [Any]?,
        forward: @Sendable @escaping (T0, T1, T2, T3, T4) -> NewOutput
    ) -> ReflectiveGenerator<NewOutput> {
        let erased: ContiguousArray<AnyGenerator> = [gen0.gen.erase(), gen1.gen.erase(), gen2.gen.erase(), gen3.gen.erase(), gen4.gen.erase()]
        let allReflective = gen0.isReflective && gen1.isReflective && gen2.isReflective && gen3.isReflective && gen4.isReflective

        return Gen.zipped(
            erased,
            pack: { values in forward(values[0] as! T0, values[1] as! T1, values[2] as! T2, values[3] as! T3, values[4] as! T4) },
            unpack: { output in
                guard let values = backward(output) else {
                    throw ReflectionError.contramapWasWrongType
                }
                return values
            }
        ).wrapped(isReflective: allReflective)
    }

    static func _macroZipEnumCase<T0, T1, T2, T3, T4, Output>(
        _ gen0: ReflectiveGenerator<T0>,
        _ gen1: ReflectiveGenerator<T1>,
        _ gen2: ReflectiveGenerator<T2>,
        _ gen3: ReflectiveGenerator<T3>,
        _ gen4: ReflectiveGenerator<T4>,
        caseName: String,
        parameterOrder: [Int],
        forward: @Sendable @escaping (T0, T1, T2, T3, T4) -> Output
    ) -> ReflectiveGenerator<Output> {
        _macroZip(
            gen0, gen1, gen2, gen3, gen4,
            backward: _enumCaseBackward(caseName: caseName, parameterOrder: parameterOrder),
            forward: forward
        )
    }

    static func __zip<T0, T1, T2, T3, T4>(
        _ gen0: ReflectiveGenerator<T0>,
        _ gen1: ReflectiveGenerator<T1>,
        _ gen2: ReflectiveGenerator<T2>,
        _ gen3: ReflectiveGenerator<T3>,
        _ gen4: ReflectiveGenerator<T4>
    ) -> ReflectiveGenerator<(T0, T1, T2, T3, T4)> {
        let erased: ContiguousArray<AnyGenerator> = [gen0.gen.erase(), gen1.gen.erase(), gen2.gen.erase(), gen3.gen.erase(), gen4.gen.erase()]
        let allReflective = gen0.isReflective && gen1.isReflective && gen2.isReflective && gen3.isReflective && gen4.isReflective

        return Gen.zipped(
            erased,
            pack: { values in (values[0] as! T0, values[1] as! T1, values[2] as! T2, values[3] as! T3, values[4] as! T4) },
            unpack: { packed in [packed.0 as Any, packed.1 as Any, packed.2 as Any, packed.3 as Any, packed.4 as Any] }
        ).wrapped(isReflective: allReflective)
    }

    // MARK: Arity 6

    static func _macroZip<T0, T1, T2, T3, T4, T5, NewOutput>(
        _ gen0: ReflectiveGenerator<T0>,
        _ gen1: ReflectiveGenerator<T1>,
        _ gen2: ReflectiveGenerator<T2>,
        _ gen3: ReflectiveGenerator<T3>,
        _ gen4: ReflectiveGenerator<T4>,
        _ gen5: ReflectiveGenerator<T5>,
        labels: [String],
        forward: @Sendable @escaping (T0, T1, T2, T3, T4, T5) -> NewOutput
    ) -> ReflectiveGenerator<NewOutput> {
        let erased: ContiguousArray<AnyGenerator> = [gen0.gen.erase(), gen1.gen.erase(), gen2.gen.erase(), gen3.gen.erase(), gen4.gen.erase(), gen5.gen.erase()]
        let allReflective = gen0.isReflective && gen1.isReflective && gen2.isReflective && gen3.isReflective && gen4.isReflective && gen5.isReflective

        return Gen.zipped(
            erased,
            pack: { values in forward(values[0] as! T0, values[1] as! T1, values[2] as! T2, values[3] as! T3, values[4] as! T4, values[5] as! T5) },
            unpack: { output in
                guard let values = Self._mirrorExtractAll(output, labels: labels) else {
                    throw ReflectionError.contramapWasWrongType
                }
                return values
            }
        ).wrapped(isReflective: allReflective)
    }

    static func _macroZip<T0, T1, T2, T3, T4, T5, NewOutput>(
        _ gen0: ReflectiveGenerator<T0>,
        _ gen1: ReflectiveGenerator<T1>,
        _ gen2: ReflectiveGenerator<T2>,
        _ gen3: ReflectiveGenerator<T3>,
        _ gen4: ReflectiveGenerator<T4>,
        _ gen5: ReflectiveGenerator<T5>,
        backward: @Sendable @escaping (NewOutput) -> [Any]?,
        forward: @Sendable @escaping (T0, T1, T2, T3, T4, T5) -> NewOutput
    ) -> ReflectiveGenerator<NewOutput> {
        let erased: ContiguousArray<AnyGenerator> = [gen0.gen.erase(), gen1.gen.erase(), gen2.gen.erase(), gen3.gen.erase(), gen4.gen.erase(), gen5.gen.erase()]
        let allReflective = gen0.isReflective && gen1.isReflective && gen2.isReflective && gen3.isReflective && gen4.isReflective && gen5.isReflective

        return Gen.zipped(
            erased,
            pack: { values in forward(values[0] as! T0, values[1] as! T1, values[2] as! T2, values[3] as! T3, values[4] as! T4, values[5] as! T5) },
            unpack: { output in
                guard let values = backward(output) else {
                    throw ReflectionError.contramapWasWrongType
                }
                return values
            }
        ).wrapped(isReflective: allReflective)
    }

    static func _macroZipEnumCase<T0, T1, T2, T3, T4, T5, Output>(
        _ gen0: ReflectiveGenerator<T0>,
        _ gen1: ReflectiveGenerator<T1>,
        _ gen2: ReflectiveGenerator<T2>,
        _ gen3: ReflectiveGenerator<T3>,
        _ gen4: ReflectiveGenerator<T4>,
        _ gen5: ReflectiveGenerator<T5>,
        caseName: String,
        parameterOrder: [Int],
        forward: @Sendable @escaping (T0, T1, T2, T3, T4, T5) -> Output
    ) -> ReflectiveGenerator<Output> {
        _macroZip(
            gen0, gen1, gen2, gen3, gen4, gen5,
            backward: _enumCaseBackward(caseName: caseName, parameterOrder: parameterOrder),
            forward: forward
        )
    }

    static func __zip<T0, T1, T2, T3, T4, T5>(
        _ gen0: ReflectiveGenerator<T0>,
        _ gen1: ReflectiveGenerator<T1>,
        _ gen2: ReflectiveGenerator<T2>,
        _ gen3: ReflectiveGenerator<T3>,
        _ gen4: ReflectiveGenerator<T4>,
        _ gen5: ReflectiveGenerator<T5>
    ) -> ReflectiveGenerator<(T0, T1, T2, T3, T4, T5)> {
        let erased: ContiguousArray<AnyGenerator> = [gen0.gen.erase(), gen1.gen.erase(), gen2.gen.erase(), gen3.gen.erase(), gen4.gen.erase(), gen5.gen.erase()]
        let allReflective = gen0.isReflective && gen1.isReflective && gen2.isReflective && gen3.isReflective && gen4.isReflective && gen5.isReflective

        return Gen.zipped(
            erased,
            pack: { values in (values[0] as! T0, values[1] as! T1, values[2] as! T2, values[3] as! T3, values[4] as! T4, values[5] as! T5) },
            unpack: { packed in [packed.0 as Any, packed.1 as Any, packed.2 as Any, packed.3 as Any, packed.4 as Any, packed.5 as Any] }
        ).wrapped(isReflective: allReflective)
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
    /// The `SendableMetatype` constraints let the reified `mapped(forward:backward:)` capture the generic metatypes in its `@Sendable` transform closures without a strict-concurrency diagnostic. Every standard numeric type satisfies them.
    static func _macroMapScalar<Input: BinaryFloatingPoint & SendableMetatype, Output: BinaryFloatingPoint & SendableMetatype>(
        _ generator: ReflectiveGenerator<Input>,
        forward: @Sendable @escaping (Input) -> Output
    ) -> ReflectiveGenerator<Output> {
        generator.mapped(forward: forward, backward: { Input($0) })
    }

    /// Unconstrained fallback: forward-only when no numeric protocol matches.
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
        var allReflective = true
        for generator in repeat each generators {
            allReflective = allReflective && generator.isReflective
        }
        return Gen.zip(repeat (each generators).gen).wrapped(isReflective: allReflective)
    }
}
