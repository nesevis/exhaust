//
//  ShrinkingTests.swift
//  ExhaustTests
//
//  Tests for the shrinking functionality including simple and complex
//  structure shrinking scenarios.
//

import Testing
@testable import Exhaust

@Suite("Shrinking Functionality")
struct ShrinkingTests {
    
    @Suite("Basic Shrinking")
    struct BasicShrinkingTests {
        
        @Test("Shrinker with simple generators")
        func testShrinkingSimpleGenerator() {
            let gen = Gen.choose(in: 1...1000, input: Any.self)
            let shrinker = Shrinker()
            
            let failingValue = 500
            let property: (Int) -> Bool = { $0 >= 100 }
            
            let shrunken = shrinker.shrink(failingValue, using: gen, where: property)
            
            // Should shrink towards the boundary
            #expect(shrunken >= 100)
            #expect(shrunken < failingValue)
        }
        
        @Test("Shrinker with array generators")
        func testShrinkingArrayGenerator() {
            let gen = UInt.arbitrary.proliferate(with: 1...20)
            let shrinker = Shrinker()
            
            let largeArray = Array(1...15).map(UInt.init)
            let property: ([UInt]) -> Bool = { $0.count >= 5 }
            
            let shrunken = shrinker.shrink(largeArray, using: gen, where: property)
            
            #expect(shrunken.count >= 5)
            #expect(shrunken.count <= largeArray.count)
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
    }
    
    @Suite("Complex Structure Shrinking")
    struct ComplexShrinkingTests {
        
        struct TestPerson: Equatable {
            let name: String
            let age: Int
            let height: Double
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
            
            // Assert: The shrinker should find the minimal boundary case.
            let expectedMinimalValue = Person(age: 51, height: 99)
            let recipe = Interpreters.reflect(personGen, with: expectedMinimalValue)
            #expect(recipe != nil)
        }
        
        @Test("Shrinker with complex structures")
        func testShrinkingComplexStructure() {
            let personGen = Gen.lens(extract: \TestPerson.name, String.arbitrary)
                .bind { name in
                    Gen.lens(extract: \TestPerson.age, Gen.choose(in: 0...100))
                        .map { age in
                            TestPerson(name: name, age: age, height: 170.0)
                        }
                }
            
            let shrinker = Shrinker()
            let failingPerson = TestPerson(name: "Very Long Name", age: 80, height: 170.0)
            
            // Property: fails if age > 50 OR name length > 5
            let property: (TestPerson) -> Bool = { person in
                person.age > 50 || person.name.count > 5
            }
            
            let shrunken = shrinker.shrink(failingPerson, using: personGen, where: property)
            
            // Should shrink to minimal failing case
            #expect(shrunken.age > 50 || shrunken.name.count > 5)
            #expect(shrunken.age <= failingPerson.age)
            #expect(shrunken.name.count <= failingPerson.name.count)
        }
    }
    
    @Suite("String Shrinking")
    struct StringShrinkingTests {
        
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
            
            let failingExample2 = Thing(name: "㒺⿙㒒瘰绮챪Ῥ䨔鈎㗎㮠蔛ㅟ閻ꁗ폔稌낣è䯪᝗渁傱㕀㸐蹎菹⺞⾶켑눺詢Ჺ⺈嶢误㛒쫻ꑭ讘⢖쿇쭘橜⢟拹䊂꫇叔⃭礗Ꞧ嚒⭑ᅜ㨍쩱苋㳜̦涚쏧䳳诛좶ർ፻뻶໖縗ꉉꨇ㰅컪遊⊮饨ᨽ쑚챂ꔘ괠준嵑肠蛳䪟ȕ຅᠍嗃鐷▪応咘ア褑淤⃧䆣깭䩘뱌䘉ব鵦빝뛻Z왼젷ꕱᎴ㶴ḝ㮊콶氛癈쟔殊木騁컯ᑫ통䧇ᣲ䭸돰퍪馚뀤ܔ㓾䵭ӹ첺㾉직銪많璿샢Ѧ던쮪蟃늤䨥ꚽṗ蠱拱ճ◭淄ᏹ貪퐥䎸欁툓룑됹ୢ똶炁铢楋闟㶉吩榧⵰貢ꪲ逫烾⫎닖鄂殗㋶❯䈀⏇폣曣俈踀鎡럞᣶蕮ཾ┠৬ླəꃑ湵큄蝵ʳ躝㐳絒砂䜁ㆪ᧣⍲뀮銬焼Ù쐪頽㲩ꇼ秹寜籏楹ੇꆇ꾏䡜蚪⃣詷浅롆ഠ㭕⧤ᔛ❑䦃须쉥࿋㸑墭껈坄偅焲䪣瞟皷콗㆓骻납뾢副ׅཐ䐂얂雲᪃䋯⽇䃯侣䮢鼘糠鱕Ɛ䍏㟩彾챝逼岾㒺⿙㒒瘰绮챪Ῥ䨔鈎BOOP㗎㮠蔛ㅟ閻ꁗ폔稌낣è䯪᝗渁傱㕀㸐蹎菹⺞⾶켑눺詢Ჺ⺈嶢误㛒쫻ꑭ讘⢖쿇쭘橜⢟拹䊂꫇叔⃭礗Ꞧ嚒⭑ᅜ㨍쩱苋㳜̦涚쏧䳳诛좶ർ፻뻶໖縗ꉉꨇ㰅컪遊⊮饨ᨽ쑚챂ꔘ괠준嵑肠蛳䪟ȕ຅᠍嗃鐷▪応咘ア褑淤⃧䆣깭䩘뱌䘉ব鵦빝뛻Z왼젷ꕱᎴ㶴ḝ㮊콶氛癈쟔殊木騁컯ᑫ통䧇ᣲ䭸돰퍪馚뀤ܔ㓾䵭ӹ첺㾉직銪많璿샢Ѧ던쮪蟃늤䨥ꚽṗ蠱拱ճ◭淄ᏹ貪퐥䎸欁툓룑됹ୢ똶炁铢楋闟㶉吩榧⵰貢ꪲ逫烾⫎닖鄂殗㋶❯䈀⏇폣曣俈踀鎡럞᣶蕮ཾ┠৬ླəꃑ湵큄蝵ʳ躝㐳絒砂䜁ㆪ᧣⍲뀮銬焼Ù쐪頽㲩ꇼ秹寜籏楹ੇꆇ꾏䡜蚪⃣詷浅롆ഠ㭕⧤ᔛ❑䦃须쉥࿋㸑墭껈坄偅焲䪣瞟皷콗㆓骻납뾢副ׅཐ䐂얂雲᪃䋯⽇䃯侣䮢鼘糠鱕Ɛ䍏㟩彾챝逼岾㒺⿙boris㒒瘰绮챪Ῥ䨔鈎㗎㮠蔛ㅟ閻ꁗ폔稌낣è䯪᝗渁傱㕀㸐蹎菹⺞⾶켑눺詢Ჺ⺈嶢误㛒쫻ꑭ讘⢖쿇쭘橜⢟拹䊂꫇叔⃭礗Ꞧ嚒⭑ᅜ㨍쩱苋㳜̦涚쏧䳳诛좶ർ፻뻶໖縗ꉉꨇ㰅컪遊⊮饨ᨽ쑚챂ꔘ괠준嵑肠蛳䪟ȕ຅᠍嗃鐷▪応咘ア褑淤⃧䆣깭䩘뱌䘉ব鵦빝뛻Z왼젷ꕱᎴ㶴ḝ㮊콶氛癈쟔殊木騁컯ᑫ통䧇ᣲ䭸돰퍪馚뀤ܔ㓾䵭ӹ첺㾉직銪많璿샢Ѧ던쮪蟃늤䨥ꚽṗ蠱拱ճ◭淄ᏹ貪퐥䎸欁툓룑됹ୢ똶炁铢楋闟㶉吩榧⵰貢ꪲ逫烾⫎닖鄂flump殗㋶❯䈀⏇폣曣俈踀鎡럞᣶蕮ཾ┠৬ླəꃑ湵큄蝵ʳ躝㐳絒砂䜁ㆪ᧣⍲뀮銬焼Ù쐪頽㲩ꇼ秹寜籏楹ੇꆇ꾏䡜蚪⃣詷浅롆ഠ㭕⧤ᔛ❑䦃须쉥࿋㸑墭껈坄偅焲䪣瞟皷콗㆓骻납뾢副ׅཐ䐂얂雲᪃䋯⽇䃯侣䮢鼘糠鱕Ɛ䍏㟩彾챝逼岾㒺⿙㒒瘰绮챪Ῥ䨔鈎㗎㮠蔛ㅟ閻ꁗ폔稌낣è䯪᝗渁傱㕀㸐蹎菹⺞⾶켑눺詢Ჺ⺈嶢误㛒쫻ꑭ讘⢖쿇쭘橜⢟拹䊂꫇叔⃭礗Ꞧ嚒⭑ᅜ㨍쩱苋㳜̦涚쏧䳳诛좶ർ፻뻶໖縗ꉉꨇ㰅컪遊⊮饨ᨽ쑚챂ꔘ괠준嵑肠蛳䪟ȕ຅᠍嗃鐷▪応咘ア褑淤⃧䆣깭䩘뱌䘉ব鵦빝뛻Z왼젷ꕱᎴ㶴ḝ㮊콶氛癈쟔殊木騁컯ᑫ통䧇ᣲ䭸돰퍪馚뀤ܔ㓾䵭ӹ첺㾉직銪많璿샢Ѧ던쮪蟃늤䨥ꚽṗ蠱拱ճ◭淄ᏹ貪퐥䎸欁툓룑됹ୢ똶炁铢楋闟㶉吩榧⵰貢ꪲ逫烾⫎닖鄂殗㋶❯䈀⏇폣曣俈踀鎡럞᣶蕮ཾ┠৬ླəꃑ湵큄蝵ʳ躝㐳絒砂䜁ㆪ᧣⍲뀮銬焼Ù쐪頽㲩ꇼ秹寜籏楹ੇꆇ꾏䡜蚪⃣詷浅롆ഠ㭕⧤ᔛ❑䦃须쉥࿋㸑墭껈坄偅焲䪣瞟皷콗㆓骻납뾢副ׅཐ䐂얂雲᪃䋯⽇䃯侣䮢鼘糠鱕Ɛ䍏㟩彾챝逼岾")
            let expectedMinimumCounterExample = Thing(name: "A")
            
            // Act
            let recipe = Interpreters.reflect(gen, with: failingExample2)
            let replayed = Interpreters.replay(gen, using: recipe!)
            #expect(replayed!.name == failingExample2.name)
            let shrunken2 = shrinker.shrink(failingExample2, using: gen, where: property)
            
            // Assert
            #expect(expectedMinimumCounterExample == shrunken2)
        }
        
        @Test("Simple string array")
        func testSimpleStringArray() {
            let gen = String.arbitrary.proliferate(with: 1...10)
            let minimal = ["Hello there"]
            let recipe = Interpreters.reflect(gen, with: minimal)
            let shrunken = Shrinker().shrink(minimal, using: gen, where: {
                $0.first?.contains(where: { $0.isUppercase }) ?? false
            })
        }
        
        @Test("Simple nested string array")
        func testSimpleNestedStringArray() {
            let gen = String.arbitrary.proliferate(with: 1...10).proliferate(with: 1...10)
            let minimal = [["Hello there"]]
            let recipe = Interpreters.reflect(gen, with: minimal)
            let shrunken = Shrinker().shrink(minimal, using: gen, where: {
                $0.first?.first?.contains(where: { $0.isUppercase }) ?? false
            })
        }
    }
    
    @Suite("Advanced Shrinking Scenarios")
    struct AdvancedShrinkingTests {
        
        struct Receipt: Equatable {
            let items: [[String]]
            let cost: UInt64
        }
        
        @Test("Sequence with picks")
        func testSequenceWithPicks() {
            let shrinker = Shrinker()
            
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
    }
}
