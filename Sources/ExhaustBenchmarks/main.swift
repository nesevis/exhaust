import Benchmark
import Exhaust

benchmark("Int Generation") {
    let generator = Gen.choose(in: 0...1000)
    var iterator = GeneratorIterator(generator, seed: 1, maxRuns: 100)
    while let next = iterator.next() {
        let bla = next
        let bla2 = bla
    }
}

benchmark("String generation") {
    let generator = String.arbitrary
    var iterator = GeneratorIterator(generator, seed: 1, maxRuns: 100)
    while let next = iterator.next() {
        let next = next
    }
}


benchmark("String generation with reflection") {
    let generator = String.arbitrary
    var iterator = GeneratorIterator(generator, seed: 1, maxRuns: 100)
    while let next = iterator.next() {
        let reflection = try Interpreters.reflect(generator, with: next)
    }
}

benchmark("String generation with choiceTree") {
    let generator = String.arbitrary
    var iterator = ValueAndChoiceTreeIterator(generator, seed: 1, maxRuns: 100)
    while let (value, tree) = iterator.next() {
        let value = value
        let tree = tree
    }
}

// There's no functional difference here between calling next() repeatedly and creating an array from the prefix

benchmark("String generation with choiceTree materialised") {
    let generator = String.arbitrary
    var iterator = ValueAndChoiceTreeIterator(generator, materializePicks: true, seed: 1, maxRuns: 100)
    while let (value, tree) = iterator.next() {
        let value = value
        let tree = tree
    }
}

fileprivate struct Person {
    let name: String
    let age: UInt8
    let height: Double
}

benchmark("Zipped person") {
    let generator = Gen.zip(String.arbitraryAscii, UInt8.arbitrary, Double.arbitrary)
        .mapped(forward: { Person(name: $0.0, age: $0.1, height: $0.2) }, backward: { ($0.name, $0.age, $0.height) })
    var iterator = GeneratorIterator(generator, seed: 1, maxRuns: 100)
    while let next = iterator.next() {
        let next = next
    }
}

benchmark("Zipped person with reflection") {
    let generator = Gen.zip(String.arbitraryAscii, UInt8.arbitrary, Double.arbitrary)
        .mapped(forward: { Person(name: $0.0, age: $0.1, height: $0.2) }, backward: { ($0.name, $0.age, $0.height) })
    var iterator = GeneratorIterator(generator, seed: 1, maxRuns: 100)
    while let next = iterator.next() {
        let reflection = try Interpreters.reflect(generator, with: next)
    }
}


benchmark("Zipped person with ChoiceTree") {
    let generator = Gen.zip(
        String.arbitraryAscii,
        UInt8.arbitrary,
        Double.arbitrary
    )
    .mapped(forward: { Person(name: $0.0, age: $0.1, height: $0.2) }, backward: { ($0.name, $0.age, $0.height) })
    var iterator = ValueAndChoiceTreeIterator(generator, materializePicks: true, seed: 1, maxRuns: 100)
    while let (value, tree) = iterator.next() {
        let value = value
        let tree = tree
    }
}

Benchmark.main()

//struct ExhaustBenchmarks {
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
//}
