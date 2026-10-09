import Foundation
import Testing
@testable import ExhaustCore

@Suite("Character simplification")
struct CharacterSimplificationTests {
    @Test("Only UTF-8 width minimums have explicit width simplifications", arguments: [
        (UInt32(0x7F), [UInt32]()),
        (0x80, [0]),
        (0x7FF, []),
        (0x800, [0, 0x80]),
        (0xD7FF, []),
        (0x10000, [0, 0x80, 0x800]),
        (0x1F600, []),
    ] as [(UInt32, [UInt32])])
    func widthCandidates(source: UInt32, expected: [UInt32]) {
        let scalars = UnicodeVersion.v17.scalarRangeSet
        let forms = simplerForms(of: Character(Unicode.Scalar(source)!), in: scalars)
        #expect(forms.map { $0.unicodeScalars.first!.value } == expected)
    }

    @Test("Width candidates respect sparse domains and reserved simplest scalars", arguments: [UInt32?.none, 0, 0x80, 0x800, 0x10000])
    func widthCandidateDomains(bottom: UInt32?) {
        var ranges = ExhaustRangeSet<UInt32>()
        for value: UInt32 in [0x80, 0x100, 0x800, 0x801, 0x10000, 0x10001] {
            ranges.insert(contentsOf: value ..< value + 1)
        }
        let scalars = ScalarRangeSet(ranges, bottomCodepoint: bottom.map { Unicode.Scalar($0)! })
        let source = Unicode.Scalar(0x10000)!
        let indices = scalars.simplifications.simplerIndices(than: UInt64(scalars.index(of: source)))
        let expected: [UInt32] = bottom == 0x10000 ? [] : bottom == 0 ? [0, 0x80, 0x800] : bottom == 0x800 ? [0x800, 0x80] : [0x80, 0x800]
        #expect(indices.map { scalars.scalar(at: Int($0)).value } == expected)
        #expect(indices.allSatisfy { $0 < UInt64(scalars.index(of: source)) })
        if let bottom {
            #expect(scalars.simplifications.simplerIndices(than: UInt64(scalars.index(of: Unicode.Scalar(bottom)!))).isEmpty)
        }
    }

    @Test("Unavailable width boundaries are omitted")
    func missingWidthBoundaries() {
        let scalars = CharacterSet(charactersIn: "\u{10000}" ... "\u{10010}").scalarRangeSet(bottomCodepoint: nil)
        #expect(simplerForms(of: "\u{10000}", in: scalars).isEmpty)
    }

    @Test("Value search reaches narrower width boundaries across a non-monotone gap", arguments: [UInt32(0x80), 0x800])
    func reducesWidth(target: UInt32) throws {
        let initial = Character("\u{10000}")
        let expected = Character(Unicode.Scalar(target)!)
        let generator = Gen.character().gen
        let tree = try #require(try Interpreters.reflect(generator, with: initial))
        let (_, reduced) = try #require(try Interpreters.choiceGraphReduce(
            gen: generator,
            tree: tree,
            output: initial,
            config: .init(maxStalls: 2, enabledEncoders: [.valueSearch])
        ) { $0 != initial && $0 != expected }.counterexample)
        #expect(reduced == expected)
    }

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
