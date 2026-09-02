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
        Gen.just(value).wrapped(isReflective: true)
    }

    /// Defers construction of a generator until generation actually reaches it.
    ///
    /// Use this for recursive generators, or for expensive branches of `.oneOf`, where building the subgenerator eagerly would rebuild the whole recursive tree on every invocation of the enclosing generator. The closure runs each time generation or replay reaches this point, so it must be pure: given no input, it must always return a structurally identical generator, or replay and reduction lose determinism.
    ///
    /// ```swift
    /// .oneOf(
    ///     .just(Tree.leaf),
    ///     .lazy { treeGen(depth: depth - 1) }
    /// )
    /// ```
    ///
    /// - Note: Implemented as a unit `bound`, so reflection passes through into the constructed generator: the backward direction trivially recovers the unit input and delegates to `make()`'s generator. The wrapper reports reflective regardless of the inner generator; a non-reflective inner surfaces at runtime through `#examine` or a failing `reflecting:`, the same exposure every `bound` continuation has.
    /// - Parameter make: A pure function that constructs the deferred generator. It runs on every generation, replay, and reflection pass, so it must always return a structurally identical generator.
    /// - Returns: A generator that builds and runs `make()`'s result on demand.
    static func lazy(
        _ make: @Sendable @escaping () -> ReflectiveGenerator<Output>,
        fileID: StaticString = #fileID,
        line: UInt = #line,
        column: UInt = #column
    ) -> ReflectiveGenerator<Output> {
        ReflectiveGenerator<Void>.just(()).bound(
            forward: { _ in make() },
            backward: { _ in () },
            fileID: fileID,
            line: line,
            column: column
        )
    }

    /// Generates arbitrary `Bool` values. Reduces toward `false`.
    ///
    /// ```swift
    /// let gen = #gen(.bool())
    /// ```
    static func bool() -> ReflectiveGenerator<Bool> {
        Gen.choose(in: UInt8(0) ... 1, scaling: .constant).wrapped(isReflective: true)
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
        _ generators: ReflectiveGenerator<Output>...,
        fileID: StaticString = #fileID,
        line: UInt = #line,
        column: UInt = #column
    ) -> ReflectiveGenerator<Output> {
        Gen.pick(choices: generators.map { (1, $0.gen) }, fileID: fileID, line: line, column: column).wrapped(isReflective: generators.allSatisfy { $0.isReflective })
    }

    /// Creates a generator that randomly selects from weighted generators.
    ///
    /// Entries with weight zero are removed before the pick is built, so `oneOf` never carries a branch that cannot be drawn. (``backtrack(failable:fileID:line:column:)`` is the one combinator that does: its zero-weight arm records absence.) When that removal leaves exactly one entry, its generator is returned directly with no pick node; a list that starts with a single entry keeps its pick. At least one entry must have a nonzero weight.
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
        oneOf(weighted: choices, fileID: fileID, line: line, column: column)
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
        Gen.pick(choices: generators.map { (1, $0.gen) }, fileID: fileID, line: line, column: column).wrapped(isReflective: generators.allSatisfy { $0.isReflective })
    }

    /// Selects from an array of weighted generators.
    ///
    /// Entries with weight zero are removed before the pick is built, so `oneOf` never carries a branch that cannot be drawn. (``backtrack(failable:fileID:line:column:)`` is the one combinator that does: its zero-weight arm records absence.) When that removal leaves exactly one entry, its generator is returned directly with no pick node; a list that starts with a single entry keeps its pick. At least one entry must have a nonzero weight.
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
        var pickChoices: [(weight: Int, generator: Generator<Output>)] = []
        pickChoices.reserveCapacity(choices.count)
        var allReflective = true
        var lastActiveGenerator: ReflectiveGenerator<Output>?
        for index in 0 ..< choices.count {
            let (weight, generator) = choices[index]
            if weight == 0 {
                continue
            }
            pickChoices.append((weight, generator.gen))
            allReflective = allReflective && generator.isReflective
            lastActiveGenerator = generator
        }
        precondition(pickChoices.isEmpty == false, "At least one oneOf choice must have a nonzero weight")
        // A list that starts with one entry keeps its pick node: the @StateMachine macro synthesizes single-command generators this way, and the concurrent runners require a top-level pick.
        let zeroWeightRemovalOccurred = pickChoices.count < choices.count
        if zeroWeightRemovalOccurred, pickChoices.count == 1, let lastActiveGenerator {
            return lastActiveGenerator
        }
        return Gen.pick(choices: pickChoices, fileID: fileID, line: line, column: column).wrapped(isReflective: allReflective)
    }

    /// Wraps this generator to produce optional values, choosing between `nil` and a generated value.
    ///
    /// The `someWeight` and `noneWeight` parameters control the relative frequency of `.some` versus `nil`. The defaults produce `nil` roughly 20% of the time. Both weights must be at least 1; a zero or negative weight traps at construction. To never produce `nil`, use the wrapped generator without `optional`; to always produce `nil`, use `.just(nil)`.
    ///
    /// ```swift
    /// let gen = #gen(.int(in: 0...10)).optional()
    /// let nilHeavy = #gen(.int(in: 0...10)).optional(someWeight: 1, noneWeight: 3)
    /// ```
    ///
    /// - Parameters:
    ///   - someWeight: Relative weight for generating a value. Must be at least 1. Defaults to 4.
    ///   - noneWeight: Relative weight for generating `nil`. Must be at least 1. Defaults to 1.
    func optional(
        someWeight: Int = 4,
        noneWeight: Int = 1
    ) -> ReflectiveGenerator<Output?> {
        Gen.pick(choices: [
            (someWeight, gen.liftToOptional()),
            (noneWeight, Gen.just(.none)),
        ]).wrapped(isReflective: isReflective)
    }

    /// Wraps a generator to produce optional values, choosing between `nil` and a generated value.
    ///
    /// The `someWeight` and `noneWeight` parameters control the relative frequency of `.some` versus `nil`. The defaults produce `nil` roughly 20% of the time. Both weights must be at least 1; a zero or negative weight traps at construction. To never produce `nil`, use the wrapped generator without `optional`; to always produce `nil`, use `.just(nil)`.
    ///
    /// ```swift
    /// let gen = #gen(.optional(.int(in: 0...10)))
    /// let nilHeavy = #gen(.optional(.int(in: 0...10), someWeight: 1, noneWeight: 3))
    /// ```
    ///
    /// - Parameters:
    ///   - gen: The generator to wrap.
    ///   - someWeight: Relative weight for generating a value. Must be at least 1. Defaults to 4.
    ///   - noneWeight: Relative weight for generating `nil`. Must be at least 1. Defaults to 1.
    static func optional<Wrapped>(
        _ gen: ReflectiveGenerator<Wrapped>,
        someWeight: Int = 4,
        noneWeight: Int = 1
    ) -> ReflectiveGenerator<Wrapped?> {
        // `Wrapped` is a method generic and `Output` stays free so the implicit-member form infers: the chain's result must equal its contextual base, and a result spelled `ReflectiveGenerator<Output?>` could never equal a base of `ReflectiveGenerator<Output>`.
        Gen.pick(choices: [
            (someWeight, gen.gen.liftToOptional()),
            (noneWeight, Gen.just(Wrapped?.none)),
        ]).wrapped(isReflective: gen.isReflective)
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
    ) -> ReflectiveGenerator<Result<Success, Failure>> {
        Gen.pick(choices: [
            (1, Gen.contramap(
                { (result: Result<Success, Failure>) throws -> Success in
                    guard case let .success(value) = result else {
                        throw ReflectionError.contramapWasWrongType
                    }
                    return value
                },
                success.gen.map { Result<Success, Failure>.success($0) }
            )),
            (1, Gen.contramap(
                { (result: Result<Success, Failure>) throws -> Failure in
                    guard case let .failure(error) = result else {
                        throw ReflectionError.contramapWasWrongType
                    }
                    return error
                },
                failure.gen.map { Result<Success, Failure>.failure($0) }
            )),
        ]).wrapped(isReflective: success.isReflective && failure.isReflective)
    }
}
