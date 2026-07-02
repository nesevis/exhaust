//
//  Gen+Zip.swift
//  Exhaust
//
//  Created by Chris Kolbu on 21/7/2025.
//

package extension Gen {
    /// Composes a fixed number of independent generators into a single tuple result.
    ///
    /// Use zip for fixed-arity parallel composition where the child count is known at construction time. Coverage analysis enumerates parameter combinations across zip children directly — unlike ``sequence``, which must generate a length first. The reducer treats each child as an independent scope, so simplifying one child does not affect the others.
    ///
    /// ```swift
    /// let pairGen = Gen.zip(Gen.int(in: 0...99), Gen.string())
    /// // produces Generator<(Int, String)>
    /// ```
    ///
    /// - Parameters:
    ///   - generators: The generators to combine.
    ///   - isOpaque: When `true`, the resulting zip node is treated as a single unit during coverage analysis. Defaults to `false`.
    /// - Returns: A generator producing a tuple of values, one per input generator.
    static func zip<each T>(
        _ generators: repeat Generator<each T>,
        isOpaque: Bool = false
    ) -> Generator<(repeat each T)> {
        var erased: ContiguousArray<AnyGenerator> = []
        erased.reserveCapacity(5) // It will rarely exceed this size
        for generator in repeat each generators {
            erased.append(generator.erase())
        }

        let zipNode: AnyGenerator = .impure(
            operation: .zip(erased, isOpaque: isOpaque),
            continuation: { .pure($0) }
        )

        // The `[Any]` ↔ tuple packaging is a framework-authored exact inverse pair, so it qualifies for `.isomorph` — one transform node instead of the contramap + map sandwich this method emitted previously.
        return Gen.liftF(.transform(
            kind: .isomorph(
                forward: { anyValues in
                    let values = anyValues as! [Any]
                    var index = 0
                    func next<Element>(_: Element.Type) -> Element {
                        defer { index += 1 }
                        return values[index] as! Element
                    }
                    return (repeat next((each T).self))
                },
                backward: { anyTuple in
                    // Reflection probes pick branches against a shared final output, so a mismatched value is a normal rejection, not a programmer error — throw (as the previous contramap-based construction did) instead of trapping.
                    guard let tuple = anyTuple as? (repeat each T) else {
                        throw ReflectionError.contramapWasWrongType
                    }
                    var values: [Any] = []
                    for value in repeat each tuple {
                        values.append(value)
                    }
                    return values
                },
                inputType: [Any].self,
                outputType: (repeat each T).self
            ),
            inner: zipNode
        ))
    }
}
