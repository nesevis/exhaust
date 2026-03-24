import Benchmark
import Exhaust
import ExhaustCore
import Foundation

// swiftlint:disable force_try

// benchmark("Int Generation") {
//    let generator = Gen.choose(in: 0 ... 1000)
//    var iterator = ValueInterpreter(generator, seed: 1, maxRuns: 100)
//    while let next = try iterator.next() {
//        _ = next
//    }
// }
//
// benchmark("String generation") {
//    let generator = #gen(.string())
//    var iterator = ValueInterpreter(generator, seed: 1, maxRuns: 100)
//    while let next = try iterator.next() {
//        _ = next
//    }
// }
//
// benchmark("String generation with reflection") {
//    let generator = #gen(.string())
//    var iterator = ValueInterpreter(generator, seed: 1, maxRuns: 100)
//    while let next = try iterator.next() {
//        _ = try Interpreters.reflect(generator, with: next)
//    }
// }
//
// benchmark("String generation with choiceTree") {
//    let generator = #gen(.string())
//    var iterator = ValueAndChoiceTreeInterpreter(generator, seed: 1, maxRuns: 100)
//    while let (value, tree) = try iterator.next() {
//        _ = value
//        _ = tree
//    }
// }
//
//// There's no functional difference here between calling next() repeatedly and creating an array from the prefix
//
// benchmark("Double generation with choiceTree materialised") {
//    let generator = #gen(.oneOf(weighted: (1, .double()), (2, .double()), (4, .double())))
//    var iterator = ValueAndChoiceTreeInterpreter(generator, materializePicks: true, seed: 1, maxRuns: 100)
//    while let (value, tree) = try iterator.next() {
//        _ = value
//        _ = tree
//    }
// }
//
// benchmark("String generation with choiceTree materialised") {
//    let generator = #gen(.string())
//    var iterator = ValueAndChoiceTreeInterpreter(generator, materializePicks: true, seed: 1, maxRuns: 100)
//    while let _ = try iterator.next() {}
// }
//
// private struct Person {
//    let name: String
//    let age: UInt8
//    let height: Double
// }
//
// benchmark("Zipped person") {
//    let generator = #gen(.asciiString(), .uint8(), .double())
//        .mapped(forward: { Person(name: $0.0, age: $0.1, height: $0.2) }, backward: { ($0.name, $0.age, $0.height) })
//    var iterator = ValueInterpreter(generator, seed: 1, maxRuns: 100)
//    while let next = try iterator.next() {
//        _ = next
//    }
// }
//
// benchmark("Zipped person with reflection") {
//    let generator = #gen(.asciiString(), .uint8(), .double())
//        .mapped(forward: { Person(name: $0.0, age: $0.1, height: $0.2) }, backward: { ($0.name, $0.age, $0.height) })
//    var iterator = ValueInterpreter(generator, seed: 1, maxRuns: 100)
//    while let next = try iterator.next() {
//        _ = try Interpreters.reflect(generator, with: next)
//    }
// }
//
// benchmark("Zipped person with ChoiceTree") {
//    let generator = #gen(
//        .asciiString(),
//        .uint8(),
//        .double()
//    )
//    .mapped(forward: { Person(name: $0.0, age: $0.1, height: $0.2) }, backward: { ($0.name, $0.age, $0.height) })
//    var iterator = ValueAndChoiceTreeInterpreter(generator, materializePicks: true, seed: 1, maxRuns: 100)
//    while let (value, tree) = try iterator.next() {
//        _ = value
//        _ = tree
//    }
// }

struct Bound5: Equatable {
    let a: [Int16]
    let b: [Int16]
    let c: [Int16]
    let d: [Int16]
    let e: [Int16]

    let arr: [Int16]

    init(a: [Int16], b: [Int16], c: [Int16], d: [Int16], e: [Int16]) {
        self.a = a
        self.b = b
        self.c = c
        self.d = d
        self.e = e
        arr = a + b + c + d + e
    }
}

// MARK: - Bound5

let b5ArrGen = #gen(.int16(scaling: .linear).array(length: 0 ... 10))
    .filter(.rejectionSampling) { $0.isEmpty || $0.dropFirst().reduce($0[0], &+) < 256 }
let b5Gen = #gen(b5ArrGen, b5ArrGen, b5ArrGen, b5ArrGen, b5ArrGen) { a, b, c, d, e in
    Bound5(a: a, b: b, c: c, d: d, e: e)
}

benchmark("Bound5, 100 iterations") {
    let property: (Bound5) -> Bool = { b5 in
        if b5.arr.isEmpty {
            return true
        }
        return b5.arr.dropFirst().reduce(b5.arr[0], &+) < 5 * 256
    }

    do {
        var iterator = ValueAndChoiceTreeInterpreter(b5Gen, seed: 1337, maxRuns: 1000)
        var count = 0
        while let (value, tree) = try iterator.next() {
            guard property(value) == false else { continue }
            count += 1
            _ = try Interpreters.bonsaiReduce(gen: b5Gen, tree: tree, output: value, config: .fast, property: property)
            if count >= 100 {
                break
            }
        }
    } catch {
        print(error)
    }
}

benchmark("Bound5, 100 iterations (adaptive)") {
    let property: (Bound5) -> Bool = { b5 in
        if b5.arr.isEmpty {
            return true
        }
        return b5.arr.dropFirst().reduce(b5.arr[0], &+) < 5 * 256
    }

    do {
        var iterator = ValueAndChoiceTreeInterpreter(b5Gen, seed: 1337, maxRuns: 1000)
        var count = 0
        while let (value, tree) = try iterator.next() {
            guard property(value) == false else { continue }
            count += 1
            _ = try Interpreters.bonsaiReduce(gen: b5Gen, tree: tree, output: value, config: .fast, adaptiveScheduling: true, property: property)
            if count >= 100 {
                break
            }
        }
    } catch {
        print(error)
    }
}

indirect enum Expr: Equatable, CustomDebugStringConvertible, CustomStringConvertible {
    case value(Int)
    case add(Expr, Expr)
    case div(Expr, Expr)

    var value: Int? {
        guard case let .value(value) = self else {
            return nil
        }
        return value
    }

    var debugDescription: String {
        switch self {
        case let .value(value):
            "value(\(value))"
        case let .add(lhs, rhs):
            "add(\(lhs.debugDescription), \(rhs.debugDescription))"
        case let .div(lhs, rhs):
            "div(\(lhs.debugDescription), \(rhs.debugDescription))"
        }
    }

    var description: String {
        debugDescription
    }
}

enum EvalError: Error {
    case divisionByZero
}

func eval(_ expr: Expr) throws -> Int {
    switch expr {
    case let .value(value):
        return value
    case let .add(lhs, rhs):
        return try eval(lhs) + eval(rhs)
    case let .div(lhs, rhs):
        let denominator = try eval(rhs)
        guard denominator != 0 else {
            throw EvalError.divisionByZero
        }
        return try eval(lhs) / denominator
    }
}

func containsLiteralDivisionByZero(_ expr: Expr) -> Bool {
    switch expr {
    case .value:
        false
    case let .add(lhs, rhs):
        containsLiteralDivisionByZero(lhs) || containsLiteralDivisionByZero(rhs)
    case .div(_, .value(0)):
        true
    case let .div(lhs, rhs):
        containsLiteralDivisionByZero(lhs) || containsLiteralDivisionByZero(rhs)
    }
}

func expression(depth: UInt64) -> ReflectiveGenerator<Expr> {
    let leaf = #gen(.int(in: -10 ... 10))
        .mapped(forward: { Expr.value($0) }, backward: { $0.value ?? 0 })

    guard depth > 0 else {
        return leaf
    }

    let child = expression(depth: depth - 1)

    let add = #gen(child, leaf)
        .mapped(
            forward: { lhs, rhs in Expr.add(lhs, rhs) },
            backward: { value in
                switch value {
                case let .add(lhs, rhs): (lhs, rhs)
                case let .div(lhs, rhs): (lhs, rhs)
                case .value:
                    (value, value)
                }
            }
        )
    let div = #gen(leaf, child)
        .mapped(
            forward: { lhs, rhs in Expr.div(lhs, rhs) },
            backward: { value in
                switch value {
                case let .add(lhs, rhs): (lhs, rhs)
                case let .div(lhs, rhs): (lhs, rhs)
                case .value:
                    (value, value)
                }
            }
        )

    return #gen(.oneOf(weighted:
        (3, leaf),
        (3, add),
        (3, div)))
}

let calculatorGen = #gen(expression(depth: 4))

benchmark("Calculator, 100 iterations") {
    let property: (Expr) -> Bool = { expr in
        guard containsLiteralDivisionByZero(expr) == false else {
            return true
        }
        do {
            _ = try eval(expr)
            return true
        } catch EvalError.divisionByZero {
            return false
        } catch {
            return false
        }
    }

    do {
        var iterator = ValueAndChoiceTreeInterpreter(calculatorGen, seed: 1337, maxRuns: 1000)
        var count = 0
        while let (value, tree) = try iterator.next() {
            guard property(value) == false else { continue }
            count += 1
            _ = try Interpreters.bonsaiReduce(gen: calculatorGen, tree: tree, output: value, config: .fast, property: property)
            if count >= 100 {
                break
            }
        }
    } catch {
        print(error)
    }
}

benchmark("Calculator, 100 iterations (adaptive)") {
    let property: (Expr) -> Bool = { expr in
        guard containsLiteralDivisionByZero(expr) == false else {
            return true
        }
        do {
            _ = try eval(expr)
            return true
        } catch EvalError.divisionByZero {
            return false
        } catch {
            return false
        }
    }

    do {
        var iterator = ValueAndChoiceTreeInterpreter(calculatorGen, seed: 1337, maxRuns: 1000)
        var count = 0
        while let (value, tree) = try iterator.next() {
            guard property(value) == false else { continue }
            count += 1
            _ = try Interpreters.bonsaiReduce(gen: calculatorGen, tree: tree, output: value, config: .fast, adaptiveScheduling: true, property: property)
            if count >= 100 {
                break
            }
        }
    } catch {
        print(error)
    }
}

// benchmark("ScalarRangeSet.scalar(at:)") {
//    let chars = CharacterSet.illegalCharacters.inverted.subtracting(.controlCharacters)
//    let srs = chars.scalarRangeSet()
//    var f: Unicode.Scalar?
//    for n in 1 ... 10000 {
//        f = srs.scalar(at: n)
//    }
//    precondition(f != nil)
// }
//
// benchmark("ScalarRangeSet.index(of:)") {
//    let chars = CharacterSet.illegalCharacters.inverted.subtracting(.controlCharacters)
//    let srs = chars.scalarRangeSet()
//    let count = min(srs.scalarCount, 10000)
//    let scalars = (0 ..< count).map { srs.scalar(at: $0) }
//    var result = 0
//    for scalar in scalars {
//        result = srs.index(of: scalar)
//    }
//    precondition(result >= 0)
// }

Benchmark.main()

// struct ExhaustBenchmarks {
//    static let benchmarks =
//
//    Benchmark("String Generation") { benchmark in
//        let generator = Gen.arrayOf(Character.arbitrary)
//            .map { String($0) }
//        var prng = Xoshiro256(seed: 42)
//
//        for _ in benchmark.scaledIterations {
//            _ = try! GeneratorIterator.generate(
//                generator,
//                initialSize: 20,
//                maxRuns: 1,
//                using: &prng
//            )
//        }
//    }
//
//    Benchmark("Array Generation") { benchmark in
//        let intGenerator = Gen.choose(in: 0...100, input: Any.self)
//        let generator = Gen.arrayOf(intGenerator, exactly: 10)
//        var prng = Xoshiro256(seed: 42)
//
//        for _ in benchmark.scaledIterations {
//            _ = try! GeneratorIterator.generate(
//                generator,
//                initialSize: 10,
//                maxRuns: 1,
//                using: &prng
//            )
//        }
//    }
//
//    Benchmark("Choice Generation") { benchmark in
//        let generator = Gen.pick(choices: [
//            (weight: 1, generator: Gen.exact("option1")),
//            (weight: 2, generator: Gen.exact("option2")),
//            (weight: 1, generator: Gen.exact("option3"))
//        ])
//        var prng = Xoshiro256(seed: 42)
//
//        for _ in benchmark.scaledIterations {
//            _ = try! GeneratorIterator.generate(
//                generator,
//                initialSize: 10,
//                maxRuns: 1,
//                using: &prng
//            )
//        }
//    }
//
//    Benchmark("Int Reflection") { benchmark in
//        let generator = Gen.choose(in: 0...100, input: Any.self)
//        let values = Array(0..<100)
//
//        for _ in benchmark.scaledIterations {
//            for value in values {
//                _ = try! Interpreters.reflect(generator, with: value)
//            }
//        }
//    }
//
//    Benchmark("String Reflection") { benchmark in
//        let generator = Gen.arrayOf(Character.arbitrary)
//            .map { String($0) }
//        let strings = (0..<20).map { "test_\($0)" }
//
//        for _ in benchmark.scaledIterations {
//            for string in strings {
//                _ = try! Interpreters.reflect(generator, with: string)
//            }
//        }
//    }
//
//    Benchmark("Generation-Reflection-Replay Cycle") { benchmark in
//        let generator = Gen.choose(in: 0...1000, input: Any.self)
//        var prng = Xoshiro256(seed: 42)
//
//        for _ in benchmark.scaledIterations {
//            // Generate
//            let value = try! GeneratorIterator.generate(
//                generator,
//                initialSize: 50,
//                maxRuns: 1,
//                using: &prng
//            )
//
//            // Reflect
//            guard let choiceTree = try! Interpreters.reflect(generator, with: value) else { continue }
//
//            // Replay
//            _ = try! Interpreters.replay(generator, using: choiceTree)
//        }
//    }
//
//    Benchmark("Complex Generator Composition") { benchmark in
//        let intGenerator = Gen.choose(in: 0...100, input: Any.self)
//        let stringGenerator = Gen.arrayOf(Character.arbitrary, exactly: 5)
//            .map { String($0) }
//        let boolGenerator = Gen.pick(choices: [
//            (weight: 1, generator: Gen.exact(true)),
//            (weight: 1, generator: Gen.exact(false))
//        ])
//
//        let generator = Gen.pick(choices: [
//            (weight: 1, generator: intGenerator.map { "int: \($0)" }),
//            (weight: 1, generator: stringGenerator.map { "string: \($0)" }),
//            (weight: 1, generator: boolGenerator.map { "bool: \($0)" })
//        ])
//        var prng = Xoshiro256(seed: 42)
//
//        for _ in benchmark.scaledIterations {
//            _ = try! GeneratorIterator.generate(
//                generator,
//                initialSize: 20,
//                maxRuns: 1,
//                using: &prng
//            )
//        }
//    }
// }

// swiftlint:enable force_try
