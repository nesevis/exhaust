import ExhaustCore
import Foundation

public extension __ExhaustRuntime {
    /// Synthesises a generator from a `Decodable` type and example JSON data.
    ///
    /// This is the runtime target of the `#gen(T.self, from: Data)` macro expansion. Do not call directly — use `#gen` instead.
    static func _macroGenDecodable<T: Decodable>(
        _ type: T.Type,
        from data: Data
    ) throws -> ReflectiveGenerator<T> {
        try GeneratorSynthesizer.makeGenerator(type, from: data)
    }

    /// Synthesises a generator from a `Decodable` type and an example JSON string.
    ///
    /// This is the runtime target of the `#gen(T.self, from: String)` macro expansion. Do not call directly — use `#gen` instead.
    static func _macroGenDecodable<T: Decodable>(
        _ type: T.Type,
        from string: String
    ) throws -> ReflectiveGenerator<T> {
        try GeneratorSynthesizer.makeGenerator(type, from: string)
    }

    /// Synthesises a generator from a `Codable` instance by encoding it to JSON first.
    ///
    /// This is the runtime target of the `#gen(instance)` macro expansion for `Codable` values. Do not call directly — use `#gen` instead.
    static func _macroGenCodableInstance<T: Codable>(
        _ instance: T
    ) throws -> ReflectiveGenerator<T> {
        let data = try JSONEncoder().encode(instance)
        return try GeneratorSynthesizer.makeGenerator(T.self, from: data)
    }
}
