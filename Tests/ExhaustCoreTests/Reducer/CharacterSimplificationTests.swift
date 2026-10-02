import Foundation
import Testing
@testable import ExhaustCore

@Suite("Character simplification")
struct CharacterSimplificationTests {
    @Test("A lowercase letter's only simpler form is its uppercase letter", arguments: Array("creepidiot"))
    func lowercaseSimplifiesToUppercase(character: Character) {
        let scalars = UnicodeVersion.v17.scalarRangeSet

        #expect(simplerForms(of: character, in: scalars) == [Character(character.uppercased())])
    }

    @Test("An accented letter reaches its unaccented uppercase form in one step, simplest first")
    func accentedLetterReachesBaseUppercase() {
        let scalars = UnicodeVersion.v17.scalarRangeSet

        #expect(simplerForms(of: "å", in: scalars) == ["A", "a", "Å"])
        #expect(simplerForms(of: "á", in: scalars) == ["A", "a", "Á"])
        #expect(simplerForms(of: "ß", in: scalars) == ["S", "s"])
    }

    @Test(
        "Greek, Cyrillic, Latin Extended Additional, ligatures, fullwidth, and math alphanumerics reach their simpler forms",
        arguments: [
            ("б", ["Б"]),
            ("ἀ", ["Α", "α"]),
            ("ạ", ["A", "a", "Ạ"]),
            ("ﬁ", ["F", "I", "f", "i"]),
            ("！", ["!"]),
            ("𝐀", ["A", "a"]),
        ] as [(Character, [Character])]
    )
    func widenedBlocksSimplify(source: Character, expected: [Character]) {
        let scalars = UnicodeVersion.v17.scalarRangeSet

        #expect(simplerForms(of: source, in: scalars) == expected)
    }

    @Test("No simplification proposes a bare combining mark")
    func noCandidateIsACombiningMark() {
        let scalars = UnicodeVersion.v17.scalarRangeSet

        for index in 0 ..< scalars.scalarCount {
            let candidates = scalars.simplifications.simplerIndices(than: UInt64(index))
            for candidate in candidates {
                #expect(isCombiningMark(scalars.scalar(at: Int(candidate))) == false)
            }
        }
    }

    @Test("A character with no lower-indexed form has no simplifications")
    func uppercaseHasNoSimplifications() {
        let scalars = UnicodeVersion.v17.scalarRangeSet

        #expect(simplerForms(of: "A", in: scalars).isEmpty)
    }

    @Test("Forms outside the generator's character set are never proposed")
    func formsOutsideTheSetAreExcluded() {
        let scalars = CharacterSet(charactersIn: "a" ... "z").scalarRangeSet(bottomCodepoint: nil)

        #expect(simplerForms(of: "c", in: scalars).isEmpty)
    }

    @Test("Reduction uppercases characters whose case the property ignores")
    func reductionUppercasesCaseInsensitiveText() throws {
        let generator = Gen.string().gen
        let tree = try #require(try Interpreters.reflect(generator, with: "creepidiot"))

        let (_, reduced) = try #require(
            try Interpreters.choiceGraphReduce(
                gen: generator,
                tree: tree,
                output: "creepidiot",
                config: Interpreters.ReducerConfiguration(maxStalls: 2)
            ) { text in
                let lowered = text.lowercased()
                return (lowered.contains("creep") && lowered.contains("idiot")) == false
            }.counterexample
        )

        #expect(reduced == "CREEPIDIOT")
    }

    @Test("Reduction strips accents when the property ignores them")
    func reductionStripsAccents() throws {
        let generator = Gen.string().gen
        let tree = try #require(try Interpreters.reflect(generator, with: "å"))

        let (_, reduced) = try #require(
            try Interpreters.choiceGraphReduce(
                gen: generator,
                tree: tree,
                output: "å",
                config: Interpreters.ReducerConfiguration(maxStalls: 2)
            ) { text in
                text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) != "a"
            }.counterexample
        )

        #expect(reduced == "A")
    }

    @Test("Reduction removes every Zalgo mark and leaves no letter with a simpler case")
    func reductionRemovesZalgoMarks() throws {
        let zalgo = "ZA̡͊͠͝LGΌ ISͮ̂҉̯͈͕̹̘̱ TO͇̹̺ͅƝ̴ȳ̳ TH̘Ë͖́̉ ͠P̯͍̭O̚N̐Y̡ H̸̡̪̯ͨ͊̽̅̾̎Ȩ̬̩̾͛ͪ̈́̀́͘ ̶̧̨̱̹̭̯ͧ̾ͬC̷̙̲̝͖ͭ̏ͥͮ͟Oͮ͏̮̪̝͍M̲̖͊̒ͪͩͬ̚̚͜Ȇ̴̟̟͙̞ͩ͌͝S̨̥̫͎̭ͯ̿̔̀ͅ"
        let stripped = markStripped(zalgo)
        let generator = Gen.string().gen
        let tree = try #require(try Interpreters.reflect(generator, with: zalgo))

        let (_, reduced) = try #require(
            try Interpreters.choiceGraphReduce(
                gen: generator,
                tree: tree,
                output: zalgo,
                config: Interpreters.ReducerConfiguration(maxStalls: 2)
            ) { text in
                markStripped(text) != stripped
            }.counterexample
        )

        #expect(reduced.unicodeScalars.contains(where: isCombiningMark) == false)
        #expect(reduced.allSatisfy { String($0).uppercased() == String($0) })
        // Greek capital omicron with tonos (U+038C) and Latin capital N with left hook (U+019D) have no simpler forms.
        #expect(reduced == "ZALG\u{038C} IS TO\u{019D}Y THE PONY HE COMES")
    }
}

// MARK: - Helpers

private func simplerForms(of character: Character, in scalars: ScalarRangeSet) -> [Character] {
    let scalar = character.unicodeScalars.first!
    let index = UInt64(scalars.index(of: scalar))
    return scalars.simplifications.simplerIndices(than: index).map { Character(scalars.scalar(at: Int($0))) }
}

private func markStripped(_ text: String) -> String {
    text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
}

private func isCombiningMark(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.properties.generalCategory {
        case .nonspacingMark, .spacingMark, .enclosingMark:
            true
        default:
            false
    }
}
