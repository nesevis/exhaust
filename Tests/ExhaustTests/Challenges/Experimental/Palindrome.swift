import Exhaust
import ExhaustCore
import ExhaustTestSupport
import Foundation
import Testing

@Suite("Experimental Challenge: Palindrome", .tags(.challenge))
struct PalindromeChallenge {
    @Test("Symmetric deletion reduces an odd palindrome by removing both edges")
    func racecarDeletion() throws {
        let generator = Gen.string(from: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz")).gen
        let tree = try #require(try Interpreters.reflect(generator, with: "racecar"))
        let result = Interpreters.choiceGraphReduce(
            gen: generator,
            tree: tree,
            output: "racecar",
            config: .init(maxStalls: 2, enabledEncoders: [.deletion]),
            property: palindromeProperty
        )
        let (_, output) = try #require(result.counterexample)

        #expect(output == "cec")
        #expect(palindromeProperty(output) == false)
    }

    @Test("The full reducer reduces short and long odd palindromes", arguments: ["racecar", palindromePoem])
    func fullReduction(input: String) throws {
        #expect(palindromeProperty(input) == false)
        let generator = Gen.string(from: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz")).gen
        let tree = try #require(try Interpreters.reflect(generator, with: input))
        let result = Interpreters.choiceGraphReduce(
            gen: generator,
            tree: tree,
            output: input,
            config: .init(maxStalls: 2),
            property: palindromeProperty
        )
        let (_, output) = try #require(result.counterexample)

        #expect(output.count == 3)
        #expect(palindromeProperty(output) == false)
    }

    @Test("The string macro reduces an odd palindrome to three characters")
    func stringPalindrome() throws {
        let generator = #gen(.string(from: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz")))
        let property: @Sendable (String) -> Bool = { text in
            guard Set(text).count >= 2, text.count.isMultiple(of: 2) == false else { return true }
            return text.elementsEqual(text.reversed()) == false
        }
        let result = #exhaust(
            generator,
            reflecting: "racecar",
            .suppress(.issueReporting),
            property: property
        )
        let output = try #require(result)

        #expect(output.count == 3)
        #expect(property(output) == false)
    }
}

private func palindromeProperty(_ text: String) -> Bool {
    guard Set(text).count >= 2, text.count.isMultiple(of: 2) == false else { return true }
    return text.elementsEqual(text.reversed()) == false
}

private let palindromePoem = """
Dammit I’m mad.
Evil is a deed as I live.
God, am I reviled? I rise, my bed on a sun, I melt.
To be not one man emanating is sad. I piss.
Alas, it is so late. Who stops to help?
Man, it is hot. I’m in it. I tell.
I am not a devil. I level “Mad Dog”.
Ah, say burning is, as a deified gulp,
In my halo of a mired rum tin.
I erase many men. Oh, to be man, a sin.
Is evil in a clam? In a trap?
No. It is open. On it I was stuck.
Rats peed on hope. Elsewhere dips a web.
Be still if I fill its ebb.
Ew, a spider… eh?
We sleep. Oh no!
Deep, stark cuts saw it in one position.
Part animal, can I live? Sin is a name.
Both, one… my names are in it.
Murder? I’m a fool.
A hymn I plug, deified as a sign in ruby ash,
A Goddam level I lived at.
On mail let it in. I’m it.
Oh, sit in ample hot spots. Oh wet!
A loss it is alas (sip). I’d assign it a name.
Name not one bottle minus an ode by me:
“Sir, I deliver. I’m a dog”
Evil is a deed as I live.
Dammit I’m mad.
""".filter(\.isLetter).lowercased()
