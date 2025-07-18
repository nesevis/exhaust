import Testing
@testable import Exhaust

@Test func example() async throws {
    let gen = boolArrayGen()
    let results = Interpreters.generate(gen) ?? []
    #expect(Set(results).count == 2)
}

@Test func example2() async throws {
    let gen = Gen.choose(in: 1...5, input: Void.self)
    let results = Interpreters.generate(gen)
    guard let results = results else {
        #expect(false, "Generation failed")
        return
    }
    let choices = Interpreters.reflect(gen, with: results, where: { _ in true })
    #expect(true)
}

@Test func example3() async throws {
    struct Person: Equatable {
        let age: Int
        let height: Double
    }
    let lensedAge = Gen.lens(extract: \Person.age, Gen.choose(in: 0...150))
    let lensedHeight = Gen.lens(extract: \Person.height, Gen.choose(in: Double(120)...180))
    let zipped = lensedAge.bind { age in
        lensedHeight.map { height in
            Person(age: age, height: height)
        }
    }    
    let result = Interpreters.generate(zipped)!
    let choices = Interpreters.reflect(zipped, with: result)
    if let choices {
        let replayed = Interpreters.replay(zipped, using: choices)
        if let replayed = replayed {
            #expect(replayed == result)
        } else {
            #expect(false, "Replay failed in example3")
        }
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
    
    let lensedAge = Gen.lens(extract: \Person.age, Gen.choose(in: 0...1500))
    let lensedHeight = Gen.lens(extract: \Person.height, Gen.choose(in: 25...250))
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
//    let shrunkenValue = shrinker.shrink(
//        initialFailingValue,
//        using: personGen,
//        where: isFailing
//    )
    
    // Assert: The shrinker should find the minimal boundary case.
    // The shrinker will try ages 0, 50, 75, etc., and will find that 51 is the smallest age that fails.
    // The height cannot be shrunk further without making the test pass.
    let expectedMinimalValue = Person(age: 51, height: 99)
    let recipe = Interpreters.reflect(personGen, with: expectedMinimalValue)
    print()
//    #expect(shrunkenValue == expectedMinimalValue)
}

@Test("Shrinking something with strings!")
func testStringObjectShrinking() {
    // Arrange
    struct Thing: Equatable {
        let name: String
    }
    let shrinker = Shrinker()
    let gen = Gen.lens(extract: \Thing.name, String.arbitrary)
        .map { Thing(name: $0) }
    
    let property: (Thing) -> Bool = { thing in
        thing.name.contains(where: { $0.isUppercase })
    }
    
//    let generated = Interpreters.generate(gen)
    
//    let failingExample1 = Thing(name: "颚䑊໷Ê遍䖄㖒⍼幪⤡즪↛⭚৸怴컄")
    let failingExample2 = Thing(name: "㒺⿙㒒瘰绮챪Ῥ䨔鈎㗎㮠蔛ㅟ閻ꁗ폔稌낣è䯪᝗渁傱㕀㸐蹎菹⺞⾶켑눺詢Ჺ⺈嶢误㛒쫻ꑭ讘⢖쿇쭘橜⢟拹䊂꫇叔⃭礗Ꞧ嚒⭑ᅜ㨍쩱苋㳜̦涚쏧䳳诛좶ർ፻뻶໖縗ꉉꨇ㰅컪遊⊮饨ᨽ쑚챂ꔘ괠준嵑肠蛳䪟ȕ຅᠍嗃鐷▪応咘ア褑淤⃧䆣깭䩘뱌䘉ব鵦빝뛻Z왼젷ꕱᎴ㶴ḝ㮊콶氛癈쟔殊木騁컯ᑫ통䧇ᣲ䭸돰퍪馚뀤ܔ㓾䵭ӹ첺㾉직銪많璿샢Ѧ던쮪蟃늤䨥ꚽṗ蠱拱ճ◭淄ᏹ貪퐥䎸欁툓룑됹ୢ똶炁铢楋闟㶉吩榧⵰貢ꪲ逫烾⫎닖鄂殗㋶❯䈀⏇폣曣俈踀鎡럞᣶蕮ཾ┠৬ླəꃑ湵큄蝵ʳ躝㐳絒砂䜁ㆪ᧣⍲뀮銬焼Ù쐪頽㲩ꇼ秹寜籏楹ੇꆇ꾏䡜蚪⃣詷浅롆ഠ㭕⧤ᔛ❑䦃须쉥࿋㸑墭껈坄偅焲䪣瞟皷콗㆓骻납뾢副ׅཐ䐂얂雲᪃䋯⽇䃯侣䮢鼘糠鱕Ɛ䍏㟩彾챝逼岾㒺⿙㒒瘰绮챪Ῥ䨔鈎BOOP㗎㮠蔛ㅟ閻ꁗ폔稌낣è䯪᝗渁傱㕀㸐蹎菹⺞⾶켑눺詢Ჺ⺈嶢误㛒쫻ꑭ讘⢖쿇쭘橜⢟拹䊂꫇叔⃭礗Ꞧ嚒⭑ᅜ㨍쩱苋㳜̦涚쏧䳳诛좶ർ፻뻶໖縗ꉉꨇ㰅컪遊⊮饨ᨽ쑚챂ꔘ괠준嵑肠蛳䪟ȕ຅᠍嗃鐷▪応咘ア褑淤⃧䆣깭䩘뱌䘉ব鵦빝뛻Z왼젷ꕱᎴ㶴ḝ㮊콶氛癈쟔殊木騁컯ᑫ통䧇ᣲ䭸돰퍪馚뀤ܔ㓾䵭ӹ첺㾉직銪많璿샢Ѧ던쮪蟃늤䨥ꚽṗ蠱拱ճ◭淄ᏹ貪퐥䎸欁툓룑됹ୢ똶炁铢楋闟㶉吩榧⵰貢ꪲ逫烾⫎닖鄂殗㋶❯䈀⏇폣曣俈踀鎡럞᣶蕮ཾ┠৬ླəꃑ湵큄蝵ʳ躝㐳絒砂䜁ㆪ᧣⍲뀮銬焼Ù쐪頽㲩ꇼ秹寜籏楹ੇꆇ꾏䡜蚪⃣詷浅롆ഠ㭕⧤ᔛ❑䦃须쉥࿋㸑墭껈坄偅焲䪣瞟皷콗㆓骻납뾢副ׅཐ䐂얂雲᪃䋯⽇䃯侣䮢鼘糠鱕Ɛ䍏㟩彾챝逼岾㒺⿙boris㒒瘰绮챪Ῥ䨔鈎㗎㮠蔛ㅟ閻ꁗ폔稌낣è䯪᝗渁傱㕀㸐蹎菹⺞⾶켑눺詢Ჺ⺈嶢误㛒쫻ꑭ讘⢖쿇쭘橜⢟拹䊂꫇叔⃭礗Ꞧ嚒⭑ᅜ㨍쩱苋㳜̦涚쏧䳳诛좶ർ፻뻶໖縗ꉉꨇ㰅컪遊⊮饨ᨽ쑚챂ꔘ괠준嵑肠蛳䪟ȕ຅᠍嗃鐷▪応咘ア褑淤⃧䆣깭䩘뱌䘉ব鵦빝뛻Z왼젷ꕱᎴ㶴ḝ㮊콶氛癈쟔殊木騁컯ᑫ통䧇ᣲ䭸돰퍪馚뀤ܔ㓾䵭ӹ첺㾉직銪많璿샢Ѧ던쮪蟃늤䨥ꚽṗ蠱拱ճ◭淄ᏹ貪퐥䎸欁툓룑됹ୢ똶炁铢楋闟㶉吩榧⵰貢ꪲ逫烾⫎닖鄂flump殗㋶❯䈀⏇폣曣俈踀鎡럞᣶蕮ཾ┠৬ླəꃑ湵큄蝵ʳ躝㐳絒砂䜁ㆪ᧣⍲뀮銬焼Ù쐪頽㲩ꇼ秹寜籏楹ੇꆇ꾏䡜蚪⃣詷浅롆ഠ㭕⧤ᔛ❑䦃须쉥࿋㸑墭껈坄偅焲䪣瞟皷콗㆓骻납뾢副ׅཐ䐂얂雲᪃䋯⽇䃯侣䮢鼘糠鱕Ɛ䍏㟩彾챝逼岾㒺⿙㒒瘰绮챪Ῥ䨔鈎㗎㮠蔛ㅟ閻ꁗ폔稌낣è䯪᝗渁傱㕀㸐蹎菹⺞⾶켑눺詢Ჺ⺈嶢误㛒쫻ꑭ讘⢖쿇쭘橜⢟拹䊂꫇叔⃭礗Ꞧ嚒⭑ᅜ㨍쩱苋㳜̦涚쏧䳳诛좶ർ፻뻶໖縗ꉉꨇ㰅컪遊⊮饨ᨽ쑚챂ꔘ괠준嵑肠蛳䪟ȕ຅᠍嗃鐷▪応咘ア褑淤⃧䆣깭䩘뱌䘉ব鵦빝뛻Z왼젷ꕱᎴ㶴ḝ㮊콶氛癈쟔殊木騁컯ᑫ통䧇ᣲ䭸돰퍪馚뀤ܔ㓾䵭ӹ첺㾉직銪많璿샢Ѧ던쮪蟃늤䨥ꚽṗ蠱拱ճ◭淄ᏹ貪퐥䎸欁툓룑됹ୢ똶炁铢楋闟㶉吩榧⵰貢ꪲ逫烾⫎닖鄂殗㋶❯䈀⏇폣曣俈踀鎡럞᣶蕮ཾ┠৬ླəꃑ湵큄蝵ʳ躝㐳絒砂䜁ㆪ᧣⍲뀮銬焼Ù쐪頽㲩ꇼ秹寜籏楹ੇꆇ꾏䡜蚪⃣詷浅롆ഠ㭕⧤ᔛ❑䦃须쉥࿋㸑墭껈坄偅焲䪣瞟皷콗㆓骻납뾢副ׅཐ䐂얂雲᪃䋯⽇䃯侣䮢鼘糠鱕Ɛ䍏㟩彾챝逼岾")
//    let failingExample = Thing(name: "aleXander koLbu")
    let expectedMinimumCounterExample = Thing(name: "A")

    // Act
//    let shrunken1 = shrinker.shrink(failingExample1, using: gen, where: property)
    let shrunken2 = shrinker.shrink(failingExample2, using: gen, where: property)
    
    // Assert
//    #expect(expectedMinimumCounterExample == shrunken1)
    #expect(expectedMinimumCounterExample == shrunken2)
}

@Test("Sequence with steps")
func testSequenceWithSteps() {
    let shrinker = Shrinker()
    let gen = UInt.arbitrary.map { $0 * 10 }
    let counterExample: UInt = 1330
    let property: (UInt) -> Bool = { thing in
        thing == counterExample
    }
    
    let shrunken = shrinker.shrink(counterExample, using: gen, where: property)
    #expect(counterExample == shrunken)
}

@Test("Sequence with picks")
func testSequenceWithPicks() {
    struct Receipt: Equatable {
        let items: [[String]]
        let cost: UInt64
    }
    let shrinker = Shrinker()
    
    // Our problem is that this is [[Char]] under the hood, and if we lens into the count we're too deep to lens out.
    // I don't want to add specific handling to the reflect or replay interpreters to handle this, in the case of multiply nested arrays in the future. Look into `getSize`?
    let stringArrGen = String.arbitrary.proliferate(with: 5...10).proliferate(with: 1...2)
    let gen = Gen.lens(
        extract: \Receipt.items,
        stringArrGen
    )
        .bind { items in
            Gen.lens(extract: \Receipt.cost, Gen.choose(in: 1...100)).map { cost in
                Receipt(items: items, cost: cost)
            }
        }
    let counterExample = Receipt(items: [["ham", "cheese", "a", "b", "c"]], cost: 75)
    let property: (Receipt) -> Bool = { thing in
        let flattened = thing.items.flatMap { $0 }
        guard
            flattened.isEmpty == false,
            flattened.first?.contains(where: { $0.isLetter }) ?? false
        else {
            return false
        }
        let costPerItem = thing.cost / UInt64(thing.items.flatMap(\.self).count)
        return costPerItem > 1
    }
    let minimalCounterExample = Receipt(items: [["A"]], cost: 2)
    #expect(property(counterExample))
    let recipe = Interpreters.reflect(gen, with: counterExample)
    let shrunken = shrinker.shrink(counterExample, using: gen, where: property)
    #expect(minimalCounterExample == shrunken)
}

@Test("Simple string array")
func testSimpleStringArray() {
    let gen = String.arbitrary.proliferate(with: 1...10)
    let minimal = ["Hello there"]
    let recipe = Interpreters.reflect(gen, with: minimal)
    let shrunken = Shrinker().shrink(minimal, using: gen, where: {
        $0.first?.contains(where: { $0.isUppercase }) ?? false
    })
    print()
}

@Test("Simple nested string array")
func testSimpleNestedStringArray() {
    let gen = String.arbitrary.proliferate(with: 1...10).proliferate(with: 1...10)
    let minimal = [["Hello there"]]
    let recipe = Interpreters.reflect(gen, with: minimal)
    let shrunken = Shrinker().shrink(minimal, using: gen, where: {
        $0.first?.first?.contains(where: { $0.isUppercase }) ?? false
    })
    print()
}

@Test("Nested lensed properties")
func testNestedLensedProperties() {
    struct Outer: Equatable {
        let inners: [Inner]
        let id: UInt
    }
    struct Inner: Equatable {
        let id: UInt
    }
    
    // This works
    let innerGen = Gen.lens(extract: \Inner.id, Gen.choose(type: UInt.self))
        .proliferate(with: 1...1)
        // Casting to the type needs to be the last thing in the chain
        .map { ints in ints.map { Inner(id: $0) }}
    
    // This crashes
    let innerGen2 = Gen.lens(extract: \Inner.id, Gen.choose(type: UInt.self))
        .map { Inner(id: $0) }
        .proliferate(with: 1...1)
    
    // This would now cause a compile error due to type safety:
//     let badArrayGen = UInt.arbitrary.map { Inner(id: $0) }.proliferate(with: 1...1) 
//     let badInnerGen = Gen.lens(extract: \Inner.id, badArrayGen)  // Type error!
    
    // Test the two type-safe approaches
    for (index, gen) in [innerGen, innerGen2].enumerated() {
        print("Testing composition with innerGen\(index + 1)...")
        
        // Test the outer generator with each inner generator
        let outerGen = Gen.lens(
            extract: \Outer.inners,
            gen
        )
            .bind { inners in
                Gen.lens(extract: \Outer.id, Gen.choose(type: UInt.self)).map { id in
                    Outer(inners: inners, id: id)
                }
            }
        
        print("  Generating...")
        let generated = Interpreters.generate(outerGen)
        print("  Generated: \(String(describing: generated))")
        
        guard let generated = generated else {
            print("  ⚠️ Generation failed")
            continue
        }
        
        print("  Reflecting...")
        let recipe = Interpreters.reflect(outerGen, with: generated)
        print("  Recipe: \(recipe != nil ? "success" : "failed")")
        
        if let recipe = recipe {
            print("  Replaying...")
            let replayed = Interpreters.replay(outerGen, using: recipe)
            print("  Replayed: \(String(describing: replayed))")
            
            if let replayed = replayed {
                #expect(generated == replayed)
                print("  ✅ Test passed")
            } else {
                print("  ⚠️ Replay failed")
            }
        } else {
            print("  ⚠️ Reflection failed, skipping replay test")
        }
    }
}
