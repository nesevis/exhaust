import Benchmark
import Exhaust
@_spi(ExhaustInternal) import ExhaustCore

// swiftlint:disable force_try

benchmark("Int Generation") {
    let generator = Gen.choose(in: 0 ... 1000)
    var iterator = ValueInterpreter(generator, seed: 1, maxRuns: 100)
    while let next = iterator.next() {
        let bla = next
        let bla2 = bla
    }
}

benchmark("String generation") {
    let generator = #gen(.string())
    var iterator = ValueInterpreter(generator, seed: 1, maxRuns: 100)
    while let next = iterator.next() {
        let next = next
    }
}

benchmark("String generation with reflection") {
    let generator = #gen(.string())
    var iterator = ValueInterpreter(generator, seed: 1, maxRuns: 100)
    while let next = iterator.next() {
        let reflection = try Interpreters.reflect(generator, with: next)
    }
}

benchmark("String generation with choiceTree") {
    let generator = #gen(.string())
    var iterator = ValueAndChoiceTreeInterpreter(generator, seed: 1, maxRuns: 100)
    while let (value, tree) = iterator.next() {
        let value = value
        let tree = tree
    }
}

// There's no functional difference here between calling next() repeatedly and creating an array from the prefix

benchmark("Double generation with choiceTree materialised") {
    let generator = Gen.pick(choices: [
        (UInt64(1), Double.arbitrary),
        (UInt64(2), Double.arbitrary),
        (UInt64(4), Double.arbitrary),
    ])
    var iterator = ValueAndChoiceTreeInterpreter(generator, materializePicks: true, seed: 1, maxRuns: 100)
    while let (value, tree) = iterator.next() {
        let value = value
        let tree = tree
    }
}

benchmark("String generation with choiceTree materialised") {
    let generator = #gen(.string())
    var iterator = ValueAndChoiceTreeInterpreter(generator, materializePicks: true, seed: 1, maxRuns: 100)
    while let (value, tree) = iterator.next() {
//        let value = value
//        let tree = tree
    }
}

private struct Person {
    let name: String
    let age: UInt8
    let height: Double
}

benchmark("Zipped person") {
    let generator = Gen.zip(#gen(.asciiString()), UInt8.arbitrary, Double.arbitrary)
        .mapped(forward: { Person(name: $0.0, age: $0.1, height: $0.2) }, backward: { ($0.name, $0.age, $0.height) })
    var iterator = ValueInterpreter(generator, seed: 1, maxRuns: 100)
    while let next = iterator.next() {
        let next = next
    }
}

benchmark("Zipped person with reflection") {
    let generator = Gen.zip(#gen(.asciiString()), UInt8.arbitrary, Double.arbitrary)
        .mapped(forward: { Person(name: $0.0, age: $0.1, height: $0.2) }, backward: { ($0.name, $0.age, $0.height) })
    var iterator = ValueInterpreter(generator, seed: 1, maxRuns: 100)
    while let next = iterator.next() {
        let reflection = try Interpreters.reflect(generator, with: next)
    }
}

benchmark("Zipped person with ChoiceTree") {
    let generator = Gen.zip(
        #gen(.asciiString()),
        UInt8.arbitrary,
        Double.arbitrary,
    )
    .mapped(forward: { Person(name: $0.0, age: $0.1, height: $0.2) }, backward: { ($0.name, $0.age, $0.height) })
    var iterator = ValueAndChoiceTreeInterpreter(generator, materializePicks: true, seed: 1, maxRuns: 100)
    while let (value, tree) = iterator.next() {
        let value = value
        let tree = tree
    }
}

benchmark("Bound5, pathological 2") {
    struct Bound5: Equatable {
        let a: [Int16]
        let b: [Int16]
        let c: [Int16]
        let d: [Int16]
        let e: [Int16]
    }
    let arr = #gen(.int16().array(length: 0 ... 10))
        .filter(.auto) { $0.isEmpty || $0.dropFirst().reduce($0[0], &+) < 256 }
    let gen = #gen(arr, arr, arr, arr, arr) {
        Bound5(a: $0, b: $1, c: $2, d: $3, e: $4)
    }
    let property: (Bound5) -> Bool = { b5 in
        let arr = b5.a + b5.b + b5.c + b5.d + b5.e
        if arr.isEmpty {
            return true
        }
        return arr.dropFirst().reduce(arr[0], &+) < 5 * 256
    }
    let value = Bound5(
        a: [-10709],
        b: [29251, 31661],
        c: [-18678],
        d: [-2824, 15387, -15932, -23458, -6124, 3327, -21001, 16059, -21211, -27710],
        e: [16775, -32275, 813, 11044]
    )
    
    // Takes about 3.7ms, 20ms in a Swift Testing test. So shrinking is 5 times faster
    if let tree = try? Interpreters.reflect(gen, with: value) {
        _ = try? Interpreters.reduce(gen: gen, tree: tree, config: .fast, property: property)
    }
}

benchmark("Bound5, 50 iterations, reflective") {
    struct Bound5: Equatable {
        let a: [Int16]
        let b: [Int16]
        let c: [Int16]
        let d: [Int16]
        let e: [Int16]
    }
    let arrGen = Gen.arrayOf(Int16.arbitrary, within: 0 ... 10)
        .filter { $0.isEmpty || $0.dropFirst().reduce($0[0], &+) < 256 }

    let property: (Bound5) -> Bool = { b5 in
        let arr = b5.a + b5.b + b5.c + b5.d + b5.e
        if arr.isEmpty {
            return true
        }
        return arr.dropFirst().reduce(arr[0], &+) < 5 * 256
    }

    do {
        let gen = #gen(arrGen, arrGen, arrGen, arrGen, arrGen) { a, b, c, d, e in
            Bound5(a: a, b: b, c: c, d: d, e: e)
        }
        let iterator = ValueAndChoiceTreeInterpreter(gen, seed: 1337, maxRuns: 1000)
        var count = 0
        for (value, tree) in iterator where property(value) == false {
            count += 1
            _ = try Interpreters.reduce(gen: gen, tree: tree, config: .fast, property: property)
            if count >= 50 {
                break
            }
        }
    } catch {
        print(error)
    }
}

benchmark("Bound5, 50 iterations") {
    typealias Bound5 = ([Int16], [Int16], [Int16], [Int16], [Int16])

    let arrGen = Gen.arrayOf(Int16.arbitrary, within: 0 ... 10)
        .filter { $0.isEmpty || $0.dropFirst().reduce($0[0], &+) < 256 }
    let gen = Gen.zip(arrGen, arrGen, arrGen, arrGen, arrGen)

    let property: (Bound5) -> Bool = { arg in
        let (a, b, c, d, e) = arg
        let arr = a + b + c + d + e
        if arr.isEmpty {
            return true
        }
        return arr.dropFirst().reduce(arr[0], &+) < 5 * 256
    }

    let iterator = ValueAndChoiceTreeInterpreter(gen, seed: 1337, maxRuns: 1000)

    do {
        var count = 0
        for (value, tree) in iterator where property(value) == false {
            count += 1
            _ = try Interpreters.reduce(gen: gen, tree: tree, config: .fast, property: property)
            if count >= 50 {
                break
            }
        }
    } catch {
        print(error)
    }
}

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
