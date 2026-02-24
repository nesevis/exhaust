public extension Gen {
    /// Zips multiple generators with a forward transform and Mirror-based backward extraction.
    ///
    /// This is **macro infrastructure** — it exists solely as an expansion target for the `#gen` macro when multiple generators are combined with a labeled initializer call.
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
        forward: @escaping ((repeat each T)) -> NewOutput
    ) -> ReflectiveGenerator<NewOutput> {
        var erased: ContiguousArray<ReflectiveGenerator<Any>> = []
        erased.reserveCapacity(5)
        for generator in repeat each generators {
            erased.append(generator.erase())
        }

        let impure: ReflectiveGenerator<[Any]> = .impure(
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

        let backwardToArray: (NewOutput) -> [Any] = { output in
            _mirrorExtractAll(output, labels: labels)
        }

        return Gen.contramap(backwardToArray, impure.map(forwardFromArray))
    }
}
