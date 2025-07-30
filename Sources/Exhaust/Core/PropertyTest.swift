//
//  PropertyTest.swift
//  Exhaust
//
//  Created by Chris Kolbu on 30/7/2025.
//

enum PropertyTest {
    static func test<Output>(
        _ gen: ReflectiveGenerator<Any, Output>,
        maxIterations: UInt64 = 100,
        seed: UInt64? = nil,
        property: @escaping (Output) -> Bool
    ) throws {
        var iterations = 0
        var generator = GeneratorIterator(gen, seed: seed, maxRuns: maxIterations)
        var passFails = Dictionary([(true, [ChoiceTree?]()), (false, [ChoiceTree?]())], uniquingKeysWith: { $1 })
        
        while let next = generator.next() {
            iterations += 1
            let passed = property(next)
            let reflection = try Interpreters.reflect(gen, with: next)
            passFails[passed]?.append(reflection)
            if passed == false {
                print("Failed after \(iterations)/\(maxIterations).")
                print("Result: \(next)")
                print("Blueprint:\n\(reflection!)")
                return
            }
        }
        print("Test passed after \(maxIterations) iterations")
    }
}
