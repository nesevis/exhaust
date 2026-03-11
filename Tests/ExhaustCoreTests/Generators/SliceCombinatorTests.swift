import Testing
import ExhaustCore

@Suite("Gen.slice Combinator")
struct SliceCombinatorTests {
    @Test("Gen.slice generates valid subranges of arrays")
    func sliceGeneratesValidArraySubranges() throws {
        let gen = Gen.slice(of: Gen.arrayOf(Gen.choose(in: Int(0) ... 100)))
        var iterator = ValueInterpreter(gen, seed: 42)

        var generated = 0
        while let subseq = try iterator.next() {
            let slice = Array(subseq)
            // Every element should be in range
            for element in slice {
                #expect(0 ... 100 ~= element)
            }
            generated += 1
        }
        #expect(generated > 0)
    }

    @Test("Gen.slice result is a proper subsequence of the source")
    func sliceIsProperSubsequence() throws {
        // Generate a fixed-length array, then take a slice of it
        let arrayGen = Gen.arrayOf(Gen.choose(in: 0 ... 50) as ReflectiveGenerator<Int>, within: 10 ... 10)
        let gen = arrayGen._bind { array in
            Gen.slice(of: array)._map { sub in
                (array, Array(sub))
            }
        }
        var iterator = ValueInterpreter(gen, seed: 123)

        var checked = 0
        while let (source, sub) = try iterator.next() {
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

    @Test("Gen.slice works via Gen.slice static method")
    func staticSlice() throws {
        let gen = Gen.slice(of: Gen.arrayOf(Gen.choose(in: Int.min ... Int.max, scaling: Int.defaultScaling)))
        var iterator = ValueInterpreter(gen, seed: 7)

        var generated = 0
        while let subseq = try iterator.next() {
            let slice = Array(subseq)
            for element in slice {
                #expect(element is Int)
            }
            generated += 1
        }
        #expect(generated > 0)
    }
}
