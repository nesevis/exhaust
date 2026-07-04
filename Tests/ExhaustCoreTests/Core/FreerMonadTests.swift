//
//  FreerMonad.swift
//  Exhaust
//
//  Created by Chris Kolbu on 16/7/2025.
//

import ExhaustCore
import ExhaustTestSupport
import Testing

@Suite("Monad law tests", .tags(.dogfood))
struct MonadLawTests {
    @Test("pure(a) interprets to a with no side effects")
    func pureValueInterpretation() throws {
        try exhaustCheck(Gen.choose(in: -1000 ... 1000)) { value in
            let result = try interpret(LoggingFreerMonad.pure(value))
            return result.value == value && result.log.isEmpty
        }
    }

    @Test("Functor Law: Identity (map(id) == id)")
    func functorIdentity() throws {
        try exhaustCheck(Gen.choose(in: -1000 ... 1000)) { value in
            let monad = log("Action").map { value }
            let lhs = try interpret(monad.map(\.self))
            let rhs = try interpret(monad)
            return lhs.value == rhs.value && lhs.log == rhs.log
        }
    }

    @Test("Functor Law: Composition (map(g . f) == map(f).map(g))")
    func functorComposition() throws {
        try exhaustCheck(Gen.choose(in: -1000 ... 1000)) { value in
            let monad = log("Start").map { value }
            let f: (Int) -> String = { "\($0 * 2)" }
            let g: (String) -> String = { "Value is \($0)" }
            let lhs = try interpret(monad.map { g(f($0)) })
            let rhs = try interpret(monad.map(f).map(g))
            return lhs.value == rhs.value && lhs.log == rhs.log
        }
    }

    @Test("Monad Law: Left Identity (return a >>= f == f a)")
    func monadLeftIdentity() throws {
        try exhaustCheck(Gen.choose(in: -1000 ... 1000)) { value in
            let f: (Int) -> LoggingFreerMonad<String> = { n in
                log("Received \(n)").map { _ in "Done" }
            }
            let lhs = try interpret(LoggingFreerMonad.pure(value).bind(f))
            let rhs = try interpret(f(value))
            return lhs.value == rhs.value && lhs.log == rhs.log
        }
    }

    @Test("Monad Law: Right Identity (m >>= return == m)")
    func monadRightIdentity() throws {
        try exhaustCheck(Gen.choose(in: -1000 ... 1000)) { value in
            let monad = log("Step").map { value }
            let lhs = try interpret(monad.bind { .pure($0) })
            let rhs = try interpret(monad)
            return lhs.value == rhs.value && lhs.log == rhs.log
        }
    }

    @Test("Monad Law: Associativity ((m >>= f) >>= g == m >>= (x -> f(x) >>= g))")
    func monadAssociativity() throws {
        try exhaustCheck(Gen.choose(in: -1000 ... 1000)) { value in
            let monad: LoggingFreerMonad<Int> = log("Start").map { value }
            let f: (Int) -> LoggingFreerMonad<String> = { n in
                log("f(\(n))").map { "\(n)" }
            }
            let g: (String) -> LoggingFreerMonad<Bool> = { s in
                log("g(\(s))").map { s.isEmpty == false }
            }
            let lhs = try interpret(monad.bind(f).bind(g))
            let rhs = try interpret(monad.bind { x in f(x).bind(g) })
            return lhs.value == rhs.value && lhs.log == rhs.log
        }
    }
}

// MARK: - Partial Monadic Profunctor Law Tests

@Suite("Partial Monadic Profunctor law tests")
struct PartialMonadicProfunctorLawTests {
    /// A Partial Monadic Profunctor must satisfy: `Gen.contramap({ $0 }, Gen.prune(generator))` is equivalent to `generator`.
    @Test("PMP Law 1: contramap(Just) . prune == identity")
    func pmpLaw1_ContramapJustPruneIsIdentity() throws {
        let generator = Gen.choose(in: -1000 ... 1000) as Generator<Int>
        let lhs = Gen.contramap({ $0 as Int }, Gen.prune(generator))
        try assertSameForwardOutput(lhs, generator)
    }

    /// A PMP must satisfy: `contramap(compose(f,g)) . prune` is equivalent to `contramap(f) . prune . contramap(g) . prune`.
    @Test("PMP Law 2: Composition associativity")
    func pmpLaw2_CompositionAssociativity() throws {
        let generator = (Gen.choose(in: 1 ... 100) as Generator<Int>).map { "value-\($0)" }

        let f: (String) -> Int? = { str in str.isEmpty ? nil : str.count }
        let g: (Int) -> String? = { num in num > 0 ? "length-\(num)" : nil }

        let composed: (String) -> String? = { str in
            guard let intermediate = f(str) else { return nil }
            return g(intermediate)
        }

        let lhs = Gen.contramap(composed, Gen.prune(generator))
        let rhs = Gen.contramap(g, Gen.prune(Gen.contramap(f, Gen.prune(generator))))
        try assertSameForwardOutput(lhs, rhs)
    }

    /// A PMP must satisfy: `Gen.contramap(f, Gen.prune(.pure(y)))` is equivalent to `.pure(y)`.
    @Test("PMP Law 3: contramap . prune over pure values")
    func pmpLaw3_contramapPruneOverPure() throws {
        let pureValue = "test"
        let transform: (String) -> Int? = { $0.isEmpty == false ? $0.count : nil }

        let lhs = Gen.contramap(transform, Gen.prune(Generator.pure(pureValue)))
        let rhs = Generator<String>.pure(pureValue)
        try assertSameForwardOutput(lhs, rhs)
    }

    /// A PMP must satisfy: `(contramap f . prune)(x >>= g)` is equivalent to `(contramap f . prune) x >>= (contramap f . prune) . g`.
    @Test("PMP Law 4: contramap . prune distributes over bind")
    func pmpLaw4_contramapPruneDistributesOverBind() throws {
        let baseGenerator = Gen.choose(in: 1 ... 50) as Generator<Int>
        // Crucial: bindFunction must return a generator with the SAME input type as base
        let bindFunction: (Int) -> Generator<String> = { val in
            (Gen.choose(in: 0 ... 9) as Generator<Int>).map { "Value: \(val).\($0)" }
        }
        // transform maps from NewInput to original input type (Optional)
        let transform: (String) -> Int? = { str in
            str.hasPrefix("Value:") ? str.count : nil
        }

        // LHS: (contramap f . prune)(x >>= g)
        let boundGenerator = baseGenerator.bind(bindFunction)
        let lhs = Gen.contramap(transform, Gen.prune(boundGenerator))

        // RHS: (contramap f . prune) x >>= (contramap f . prune) . g
        let transformedBase = Gen.contramap(transform, Gen.prune(baseGenerator))
        let transformedFunction: (Int) -> Generator<String> = { val in
            Gen.contramap(transform, Gen.prune(bindFunction(val)))
        }
        let rhs = transformedBase.bind(transformedFunction)

        try assertSameForwardOutput(lhs, rhs)
    }

    // MARK: - Additional Profunctor Laws

    /// A Profunctor must satisfy: `Gen.contramap(identity, generator)` is equivalent to `generator`.
    @Test("Profunctor Law 1: contramap(identity) == identity")
    func profunctorLaw1_contramapIdentity() throws {
        let generator = Gen.choose(in: -1000 ... 1000) as Generator<Int>
        let identity: (Int) -> Int = { $0 }

        let lhs = Gen.contramap(identity, generator)
        try assertSameForwardOutput(lhs, generator)
    }

    /// A Profunctor must satisfy: `contramap(f . g)` is equivalent to `contramap(g, contramap(f, generator))`.
    @Test("Profunctor Law 2: contramap(compose(f,g)) == contramap(g) . contramap(f)")
    func profunctorLaw2_contramapComposition() throws {
        let generator = Gen.choose(in: 1 ... 1000) as Generator<Int>
        let f: (String) -> Int = { $0.count }
        let g: (Int) -> String = { "Value: \($0)" }
        let composed: (String) -> String = { str in g(f(str)) }

        let lhs = Gen.contramap(composed, generator)
        let rhs = Gen.contramap(g, Gen.contramap(f, generator))
        try assertSameForwardOutput(lhs, rhs)
    }

    // MARK: - Comap Law Tests

    /// The comap combinator should be equivalent to `contramap(transform, prune(generator))`.
    @Test("Comap is equivalent to contramap . prune")
    func comapEquivalence() throws {
        let generator = Gen.choose(in: -1000 ... 1000) as Generator<Int>
        let transform: (String) -> Int? = { str in str.isEmpty ? nil : str.count }

        let comapResult = Gen.comap(transform, generator)
        let contramapPruneResult = Gen.contramap(transform, Gen.prune(generator))
        try assertSameForwardOutput(comapResult, contramapPruneResult)
    }
}

// MARK: - Interpreter logic

/// A simple implementation for testing purposes
typealias LoggingFreerMonad<Value> = FreerMonad<LoggingOperation, Value>

enum LoggingOperation {
    case log(message: String)
}

func log(_ message: String) -> LoggingFreerMonad<Void> {
    .impure(operation: .log(message: message)) { _ in .pure(()) }
}

func interpret<Value>(_ monad: LoggingFreerMonad<Value>) throws -> (value: Value?, log: [String]) {
    var accumulatedLog: [String] = []

    // The recursive function needs to mutate the log, so we pass it as an `inout` parameter.
    // It returns only the final value.
    let finalValue = try interpretLogRecursive(monad, log: &accumulatedLog)

    return (finalValue, accumulatedLog)
}

/// The private, recursive engine for the logging interpreter.
private func interpretLogRecursive<Value>(_ monad: LoggingFreerMonad<Value>, log: inout [String]) throws -> Value? {
    switch monad {
        // Base case: We've reached a pure value. Return it.
        case let .pure(value):
            return value

        // Recursive step: We have an operation to perform.
        case let .impure(operation, continuation):
            switch operation {
                case let .log(message):
                    // 1. Perform the side-effect (mutate the log).
                    log.append(message)

                    // 2. Get the next monad in the chain by calling the continuation.
                    //    The log operation itself produces `()`.
                    let nextMonad = try continuation(())

                    // 3. Recursively call the interpreter on the next monad.
                    //    The compiler correctly infers the `Value` type for the next step.
                    guard let value = try interpretLogRecursive(nextMonad, log: &log) as? Value else {
                        return nil
                    }
                    return value
            }
    }
}

// MARK: - Law Test Helpers

/// Draws `draws` values from each generator with the same seed and asserts pairwise equality. The wrappers under test consume no entropy of their own, so equal seeds must give equal forward output on every draw, not just the first.
private func assertSameForwardOutput<Value: Equatable>(
    _ lhs: Generator<Value>,
    _ rhs: Generator<Value>,
    seed: UInt64 = 42,
    draws: Int = 20,
    sourceLocation: SourceLocation = #_sourceLocation
) throws {
    var lhsIterator = ValueInterpreter(lhs, seed: seed, maxRuns: UInt64(draws))
    var rhsIterator = ValueInterpreter(rhs, seed: seed, maxRuns: UInt64(draws))

    for draw in 0 ..< draws {
        let lhsValue = try #require(try lhsIterator.next(), sourceLocation: sourceLocation)
        let rhsValue = try #require(try rhsIterator.next(), sourceLocation: sourceLocation)
        #expect(lhsValue == rhsValue, "Draw \(draw): lhs=\(lhsValue), rhs=\(rhsValue)", sourceLocation: sourceLocation)
    }
}
