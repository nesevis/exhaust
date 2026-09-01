//
//  Gen+Zip.swift
//  Exhaust
//
//  Created by Chris Kolbu on 21/7/2025.
//

package extension Gen {
    /// Composes a fixed number of independent generators into a single tuple result.
    ///
    /// Use zip for fixed-arity parallel composition where the child count is known at construction time. Screening analysis enumerates parameter combinations across zip children directly — unlike ``sequence``, which must generate a length first. The reducer treats each child as an independent scope, so simplifying one child does not affect the others.
    ///
    /// ```swift
    /// let pairGen = Gen.zip(Gen.choose(in: 0...99), Gen.string())
    /// // produces Generator<(Int, String)>
    /// ```
    ///
    /// - Parameters:
    ///   - generators: The generators to combine.
    ///   - isOpaque: When `true`, the resulting zip node is treated as a single unit during screening analysis. Defaults to `false`.
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

        return zipped(
            erased,
            isOpaque: isOpaque,
            pack: { values in
                var index = 0
                func next<Element>(_: Element.Type) -> Element {
                    defer { index += 1 }
                    return values[index] as! Element
                }
                return (repeat next((each T).self))
            },
            unpack: { tuple in
                var values: [Any] = []
                for value in repeat each tuple {
                    values.append(value)
                }
                return values
            }
        )
    }

    /// Composes a runtime-sized array of generators into a single array result.
    ///
    /// The homogeneous counterpart to ``zip(_:isOpaque:)``. A parameter pack fixes the arity at the call site, so a collection whose size is known only at runtime cannot go through the variadic form, while ``ReflectiveOperation/zip(_:isOpaque:)`` has always taken a runtime-sized array. What separates this from ``arrayOf(_:_:)`` is that each position keeps its own generator: a sequence instantiates one element generator and reuses it everywhere, so per-position domains cannot vary there.
    ///
    /// An empty input yields ``just(_:)`` rather than a childless zip node, so no operation in the tree carries zero children.
    ///
    /// - Parameters:
    ///   - generators: One generator per output position.
    ///   - isOpaque: When `true`, the resulting zip node is treated as a single unit during screening analysis. Defaults to `false`.
    /// - Returns: A generator producing an array with one value per input generator, in order.
    static func eachOf<Value>(
        _ generators: [Generator<Value>],
        isOpaque: Bool = false
    ) -> Generator<[Value]> {
        guard generators.isEmpty == false else {
            return Gen.just([])
        }

        var erased: ContiguousArray<AnyGenerator> = []
        erased.reserveCapacity(generators.count)
        for generator in generators {
            erased.append(generator.erase())
        }

        return zipped(
            erased,
            isOpaque: isOpaque,
            pack: { values in values.map { $0 as! Value } },
            unpack: { array in array.map { $0 as Any } }
        )
    }

    /// Builds the zip node and the transform that packages its positional `[Any]` payload into `Packed`.
    ///
    /// Every zip-shaped construction in the framework differs only in how that payload is packed and unpacked, so the node construction, the arity capture the forward pass validates against, and the `.isomorph` scaffold live here. A change to how a zip reflects then lands in one place rather than in every form that has to be kept in step. The macro infrastructure in ``__ExhaustRuntime`` calls this directly so that an initializer or enum case reaches its output in a single transform node, without a tuple hop in between.
    ///
    /// `unpack` throws rather than returning an optional because reflection probes pick branches against a shared final output: an extraction that cannot recognise the value is a normal rejection, surfaced as ``ReflectionError/contramapWasWrongType``.
    ///
    /// - Parameters:
    ///   - erased: One type-erased generator per position, in output order.
    ///   - isOpaque: When `true`, the resulting zip node is treated as a single unit during screening analysis. Defaults to `false`.
    ///   - pack: Builds the result from the positional values. Must be the exact inverse of `unpack`, since the pair is declared as an isomorphism rather than a forward-only map.
    ///   - unpack: Decomposes a result back into positional values, throwing when the value does not match the shape `pack` produces.
    static func zipped<Packed>(
        _ erased: ContiguousArray<AnyGenerator>,
        isOpaque: Bool = false,
        pack: @escaping ([Any]) -> Packed,
        unpack: @escaping (Packed) throws -> [Any]
    ) -> Generator<Packed> {
        let zipNode: AnyGenerator = .impure(
            operation: .zip(erased, isOpaque: isOpaque),
            continuation: { .pure($0) }
        )

        let arity = erased.count

        // The `[Any]` ↔ `Packed` packaging is a framework-authored exact inverse pair, so it qualifies for `.isomorph`: one transform node replaces the contramap + map sandwich this construction emitted previously.
        return Gen.liftF(.transform(
            kind: .isomorph(
                forward: { anyValues in
                    try pack(zipComponents(anyValues, arity: arity))
                },
                backward: { anyPacked in
                    // Reflection probes pick branches against a shared final output, so a mismatched value is a normal rejection rather than a programmer error. Throw, as the previous contramap-based construction did, instead of trapping.
                    guard let packed = anyPacked as? Packed else {
                        throw ReflectionError.contramapWasWrongType
                    }
                    return try unpack(packed)
                },
                inputType: [Any].self,
                outputType: Packed.self
            ),
            inner: zipNode
        ))
    }
}
