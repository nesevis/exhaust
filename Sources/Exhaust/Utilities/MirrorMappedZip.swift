/// Runtime support for the `#gen` macro's multi-generator backward mapping.
///
/// Combines `Gen.zip` with a Mirror-based backward extraction, bypassing the
/// tuple-typed backward that `zip().mapped()` would require.
public extension Gen {
    static func _mirrorMappedZip<each T, NewOutput>(
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
