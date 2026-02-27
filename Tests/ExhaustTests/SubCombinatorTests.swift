import Testing
@testable import Exhaust
@testable import ExhaustCore

@Suite("Gen.sub Combinator")
struct SubCombinatorTests {
    @Test("Gen.sub generates valid subranges of arrays")
    func subGeneratesValidArraySubranges() {
        let gen = Gen.sub(Gen.arrayOf(Gen.choose(in: 0 ... 100)))
        var iterator = ValueInterpreter(gen, seed: 42)

        var generated = 0
        while let subseq = iterator.next() {
            let slice = Array(subseq)
            // Every element should be in range
            for element in slice {
                #expect(0 ... 100 ~= element)
            }
            generated += 1
        }
        #expect(generated > 0)
    }

    @Test("Gen.sub result is a proper subsequence of the source")
    func subIsProperSubsequence() {
        // Generate a fixed-length array, then take a sub of it
        let arrayGen = Gen.arrayOf(Gen.choose(in: 0 ... 50), exactly: 10)
        let gen = arrayGen.bind { array in
            Gen.subset(of: array).map { sub in
                (array, Array(sub))
            }
        }
        var iterator = ValueInterpreter(gen, seed: 123)

        var checked = 0
        while let (source, sub) = iterator.next() {
            #expect(sub.count <= source.count)
            // The subsequence must appear contiguously in the source
            if !sub.isEmpty {
                let found = source.indices.contains { start in
                    let end = start + sub.count
                    guard end <= source.count else { return false }
                    return Array(source[start ..< end]) == sub
                }
                #expect(found, "Subsequence \(sub) not found contiguously in \(source)")
            }
            checked += 1
        }
        #expect(checked > 0)
    }

    @Test("Public API .sub works via ReflectiveGenerator extension")
    func publicAPISub() {
        let gen: ReflectiveGenerator<ArraySlice<Int>> = .sub(.array(.int()))
        var iterator = ValueInterpreter(gen, seed: 7)

        var generated = 0
        while let subseq = iterator.next() {
            let slice = Array(subseq)
            for element in slice {
                #expect(element is Int)
            }
            generated += 1
        }
        #expect(generated > 0)
    }
}
