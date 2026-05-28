import ExhaustCore
import Foundation

public extension __ExhaustRuntime {
    /// Synthesises a generator from a `Decodable` type and example JSON data.
    ///
    /// Returns a `Result` so that the macro expansion can chain `.get()` — a throwing call that the user's `try` covers. This follows the same pattern as Swift Testing's `#require`, which expands to a non-throwing expression chained with a throwing method.
    static func _macroGenDecodable<T: Decodable>(
        _ type: T.Type,
        from data: Data
    ) -> Result<ReflectiveGenerator<T>, any Error> {
        Result { try GeneratorSynthesizer.makeGenerator(type, from: data) }
    }

    /// Synthesises a generator from a `Decodable` type and an example JSON string.
    static func _macroGenDecodable<T: Decodable>(
        _ type: T.Type,
        from string: String
    ) -> Result<ReflectiveGenerator<T>, any Error> {
        Result { try GeneratorSynthesizer.makeGenerator(type, from: string) }
    }

    /// Synthesises a generator from a `Codable` instance by encoding it to JSON first.
    static func _macroGenCodableInstance<T: Codable>(
        _ instance: T
    ) -> Result<ReflectiveGenerator<T>, any Error> {
        Result {
            let data = try JSONEncoder().encode(instance)
            return try GeneratorSynthesizer.makeGenerator(T.self, from: data)
        }
    }
}
