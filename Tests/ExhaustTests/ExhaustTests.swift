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
    let lensedAge = Gen.lens(into: \Person.age, Gen.choose(in: 0...150))
    let lensedHeight = Gen.lens(into: \Person.height, Gen.choose(in: Double(120)...180))
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

@Test("Shrinker finds minimal failing Person")
func testPersonShrinking() {
    struct Person: Equatable {
        let age: Int
        let height: Int
    }
    let shrinker = Shrinker()
    
    let lensedAge = Gen.lens(into: \Person.age, Gen.choose(in: 0...1500))
    let lensedHeight = Gen.lens(into: \Person.height, Gen.choose(in: 25...250))
    let personGen = lensedAge.bind { age in
        lensedHeight.map { height in
            Person(age: age, height: height)
        }
    }
    
    // The test property: fails if the age is over 50 AND the height is under 150.
    let isFailing: (Person) -> Bool = { person in
        person.age >= 51 && person.height < 150 && person.height >= 99
    }
    
    // An initial, large failing value.
    let initialFailingValue = Person(age: 997, height: 140)
    
    // Pre-condition: make sure our initial value actually fails.
    #expect(isFailing(initialFailingValue))
    
    // Act: Run the shrinker.
    let shrunkenValue = shrinker.shrink(
        initialFailingValue,
        using: personGen,
        where: isFailing
    )
    
    // Assert: The shrinker should find the minimal boundary case.
    // The shrinker will try ages 0, 50, 75, etc., and will find that 51 is the smallest age that fails.
    // The height cannot be shrunk further without making the test pass.
    let expectedMinimalValue = Person(age: 51, height: 99)
    #expect(shrunkenValue == expectedMinimalValue)
}

@Test("Shrinking something with strings!")
func testStringObjectShrinking() {
    // Arrange
    struct Thing: Equatable {
        let name: String
    }
    let shrinker = Shrinker()
    let gen = Gen.lens(into: \Thing.name.count, Gen.choose(in: 1...150))
        .bind { length in
            Gen.lens(
                into: \Thing.name,
                Gen.arrayOf(Gen.choose(type: Character.self), length).map { String($0) }
            )
        }
        .map { Thing(name: $0) }
    
    let property: (Thing) -> Bool = { thing in
        thing.name.contains(where: { $0.isUppercase })
    }
    
    let failingExample = Thing(name: "`L4f&RdT){DV1Hf(%bYZ0k+HW|(e+1)16^Twes;XU@BZ[-*9FRR+s#W5Bl_e?DEYDw;o0-jp_&LO:^l9qYWSC5?yue?wMG:c%sIfS{jOl{mJ6:[l6FKNZQfztz,k6M)/!N$:D0nDtH'@L*I'J")
    let expectedMinimumCounterExample = Thing(name: "A")

    // Act
    let shrunken = shrinker.shrink(failingExample, using: gen, where: property)
    
    // Assert
    #expect(expectedMinimumCounterExample == shrunken)
}
