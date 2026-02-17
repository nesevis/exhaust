//
//  FreerMonad.swift
//  Exhaust
//
//  Created by Chris Kolbu on 16/7/2025.
//

import Testing
@testable import Exhaust

// MARK: - Test Cases

@Suite("Monad law tests")
struct MonadLawTests {
    @Test("A pure monad should interpret to its value without affecting state")
    func pureValueInterpretation() throws {
        // Arrange
        let output = "hello"
        let pureMonad = LoggingFreerMonad.pure(output)

        // Act
        let result = try interpret(pureMonad)

        // Assert
        #expect(result.value == output)
        #expect(result.log.isEmpty, "A pure case should not affect the store.")
    }

    // MARK: - Functor Laws

    /// A Functor must satisfy: `m.map { $0 }` is equivalent to `m`
    @Test("Functor Law: Identity (map(id) == id)")
    func functorIdentity() throws {
        // Arrange
        let functor = log("Action").map { 42 }

        // Act
        let lhsResult = try interpret(functor.map(\.self))
        let rhsResult = try interpret(functor)

        // Assert
        #expect(lhsResult.value == rhsResult.value)
        #expect(lhsResult.log == rhsResult.log)
    }

    /// A Functor must satisfy: `m.map { function2(function1($0)) }` is equivalent to `m.map(function1).map(function2)`
    @Test("Functor Law: Composition (map(g • f) == map(f).map(g))")
    func functorComposition() throws {
        // Arrange
        let functor = log("Start").map { 10 } // Initial monad producing an Int
        let function1: (Int) -> String = { "\($0 * 2)" }
        let function2: (String) -> String = { "Value is \($0)" }

        // Act
        let lhsResult = try interpret(functor.map { function2(function1($0)) })
        let rhsResult = try interpret(functor.map(function1).map(function2))

        // Assert
        #expect(lhsResult.value == rhsResult.value)
        #expect(lhsResult.log == rhsResult.log, "The side-effects (logs) should be identical.")
        #expect(lhsResult.value == "Value is 20")
    }

    // MARK: Monad Laws

    /// A Monad must satisfy: `pure(output).bind(function)` is equivalent to `f(output)`
    @Test("Monad Law: Left Identity (return a >>= f == f a)")
    func monadLeftIdentity() throws {
        // Arrange
        let output = "World"
        let function: (String) -> LoggingFreerMonad<String> = { name in
            log("Hello, \(name)").map { _ in "Done" }
        }

        // Act
        let lhsResult = try interpret(LoggingFreerMonad.pure(output).bind(function))
        let rhsResult = try interpret(function(output))

        // Assert
        #expect(lhsResult.value == rhsResult.value)
        #expect(lhsResult.log == rhsResult.log)
    }

    /// A Monad must satisfy: `monad.bind { .pure($0) }` is equivalent to `monad`
    @Test("Monad Law: Right Identity (m >>= return == m)")
    func monadRightIdentity() throws {
        // Arrange
        let monad = log("Step 1").bind { log("Step 2") }.map { 123 }

        // Act
        let lhsResult = try interpret(monad.bind { .pure($0) })
        let rhsResult = try interpret(monad)

        // Assert
        #expect(lhsResult.value == rhsResult.value)
        #expect(lhsResult.log == rhsResult.log)
    }

    /// A Monad must satisfy: `(monad.bind(function1)).bind(function2)` is equivalent to `m.bind { x in function1(x).bind(function2) }`
    @Test("Monad Law: Associativity ((m >>= f) >>= g == m >>= (x -> f(x) >>= g))")
    func monadAssociativity() throws {
        // Arrange: Use a chain that changes types to stress the generic interpreter.
        let monad: LoggingFreerMonad<String> = log("Start").map { "Value from m" }

        let function1: (String) -> LoggingFreerMonad<Int> = { val in
            log("function1 received '\(val)'").map { 42 }
        }

        let function2: (Int) -> LoggingFreerMonad<Bool> = { val in
            log("function2 received \(val)").map { true }
        }

        // Act
        let lhsResult = try interpret(monad.bind(function1).bind(function2))
        let rhsResult = try interpret(monad.bind { x in function1(x).bind(function2) })

        // Assert
        #expect(lhsResult.value == rhsResult.value)
        #expect(lhsResult.log == rhsResult.log, "The sequence of operations must be identical.")

        // Also check the final state to be sure the test is meaningful
        let expectedLog = ["Start", "function1 received 'Value from m'", "function2 received 42"]
        #expect(lhsResult.log == expectedLog)
        #expect(lhsResult.value == true)
    }
}

// MARK: - Partial Monadic Profunctor Law Tests

@Suite("Partial Monadic Profunctor law tests")
struct PartialMonadicProfunctorLawTests {
    // MARK: - PMP Law 1: contramap Just . prune = id

    /// A Partial Monadic Profunctor must satisfy: `Gen.contramap({ $0 }, Gen.prune(generator))` is equivalent to `generator`
    @Test("PMP Law 1: contramap(Just) . prune == identity")
    func pmpLaw1_ContramapJustPruneIsIdentity() {
        // Arrange
        let generator = Gen.just(Int(42))

        // Act: contramap(Just) . prune should be identity
        // Type discovery here is bad now with input parameterisation removed
        let lhs = Gen.contramap({ $0 as Int }, Gen.prune(generator))
        let rhs = generator

        var lhsIterator = ValueInterpreter(lhs)
        var rhsIterator = ValueInterpreter(rhs)

        // Test via generation - both should produce same value
        let lhsValue = lhsIterator.next()
        let rhsValue = rhsIterator.next()

        // Assert
        #expect(lhsValue == rhsValue)
    }

    // MARK: - PMP Law 2: contramap (f >=> g) . prune = contramap f . prune . contramap g . prune

    /// A PMP must satisfy: `contramap(compose(f,g)) . prune` is equivalent to `contramap(f) . prune . contramap(g) . prune`
    @Test("PMP Law 2: Composition associativity")
    func pmpLaw2_CompositionAssociativity() {
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
        let lhsValue = lhsIterator.next()
        let rhsValue = rhsIterator.next()

        // Assert
        #expect(lhsValue == rhsValue)
    }

    // MARK: - PMP Law 3: (contramap f . prune) (return y) = return y

    /// A PMP must satisfy: `Gen.contramap(f, Gen.prune(.pure(y)))` is equivalent to `.pure(y)`
    @Test("PMP Law 3: contramap . prune over pure values")
    func pmpLaw3_contramapPruneOverPure() {
        // Arrange
        let pureValue = "test"
        let transform: (String) -> Int? = { $0.isEmpty == false ? $0.count : nil }

        // Act
        let lhs = Gen.contramap(transform, Gen.prune(ReflectiveGenerator.pure(pureValue)))
        let rhs = ReflectiveGenerator<String>.pure(pureValue)

        var lhsIterator = ValueInterpreter(lhs)
        var rhsIterator = ValueInterpreter(rhs)

        // Test via generation - both should produce same value
        let lhsValue = lhsIterator.next()
        let rhsValue = rhsIterator.next()

        // Assert
        #expect(lhsValue == rhsValue)
    }

    // MARK: - PMP Law 4: (contramap f . prune) (x >>= g) = (contramap f . prune) x >>= (contramap f . prune) . g

    /// A PMP must satisfy: `(contramap f . prune)(x >>= g)` is equivalent to `(contramap f . prune) x >>= (contramap f . prune) . g`
    @Test("PMP Law 4: contramap . prune distributes over bind")
    func pmpLaw4_contramapPruneDistributesOverBind() {
        // Arrange - carefully chosen types for the law to work
        let baseGenerator = ReflectiveGenerator<Int>.pure(5)
        // Crucial: bindFunction must return a generator with the SAME input type as base
        let bindFunction: (Int) -> ReflectiveGenerator<String> = { val in
            ReflectiveGenerator<String>.pure("Value: \(val)")
        }
        // transform maps from NewInput to original input type (Optional)
        let transform: (String) -> Int? = { str in
            str.hasPrefix("Value:") ? str.count : nil
        }

        // Act
        // LHS: (contramap f . prune)(x >>= g)
        let boundGenerator = baseGenerator.bind(bindFunction) // ReflectiveGenerator<Int, String>
        let lhs = Gen.contramap(transform, Gen.prune(boundGenerator)) // ReflectiveGenerator<String, String>

        // RHS: (contramap f . prune) x >>= (contramap f . prune) . g
        let transformedBase = Gen.contramap(transform, Gen.prune(baseGenerator)) // ReflectiveGenerator<String, Int>

        // The bind function applies (contramap f . prune) to the result of g
        let transformedFunction: (Int) -> ReflectiveGenerator<String> = { val in
            let resultGenerator = bindFunction(val) // ReflectiveGenerator<Int, String>
            return Gen.contramap(transform, Gen.prune(resultGenerator)) // ReflectiveGenerator<String, String>
        }
        let rhs = transformedBase.bind(transformedFunction) // ReflectiveGenerator<String, String>

        var lhsIterator = ValueInterpreter(lhs)
        var rhsIterator = ValueInterpreter(rhs)

        // Test via generation - both should produce same value
        let lhsValue = lhsIterator.next()
        let rhsValue = rhsIterator.next()

        // Assert
        #expect(lhsValue == rhsValue)
    }

    // MARK: - Additional Profunctor Laws

    /// A Profunctor must satisfy: `Gen.contramap(identity, generator)` is equivalent to `generator`
    @Test("Profunctor Law 1: contramap(identity) == identity")
    func profunctorLaw1_contramapIdentity() {
        // Arrange
        let generator = Gen.just(42)
        let identity: (Int) -> Int = { $0 }

        // Act
        let lhs = Gen.contramap(identity, generator)
        let rhs = generator

        var lhsIterator = ValueInterpreter(lhs)
        var rhsIterator = ValueInterpreter(rhs)

        // Test via generation - both should produce same value
        let lhsValue = lhsIterator.next()
        let rhsValue = rhsIterator.next()

        // Assert
        #expect(lhsValue == rhsValue)
    }

    /// A Profunctor must satisfy: `contramap(f . g)` is equivalent to `contramap(g, contramap(f, generator))`
    @Test("Profunctor Law 2: contramap(compose(f,g)) == contramap(g) . contramap(f)")
    func profunctorLaw2_contramapComposition() {
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
        let lhsValue = lhsIterator.next()
        let rhsValue = rhsIterator.next()

        // Assert
        #expect(lhsValue == rhsValue)
    }

    // MARK: - Comap Law Tests

    /// The comap combinator should be equivalent to `contramap(transform, prune(generator))`
    @Test("Comap is equivalent to contramap . prune")
    func comapEquivalence() {
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
        let lhsValue = lhsIterator.next()
        let rhsValue = rhsIterator.next()

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
