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
    // MARK: - PMP Law 1: contramap Just . prune = id

    /// A Partial Monadic Profunctor must satisfy: `Gen.contramap({ $0 }, Gen.prune(generator))` is equivalent to `generator`
    @Test("PMP Law 1: contramap(Just) . prune == identity")
    func pmpLaw1_ContramapJustPruneIsIdentity() throws {
        // Arrange
        let generator = Gen.just(Int(42))

        // Act: contramap(Just) . prune should be identity
        // Type discovery here is bad now with input parameterisation removed
        let lhs = Gen.contramap({ $0 as Int }, Gen.prune(generator))
        let rhs = generator

        var lhsIterator = ValueInterpreter(lhs)
        var rhsIterator = ValueInterpreter(rhs)

        // Test via generation - both should produce same value
        let lhsValue = try lhsIterator.next()
        let rhsValue = try rhsIterator.next()

        // Assert
        #expect(lhsValue == rhsValue)
    }

    // MARK: - PMP Law 2: contramap (f >=> g) . prune = contramap f . prune . contramap g . prune

    /// A PMP must satisfy: `contramap(compose(f,g)) . prune` is equivalent to `contramap(f) . prune . contramap(g) . prune`
    @Test("PMP Law 2: Composition associativity")
    func pmpLaw2_CompositionAssociativity() throws {
        // Arrange
        let generator = Gen.just("hello")

        let f: (String) -> Int? = { str in str.isEmpty ? nil : str.count }
        let g: (Int) -> String? = { num in num > 0 ? "length-\(num)" : nil }

        let composed: (String) -> String? = { str in
            guard let intermediate = f(str) else { return nil }
            return g(intermediate)
        }

        // Act
        // LHS: contramap(compose(f,g)) . prune
        let lhs = Gen.contramap(composed, Gen.prune(generator))

        // RHS: contramap(f) . prune . contramap(g) . prune
        let rhs = Gen.contramap(g, Gen.prune(Gen.contramap(f, Gen.prune(generator))))

        var lhsIterator = ValueInterpreter(lhs)
        var rhsIterator = ValueInterpreter(rhs)

        // Test via generation - both should produce same value
        let lhsValue = try lhsIterator.next()
        let rhsValue = try rhsIterator.next()

        // Assert
        #expect(lhsValue == rhsValue)
    }

    // MARK: - PMP Law 3: (contramap f . prune) (return y) = return y

    /// A PMP must satisfy: `Gen.contramap(f, Gen.prune(.pure(y)))` is equivalent to `.pure(y)`
    @Test("PMP Law 3: contramap . prune over pure values")
    func pmpLaw3_contramapPruneOverPure() throws {
        // Arrange
        let pureValue = "test"
        let transform: (String) -> Int? = { $0.isEmpty == false ? $0.count : nil }

        // Act
        let lhs = Gen.contramap(transform, Gen.prune(Generator.pure(pureValue)))
        let rhs = Generator<String>.pure(pureValue)

        var lhsIterator = ValueInterpreter(lhs)
        var rhsIterator = ValueInterpreter(rhs)

        // Test via generation - both should produce same value
        let lhsValue = try lhsIterator.next()
        let rhsValue = try rhsIterator.next()

        // Assert
        #expect(lhsValue == rhsValue)
    }

    // MARK: - PMP Law 4: (contramap f . prune) (x >>= g) = (contramap f . prune) x >>= (contramap f . prune) . g

    /// A PMP must satisfy: `(contramap f . prune)(x >>= g)` is equivalent to `(contramap f . prune) x >>= (contramap f . prune) . g`
    @Test("PMP Law 4: contramap . prune distributes over bind")
    func pmpLaw4_contramapPruneDistributesOverBind() throws {
        // Arrange - carefully chosen types for the law to work
        let baseGenerator = Generator<Int>.pure(5)
        // Crucial: bindFunction must return a generator with the SAME input type as base
        let bindFunction: (Int) -> Generator<String> = { val in
            Generator<String>.pure("Value: \(val)")
        }
        // transform maps from NewInput to original input type (Optional)
        let transform: (String) -> Int? = { str in
            str.hasPrefix("Value:") ? str.count : nil
        }

        // Act
        // LHS: (contramap f . prune)(x >>= g)
        let boundGenerator = baseGenerator.bind(bindFunction) // Generator<Int, String>
        let lhs = Gen.contramap(transform, Gen.prune(boundGenerator)) // Generator<String, String>

        // RHS: (contramap f . prune) x >>= (contramap f . prune) . g
        let transformedBase = Gen.contramap(transform, Gen.prune(baseGenerator)) // Generator<String, Int>

        // The bind function applies (contramap f . prune) to the result of g
        let transformedFunction: (Int) -> Generator<String> = { val in
            let resultGenerator = bindFunction(val) // Generator<Int, String>
            return Gen.contramap(transform, Gen.prune(resultGenerator)) // Generator<String, String>
        }
        let rhs = transformedBase.bind(transformedFunction) // Generator<String, String>

        var lhsIterator = ValueInterpreter(lhs)
        var rhsIterator = ValueInterpreter(rhs)

        // Test via generation - both should produce same value
        let lhsValue = try lhsIterator.next()
        let rhsValue = try rhsIterator.next()

        // Assert
        #expect(lhsValue == rhsValue)
    }

    // MARK: - Additional Profunctor Laws

    /// A Profunctor must satisfy: `Gen.contramap(identity, generator)` is equivalent to `generator`
    @Test("Profunctor Law 1: contramap(identity) == identity")
    func profunctorLaw1_contramapIdentity() throws {
        // Arrange
        let generator = Gen.just(42)
        let identity: (Int) -> Int = { $0 }

        // Act
        let lhs = Gen.contramap(identity, generator)
        let rhs = generator

        var lhsIterator = ValueInterpreter(lhs)
        var rhsIterator = ValueInterpreter(rhs)

        // Test via generation - both should produce same value
        let lhsValue = try lhsIterator.next()
        let rhsValue = try rhsIterator.next()

        // Assert
        #expect(lhsValue == rhsValue)
    }

    /// A Profunctor must satisfy: `contramap(f . g)` is equivalent to `contramap(g, contramap(f, generator))`
    @Test("Profunctor Law 2: contramap(compose(f,g)) == contramap(g) . contramap(f)")
    func profunctorLaw2_contramapComposition() throws {
        // Arrange
        let generator = Gen.just(100)
        let f: (String) -> Int = { $0.count }
        let g: (Int) -> String = { "Value: \($0)" }
        let composed: (String) -> String = { str in g(f(str)) }

        // Act
        let lhs = Gen.contramap(composed, generator)
        let rhs = Gen.contramap(g, Gen.contramap(f, generator))

        var lhsIterator = ValueInterpreter(lhs)
        var rhsIterator = ValueInterpreter(rhs)

        // Test via generation - both should produce same value
        let lhsValue = try lhsIterator.next()
        let rhsValue = try rhsIterator.next()

        // Assert
        #expect(lhsValue == rhsValue)
    }

    // MARK: - Comap Law Tests

    /// The comap combinator should be equivalent to `contramap(transform, prune(generator))`
    @Test("Comap is equivalent to contramap . prune")
    func comapEquivalence() throws {
        // Arrange
        let generator = Gen.just(42)
        let transform: (String) -> Int? = { str in str.isEmpty ? nil : str.count }

        // Act
        let comapResult = Gen.comap(transform, generator)
        let contramapPruneResult = Gen.contramap(transform, Gen.prune(generator))

        // Test via generation with valid input

        var lhsIterator = ValueInterpreter(comapResult)
        var rhsIterator = ValueInterpreter(contramapPruneResult)

        // Test via generation - both should produce same value
        let lhsValue = try lhsIterator.next()
        let rhsValue = try rhsIterator.next()

        // Assert
        #expect(lhsValue == rhsValue)
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
            return try interpretLogRecursive(nextMonad, log: &log)
        }
    }
}
