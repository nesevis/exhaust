//
//  ReflectiveGenerator+Miscellaneous.swift
//  Exhaust
//

public extension ReflectiveGenerator {
    /// Creates a generator that always produces the same constant value.
    ///
    /// ```swift
    /// let gen = #gen(.just(42))
    /// ```
    static func just(_ value: Output) -> ReflectiveGenerator<Output> {
        Gen.just(value).wrapped
    }

    /// Generates arbitrary `Bool` values. Reduces toward `false`.
    ///
    /// ```swift
    /// let gen = #gen(.bool())
    /// ```
    static func bool() -> ReflectiveGenerator<Bool> {
        Gen.choose(in: UInt8(0) ... 1, scaling: .constant).wrapped.mapped(
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
        _ generators: ReflectiveGenerator<Output>...,
        fileID: StaticString = #fileID,
        line: UInt = #line,
        column: UInt = #column
    ) -> ReflectiveGenerator<Output> {
        Gen.pick(choices: generators.map { (1, $0.gen) }, fileID: fileID, line: line, column: column).wrapped
    }

    /// Creates a generator that randomly selects from weighted generators.
    ///
    /// ```swift
    /// let gen = #gen(.oneOf(weighted: (1, .just(0)), (5, .int(in: 1...100))))
    /// ```
    static func oneOf(
        weighted choices: (Int, ReflectiveGenerator<Output>)...,
        fileID: StaticString = #fileID,
        line: UInt = #line,
        column: UInt = #column
    ) -> ReflectiveGenerator<Output> {
        Gen.pick(choices: choices.map { ($0.0, $0.1.gen) }, fileID: fileID, line: line, column: column).wrapped
    }

    /// Selects from an array of generators with equal weight.
    ///
    /// ```swift
    /// let gens: [ReflectiveGenerator<Int>] = [.int(in: 0...5), .int(in: 100...105)]
    /// let gen = #gen(.oneOf(gens))
    /// ```
    static func oneOf(
        _ generators: [ReflectiveGenerator<Output>],
        fileID: StaticString = #fileID,
        line: UInt = #line,
        column: UInt = #column
    ) -> ReflectiveGenerator<Output> {
        Gen.pick(choices: generators.map { (1, $0.gen) }, fileID: fileID, line: line, column: column).wrapped
    }

    /// Selects from an array of weighted generators.
    ///
    /// ```swift
    /// let choices: [(Int, ReflectiveGenerator<Int>)] = [(1, .just(0)), (5, .int(in: 1...100))]
    /// let gen = #gen(.oneOf(weighted: choices))
    /// ```
    static func oneOf(
        weighted choices: [(Int, ReflectiveGenerator<Output>)],
        fileID: StaticString = #fileID,
        line: UInt = #line,
        column: UInt = #column
    ) -> ReflectiveGenerator<Output> {
        Gen.pick(choices: choices.map { ($0.0, $0.1.gen) }, fileID: fileID, line: line, column: column).wrapped
    }

    /// Wraps this generator to produce optional values, choosing between `nil` and a generated value.
    ///
    /// The `someWeight` and `noneWeight` parameters control the relative frequency of `.some` versus `nil`. The defaults produce `nil` roughly 20% of the time.
    ///
    /// ```swift
    /// let gen = #gen(.int(in: 0...10)).optional()
    /// let nilHeavy = #gen(.int(in: 0...10)).optional(someWeight: 1, noneWeight: 3)
    /// ```
    ///
    /// - Parameters:
    ///   - someWeight: Relative weight for generating a value. Defaults to 4.
    ///   - noneWeight: Relative weight for generating `nil`. Defaults to 1.
    func optional(
        someWeight: Int = 4,
        noneWeight: Int = 1
    ) -> ReflectiveGenerator<Output?> {
        Gen.pick(choices: [
            (noneWeight, Gen.just(.none)),
            (someWeight, gen.liftToOptional()),
        ]).wrapped
    }

    /// Generates arbitrary `Result` values by choosing between a success and a failure generator with equal weight.
    ///
    /// Reflection decomposes a `Result` value by matching the `.success` or `.failure` case and reflecting the inner value through the corresponding generator.
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
        where Output == Result<Success, Failure>
    {
        Gen.pick(choices: [
            (1, Gen.contramap(
                { (result: Result<Success, Failure>) throws -> Success in
                    guard case let .success(value) = result else {
                        throw Interpreters.ReflectionError.contramapWasWrongType
                    }
                    return value
                },
                success.gen.map { Result<Success, Failure>.success($0) }
            )),
            (1, Gen.contramap(
                { (result: Result<Success, Failure>) throws -> Failure in
                    guard case let .failure(error) = result else {
                        throw Interpreters.ReflectionError.contramapWasWrongType
                    }
                    return error
                },
                failure.gen.map { Result<Success, Failure>.failure($0) }
            )),
        ]).wrapped
    }
}
