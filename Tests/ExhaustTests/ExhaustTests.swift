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
    struct Person {
        let age: Int
        let height: Double
    }
    let ageGen = Gen.choose(in: 0...150)
    let heightGen = Gen.choose(in: Double(120)...180)
    let zipped = Gen.zip(ageGen, heightGen)
    
    let results = Interpreters.generate(zipped)
    let choices = Interpreters.reflect(zipped, with: results!, where: { _ in true })
    #expect(true)
}
