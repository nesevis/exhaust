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
    func metamorph<each Transformed>(
        _ transform: repeat @escaping (Output) -> each Transformed
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
