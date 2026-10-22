import Testing
@testable import ExhaustCore

@Suite("Compact choice paths")
struct ChoicePathTests {
    @Test("Paths preserve every step across packing and expansion boundaries", arguments: [0, 1, 7, 8, 9, 32], [false, true])
    func roundTrips(length: Int, largeIndices: Bool) {
        let alphabet: [ChoicePathStep] = largeIndices
            ? [.bindInner, .bindBound, .sequenceChild(-1), .sequenceChild(64), .sequenceChild(.max), .groupChild(.min), .groupChild(64), .pickBranch(64), .pickBranch(.max)]
            : [.bindInner, .bindBound, .sequenceChild(0), .sequenceChild(63), .groupChild(0), .groupChild(63), .pickBranch(0), .pickBranch(63)]
        for rotation in alphabet.indices {
            let steps = (0 ..< length).map { alphabet[($0 + rotation) % alphabet.count] }
            let path = ChoicePath(steps)
            #expect(Array(path) == steps)
            #expect(path.count == steps.count)
            #expect(Array(path.reversed()) == Array(steps.reversed()))
            var appended: ChoicePath = []
            for step in steps {
                let parent = appended
                appended = parent.appending(step)
                #expect(Array(appended.dropLast()) == Array(parent))
            }
            #expect(appended == path)
            #expect(Set([path, appended]).count == 1)
            for split in 0 ... length {
                let prefix = ChoicePath(path.prefix(split))
                let suffix = ChoicePath(path.dropFirst(split))
                #expect(prefix == ChoicePath(steps.prefix(split)))
                #expect(suffix == ChoicePath(steps.dropFirst(split)))
            }
        }
    }

    @Test("Indexed kinds and bind directions remain distinct at all compact indices")
    func distinctCoordinates() {
        var paths: Set<ChoicePath> = [[.bindInner], [.bindBound]]
        for index in 0 ..< 64 {
            paths.insert([.sequenceChild(index)])
            paths.insert([.groupChild(index)])
            paths.insert([.pickBranch(UInt64(index))])
        }
        #expect(paths.count == 194)
        #expect(paths.contains([]) == false)
        #expect(paths.contains([.sequenceChild(64)]) == false)
        #expect(paths.contains([.groupChild(-1)]) == false)
        #expect(paths.contains([.pickBranch(.max)]) == false)
    }
}
