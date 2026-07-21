//
//  ReflectiveGenerator+Metamorph.swift
//  Exhaust
//
//  Created by Chris Kolbu on 13/5/2026.
//

public extension ReflectiveGenerator {
    /// Generates independent copies of this generator's value and applies a different transform to each.
    ///
    /// Each transform receives its own independently generated copy, making this safe for reference types. The original (untransformed) value is included at tuple position zero for the metamorphic relation check. Reduction operates only on the source value — all transformed copies follow deterministically. During reflection, the original is authoritative and supplied transformed members are not validated. Replay and materialization regenerate them from the reflected original, so stale supplied members are replaced before reduction or replay.
    ///
    /// ```swift
    /// let pair = #gen(.string()).metamorph({ $0.uppercased() }, { $0.count })
    /// // pair: Gen<(String, String, Int)>
    /// //   .0 = original, .1 = uppercased copy, .2 = count of a copy
    /// ```
    ///
    /// - Parameter transform: Functions that derive follow-up values from independent copies of the source.
    /// - Returns: A generator producing `(original, transformed...)` tuples.
    /// - Note: When consuming Exhaust as a binary artifact, prefer four or fewer transforms so the call resolves to a fixed-arity overload. The variadic form links only in source builds.
    func metamorph<each Transformed>(
        _ transform: repeat @escaping @Sendable (Output) -> each Transformed
    ) -> ReflectiveGenerator<(Output, repeat each Transformed)> {
        metamorphCore(repeat each transform)
    }

    // MARK: - Fixed-Arity Overloads

    //
    // The module interface printer omits `@escaping` from function parameters inside a parameter pack, so the shipped .swiftinterface declares the variadic form with noescape transforms while the binary exports the escaping mangling (interface clients emit ...qd__xXEqd__Qp..., the library exports ...qd__xcqd__Qp...). Clients of the XCFramework therefore cannot link any call to the variadic form. Fixed-arity overloads keep `@escaping` through interface printing, and Swift's overload ranking prefers them over the pack, so existing call sites up to arity 4 resolve to a linkable symbol without source changes.

    /// Generates an independent copy of this generator's value and applies a transform to it.
    ///
    /// The transform receives its own independently generated copy, making this safe for reference types. The original (untransformed) value is included at tuple position zero for the metamorphic relation check. Reduction operates only on the source value — the transformed copy follows deterministically. During reflection, the original is authoritative and a supplied transformed member is not validated. Replay and materialization regenerate it from the reflected original, so a stale supplied member is replaced before reduction or replay.
    ///
    /// - Parameter transform: Function that derives a follow-up value from an independent copy of the source.
    /// - Returns: A generator producing `(original, transformed)` tuples.
    func metamorph<Transformed>(
        _ transform: @escaping @Sendable (Output) -> Transformed
    ) -> ReflectiveGenerator<(Output, Transformed)> {
        metamorphCore(transform)
    }

    /// Generates independent copies of this generator's value and applies a different transform to each.
    ///
    /// Each transform receives its own independently generated copy, making this safe for reference types. The original (untransformed) value is included at tuple position zero for the metamorphic relation check. Reduction operates only on the source value — all transformed copies follow deterministically. During reflection, the original is authoritative and supplied transformed members are not validated. Replay and materialization regenerate them from the reflected original, so stale supplied members are replaced before reduction or replay.
    ///
    /// - Parameters:
    ///   - firstTransform: Function that derives a follow-up value from an independent copy of the source.
    ///   - secondTransform: Function that derives a follow-up value from an independent copy of the source.
    /// - Returns: A generator producing `(original, transformed, transformed)` tuples.
    func metamorph<FirstTransformed, SecondTransformed>(
        _ firstTransform: @escaping @Sendable (Output) -> FirstTransformed,
        _ secondTransform: @escaping @Sendable (Output) -> SecondTransformed
    ) -> ReflectiveGenerator<(Output, FirstTransformed, SecondTransformed)> {
        metamorphCore(firstTransform, secondTransform)
    }

    /// Generates independent copies of this generator's value and applies a different transform to each.
    ///
    /// Each transform receives its own independently generated copy, making this safe for reference types. The original (untransformed) value is included at tuple position zero for the metamorphic relation check. Reduction operates only on the source value — all transformed copies follow deterministically. During reflection, the original is authoritative and supplied transformed members are not validated. Replay and materialization regenerate them from the reflected original, so stale supplied members are replaced before reduction or replay.
    ///
    /// - Parameters:
    ///   - firstTransform: Function that derives a follow-up value from an independent copy of the source.
    ///   - secondTransform: Function that derives a follow-up value from an independent copy of the source.
    ///   - thirdTransform: Function that derives a follow-up value from an independent copy of the source.
    /// - Returns: A generator producing `(original, transformed, transformed, transformed)` tuples.
    func metamorph<FirstTransformed, SecondTransformed, ThirdTransformed>(
        _ firstTransform: @escaping @Sendable (Output) -> FirstTransformed,
        _ secondTransform: @escaping @Sendable (Output) -> SecondTransformed,
        _ thirdTransform: @escaping @Sendable (Output) -> ThirdTransformed
    ) -> ReflectiveGenerator<(Output, FirstTransformed, SecondTransformed, ThirdTransformed)> {
        metamorphCore(firstTransform, secondTransform, thirdTransform)
    }

    /// Generates independent copies of this generator's value and applies a different transform to each.
    ///
    /// Each transform receives its own independently generated copy, making this safe for reference types. The original (untransformed) value is included at tuple position zero for the metamorphic relation check. Reduction operates only on the source value — all transformed copies follow deterministically. During reflection, the original is authoritative and supplied transformed members are not validated. Replay and materialization regenerate them from the reflected original, so stale supplied members are replaced before reduction or replay.
    ///
    /// - Parameters:
    ///   - firstTransform: Function that derives a follow-up value from an independent copy of the source.
    ///   - secondTransform: Function that derives a follow-up value from an independent copy of the source.
    ///   - thirdTransform: Function that derives a follow-up value from an independent copy of the source.
    ///   - fourthTransform: Function that derives a follow-up value from an independent copy of the source.
    /// - Returns: A generator producing `(original, transformed, transformed, transformed, transformed)` tuples.
    func metamorph<FirstTransformed, SecondTransformed, ThirdTransformed, FourthTransformed>(
        _ firstTransform: @escaping @Sendable (Output) -> FirstTransformed,
        _ secondTransform: @escaping @Sendable (Output) -> SecondTransformed,
        _ thirdTransform: @escaping @Sendable (Output) -> ThirdTransformed,
        _ fourthTransform: @escaping @Sendable (Output) -> FourthTransformed
    ) -> ReflectiveGenerator<(Output, FirstTransformed, SecondTransformed, ThirdTransformed, FourthTransformed)> {
        metamorphCore(firstTransform, secondTransform, thirdTransform, fourthTransform)
    }
}

private extension ReflectiveGenerator {
    /// Shared implementation behind the variadic ``metamorph(_:)`` and its fixed-arity overloads. Private, so the interface printer never sees its parameter pack.
    func metamorphCore<each Transformed>(
        _ transform: repeat @escaping @Sendable (Output) -> each Transformed
    ) -> ReflectiveGenerator<(Output, repeat each Transformed)> {
        var erasedTransforms: [(Any) throws -> Any] = []
        func add(_ function: @escaping (Output) -> some Any) {
            erasedTransforms.append { function($0 as! Output) as Any }
        }
        repeat add(each transform)

        let metamorphicNode: AnyGenerator = .impure(
            operation: .transform(
                kind: .metamorphic(
                    transforms: erasedTransforms,
                    inputType: Output.self
                ),
                inner: gen.erase()
            ),
            continuation: { .pure($0) }
        )

        // The `[Any]` ↔ tuple packaging is a framework-authored exact inverse pair. Keeping it outside the metamorphic operation lets reflection recover the component array before reflecting only its original value at position zero.
        return Gen.liftF(.transform(
            kind: .isomorph(
                forward: { anyValues in
                    let values = anyValues as! [Any]
                    var index = 0
                    func next<Element>(_: Element.Type) -> Element {
                        defer { index += 1 }
                        return values[index] as! Element
                    }
                    return (next(Output.self), repeat next((each Transformed).self))
                },
                backward: { anyTuple in
                    guard let tuple = anyTuple as? (Output, repeat each Transformed) else {
                        throw ReflectionError.contramapWasWrongType
                    }
                    // Accessing `tuple.0` crashes the Swift 6.2 compiler (signal 5) on tuples with parameter packs.
                    return Mirror(reflecting: tuple).children.map(\.value)
                },
                inputType: [Any].self,
                outputType: (Output, repeat each Transformed).self
            ),
            inner: metamorphicNode
        )).wrapped
    }
}
