//
//  ReflectiveGenerator+Metamorph.swift
//  Exhaust
//
//  Created by Chris Kolbu on 13/5/2026.
//

public extension ReflectiveGenerator {
    /// Generates independent copies of this generator's value and applies a different transform to each.
    ///
    /// Each transform receives its own independently generated copy, making this safe for reference types. The original (untransformed) value is included at tuple position zero for the metamorphic relation check. Reduction operates only on the source value — all transformed copies follow deterministically.
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

        let impure: Generator<[Any]> = .impure(
            operation: .transform(
                kind: .metamorphic(
                    transforms: erasedTransforms,
                    inputType: Output.self
                ),
                inner: gen.erase()
            ),
            continuation: {
                guard let array = $0 as? [Any] else {
                    throw Interpreters.ReflectionError.forwardOnlyMetamorph
                }
                return .pure(array)
            }
        )

        return ReflectiveGenerator<(Output, repeat each Transformed)> {
            // `tuple.0` crashes the Swift 6.2 compiler (signal 5) on tuples with parameter packs.
            Gen.contramap(
                { (tuple: (Output, repeat each Transformed)) -> Output in
                    Mirror(reflecting: tuple).children.first!.value as! Output
                },
                impure.map { (values: [Any]) -> (Output, repeat each Transformed) in
                    var index = 0
                    func next<Element>(_: Element.Type) -> Element {
                        defer { index += 1 }
                        return values[index] as! Element
                    }
                    return (next(Output.self), repeat next((each Transformed).self))
                }
            )
        }
    }
}
