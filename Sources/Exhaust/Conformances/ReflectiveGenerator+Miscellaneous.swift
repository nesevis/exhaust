//
//  ReflectiveGenerator+Miscellaneous.swift
//  Exhaust
//
//  Created by Chris Kolbu on 24/2/2026.
//

import ExhaustCore

public extension ReflectiveGenerator {
    /// Creates a generator that always produces the same constant value.
    ///
    /// ```swift
    /// let gen = #gen(.just(42))
    /// ```
    static func just(_ value: Value) -> ReflectiveGenerator<Value> {
        Gen.just(value)
    }

    /// Generates arbitrary `Bool` values. Reduces toward `false`.
    ///
    /// ```swift
    /// let gen = #gen(.bool())
    /// ```
    static func bool() -> ReflectiveGenerator<Bool> {
        Gen.choose(in: UInt8(0) ... 1)
            .mapped(
                forward: { $0 == 1 },
                backward: { $0 ? 1 : 0 }
            )
    }

    /// Creates a generator that randomly selects from one of the provided generators with equal weight.
    ///
    /// ```swift
    /// let gen = #gen(.oneOf(.int(in: 0...5), .int(in: 100...105)))
    /// ```
    static func oneOf(
        _ generators: ReflectiveGenerator<Value>...,
        fileID: String = #fileID,
        line: UInt = #line,
        column: UInt = #column
    ) -> ReflectiveGenerator<Value> {
        Gen.pick(choices: generators.map { (1, $0) }, fileID: fileID, line: line, column: column)
    }

    /// Creates a generator that randomly selects from weighted generators.
    ///
    /// ```swift
    /// let gen = #gen(.oneOf(weighted: (1, .just(0)), (5, .int(in: 1...100))))
    /// ```
    static func oneOf(
        weighted choices: (Int, ReflectiveGenerator<Value>)...,
        fileID: String = #fileID,
        line: UInt = #line,
        column: UInt = #column
    ) -> ReflectiveGenerator<Value> {
        Gen.pick(choices: choices.map { ($0.0, $0.1) }, fileID: fileID, line: line, column: column)
    }
}

public extension ReflectiveGenerator where Operation == ReflectiveOperation {
    /// Wraps this generator to produce optional values, choosing between `nil` and a generated value.
    ///
    /// ```swift
    /// let gen = #gen(.int(in: 0...10)).optional()
    /// ```
    func optional() -> ReflectiveGenerator<Value?> {
        Gen.pick(choices: [
            (1, Gen.just(.none)),
            (5, asOptional()),
        ])
    }
}

public extension ReflectiveGenerator {
    /// Generates arbitrary `Result` values by choosing between a success and a failure generator with equal weight.
    ///
    /// Both branches are fully reflective — the backward pass extracts the inner value from the matching `Result` case and signals a mismatch for the other case, allowing ``Gen/pick(choices:)`` to select the correct branch during reflection.
    ///
    /// ```swift
    /// let gen = #gen(.result(
    ///     success: .int(in: 0...100),
    ///     failure: .element(from: [MyError.notFound, MyError.timeout])
    /// ))
    /// ```
    ///
    /// - Parameters:
    ///   - success: Generator for the success value.
    ///   - failure: Generator for the failure value.
    /// - Returns: A generator producing `Result` values.
    static func result<Success, Failure: Error>(
        success: ReflectiveGenerator<Success>,
        failure: ReflectiveGenerator<Failure>
    ) -> ReflectiveGenerator<Result<Success, Failure>>
        where Value == Result<Success, Failure>
    {
        Gen.pick(choices: [
            (1, Gen.contramap(
                { (result: Result<Success, Failure>) throws -> Success in
                    guard case let .success(value) = result else {
                        throw Interpreters.ReflectionError.contramapWasWrongType
                    }
                    return value
                },
                success._map { Result<Success, Failure>.success($0) }
            )),
            (1, Gen.contramap(
                { (result: Result<Success, Failure>) throws -> Failure in
                    guard case let .failure(error) = result else {
                        throw Interpreters.ReflectionError.contramapWasWrongType
                    }
                    return error
                },
                failure._map { Result<Success, Failure>.failure($0) }
            )),
        ])
    }
}
