import Testing
@testable import Exhaust

@Test func example() async throws {
    let gen = boolArrayGen()
    let results = Interpreters.generate(gen) ?? []
    #expect(Set(results).count == 2)
}

@Test func example2() async throws {
    let gen = Gen.choose(in: 1...5)
    let results = Interpreters.generate(gen)
    let choices = Interpreters.reflect(gen, with: results!, where: { _ in true })
    #expect(true)
}

@Test func example3() async throws {
    struct Person: Equatable {
        let age: Int
        let height: Double
    }
    let ageGen = Gen.choose(in: 0...150)
    let heightGen = Gen.choose(in: Double(120)...180)
    let keypath = \Person.age
    
    let lensedAge = Gen.lens(into: \Person.age, ageGen)
    let lensedHeight = Gen.lens(into: \Person.height, heightGen)
//    let zipped = Gen.zip(lensedAge, lensedHeight)
//        .map { Person(age: $0, height: $1) }
    let zipped = lensedAge.bind { age in
        lensedHeight.map { height in
            Person(age: age, height: height)
        }
    }    
    let result = Interpreters.generate(zipped)!
//    let result = Person(age: 42, height: 178)
    let choices = Interpreters.reflect(zipped, with: result)
    if let first = choices.first {
        let replayed = Interpreters.replay(zipped, using: first)
        #expect(replayed! == result)
    }
    #expect(true)
}
