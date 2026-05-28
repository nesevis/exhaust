import Foundation

/// Builds a ``ReflectiveGenerator`` from a `Decodable` type and an example JSON value.
///
/// Runs `T.init(from:)` once against the provided JSON to discover the type's decode call pattern, recording a generator for each field. The result is a normal ``ReflectiveGenerator`` — all interpreters, the reducer, and coverage analysis treat it identically to a hand-written generator.
///
/// The generator is forward-only (no reflection support). Types that cannot be mapped to a built-in generator fall back to `.just(decodedValue)` using the concrete value from the JSON example.
package enum GeneratorSynthesizer {
    /// Builds a generator from an example JSON `Data` value.
    ///
    /// - Parameters:
    ///   - type: The `Decodable` type to synthesise a generator for.
    ///   - data: Example JSON data whose structure matches `T`.
    /// - Returns: A ``ReflectiveGenerator`` that produces arbitrary values of type `T`.
    package static func makeGenerator<T: Decodable>(
        _ type: T.Type,
        from data: Data
    ) throws -> ReflectiveGenerator<T> {
        let jsonValue = try JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)
        return try makeGenerator(type, jsonValue: jsonValue)
    }

    /// Builds a generator from an example JSON string.
    ///
    /// - Parameters:
    ///   - type: The `Decodable` type to synthesise a generator for.
    ///   - string: Example JSON string whose structure matches `T`.
    /// - Returns: A ``ReflectiveGenerator`` that produces arbitrary values of type `T`.
    package static func makeGenerator<T: Decodable>(
        _ type: T.Type,
        from string: String
    ) throws -> ReflectiveGenerator<T> {
        guard let data = string.data(using: .utf8) else {
            throw GeneratorSynthesizerError.invalidJSON
        }
        return try makeGenerator(type, from: data)
    }

    private static func makeGenerator<T: Decodable>(
        _: T.Type,
        jsonValue: Any
    ) throws -> ReflectiveGenerator<T> {
        let discovery = DiscoveryDecoder(jsonValue: jsonValue)
        _ = try T(from: discovery)
        let childGenerators = ContiguousArray(discovery.childGenerators)

        let zipped: AnyGenerator = .impure(
            operation: .zip(childGenerators),
            continuation: { .pure($0) }
        )

        let generator = Gen.liftF(.transform(
            kind: .map(
                forward: { values in
                    let replay = ReplayDecoder(values: values as! [Any])
                    return try T(from: replay)
                },
                inputType: [Any].self,
                outputType: T.self
            ),
            inner: zipped
        )) as Generator<T>

        return ReflectiveGenerator(generator, isSynthesized: true)
    }
}

/// Errors thrown during generator synthesis from a `Decodable` type.
package enum GeneratorSynthesizerError: Error {
    /// The input string could not be encoded as UTF-8 data.
    case invalidJSON
    /// The JSON structure did not match the expected container type (keyed, unkeyed, or single-value).
    case unexpectedContainer
}

