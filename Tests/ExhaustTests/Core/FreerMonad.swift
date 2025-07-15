//
//  FreerMonad.swift
//  Exhaust
//
//  Created by Chris Kolbu on 16/7/2025.
//

@testable import Exhaust
import Testing

// A simple implementation for testing purposes
typealias LoggingFreerMonad<Value> = FreerMonad<LoggingOperation, Value>

enum LoggingOperation {
    case log(message: String)
}

func log(_ message: String) -> LoggingFreerMonad<Void> {
    .impure(operation: .log(message: message)) { _ in .pure(()) }
}

// MARK: - Test Cases

@Test("A pure monad should interpret to its value without affecting state")
func pureValueInterpretation() {
    // Arrange
    let output = "hello"
    let pureMonad = LoggingFreerMonad.pure(output)
    
    // Act
    let result = interpret(pureMonad)
    
    // Assert
    #expect(result.value == output)
    #expect(result.log.isEmpty, "A pure case should not affect the store.")
}

// MARK: - Functor Laws

@Test("Functor Law: Identity (map(id) == id)")
/// A Functor must satisfy: `m.map { $0 }` is equivalent to `m`
func functorIdentity() {
    // Arrange
    let functor = log("Action").map { 42 }
    
    // Act
    let lhsResult = interpret(functor.map { $0 })
    let rhsResult = interpret(functor)
    
    // Assert
    #expect(lhsResult.value == rhsResult.value)
    #expect(lhsResult.log == rhsResult.log)
}

@Test("Functor Law: Composition (map(g • f) == map(f).map(g))")
/// A Functor must satisfy: `m.map { function2(function1($0)) }` is equivalent to `m.map(function1).map(function2)`
func functorComposition() {
    // Arrange
    let functor = log("Start").map { 10 } // Initial monad producing an Int
    let function1: (Int) -> String = { "\($0 * 2)" }
    let function2: (String) -> String = { "Value is \($0)" }
    
    // Act
    let lhsResult = interpret(functor.map { function2(function1($0)) })
    let rhsResult = interpret(functor.map(function1).map(function2))

    // Assert
    #expect(lhsResult.value == rhsResult.value)
    #expect(lhsResult.log == rhsResult.log, "The side-effects (logs) should be identical.")
    #expect(lhsResult.value == "Value is 20")
}


// MARK: Monad Laws

@Test("Monad Law: Left Identity (return a >>= f == f a)")
/// A Monad must satisfy: `pure(output).bind(function)` is equivalent to `f(output)`
func monadLeftIdentity() {
    // Arrange
    let output = "World"
    let function: (String) -> LoggingFreerMonad<String> = { name in
        log("Hello, \(name)").map { _ in "Done" }
    }
    
    // Act
    let lhsResult = interpret(LoggingFreerMonad.pure(output).bind(function))
    let rhsResult = interpret(function(output))
    
    // Assert
    #expect(lhsResult.value == rhsResult.value)
    #expect(lhsResult.log == rhsResult.log)
}

@Test("Monad Law: Right Identity (m >>= return == m)")
/// A Monad must satisfy: `monad.bind { .pure($0) }` is equivalent to `monad`
func monadRightIdentity() {
    // Arrange
    let monad = log("Step 1").bind { log("Step 2") }.map { 123 }
    
    // Act
    let lhsResult = interpret(monad.bind { .pure($0) })
    let rhsResult = interpret(monad)
    
    // Assert
    #expect(lhsResult.value == rhsResult.value)
    #expect(lhsResult.log == rhsResult.log)
}

@Test("Monad Law: Associativity ((m >>= f) >>= g == m >>= (x -> f(x) >>= g))")
/// A Monad must satisfy: `(monad.bind(function1)).bind(function2)` is equivalent to `m.bind { x in function1(x).bind(function2) }`
func monadAssociativity() {
    // Arrange: Use a chain that changes types to stress the generic interpreter.
    let monad: LoggingFreerMonad<String> = log("Start").map { "Value from m" }

    let function1: (String) -> LoggingFreerMonad<Int> = { val in
        log("function received '\(val)'").map { 42 }
    }
    
    let function2: (Int) -> LoggingFreerMonad<Bool> = { val in
        log("result received \(val)").map { true }
    }
    
    // Act
    let lhsResult = interpret(monad.bind(function1).bind(function2))
    let rhsResult = interpret(monad.bind { x in function1(x).bind(function2) })
    
    // Assert
    #expect(lhsResult.value == rhsResult.value)
    #expect(lhsResult.log == rhsResult.log, "The sequence of operations must be identical.")
    
    // Also check the final state to be sure the test is meaningful
    let expectedLog = ["Start", "function1 received 'Value from m'", "function2 received 42"]
    #expect(lhsResult.log == expectedLog)
    #expect(lhsResult.value == true)
}

// MARK: - Interpreter logic

func interpret<Value>(_ monad: LoggingFreerMonad<Value>) -> (value: Value?, log: [String]) {
    var accumulatedLog: [String] = []
    
    // The recursive function needs to mutate the log, so we pass it as an `inout` parameter.
    // It returns only the final value.
    let finalValue = interpretLogRecursive(monad, log: &accumulatedLog)
    
    return (finalValue, accumulatedLog)
}

/// The private, recursive engine for the logging interpreter.
private func interpretLogRecursive<Value>(_ monad: LoggingFreerMonad<Value>, log: inout [String]) -> Value? {
    switch monad {
    // Base case: We've reached a pure value. Return it.
    case .pure(let value):
        return value

    // Recursive step: We have an operation to perform.
    case .impure(let operation, let continuation):
        switch operation {
        case .log(let message):
            // 1. Perform the side-effect (mutate the log).
            log.append(message)
            
            // 2. Get the next monad in the chain by calling the continuation.
            //    The log operation itself produces `()`.
            let nextMonad = continuation(())
            
            // 3. Recursively call the interpreter on the next monad.
            //    The compiler correctly infers the `Value` type for the next step.
            return interpretLogRecursive(nextMonad, log: &log)
        }
    }
}
