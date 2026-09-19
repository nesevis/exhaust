import ExhaustCore
import ExhaustTestSupport
import Testing

@Suite("Depth-control choices")
struct DepthControlTests {
    @Test("Choice comparison ignores depth values only when both choices are depth controls")
    func comparesDepthMarkers() {
        let shallow = choice(1, tag: .depthControl)
        let deep = choice(9, tag: .depthControl)
        #expect(ChoiceTree.compareValues(shallow, deep) == nil)
        #expect(ChoiceTree.compareValues(deep, shallow) == nil)
        #expect(ChoiceTree.compareValues(choice(1), choice(9)) == "value mismatch: 1 vs 9")
        #expect(ChoiceTree.compareValues(shallow, choice(9)) == "value mismatch: 1 vs 9")
        #expect(ChoiceTree.compareValues(choice(1), deep) == "value mismatch: 1 vs 9")
    }

    @Test("Ignoring a bind's depth does not hide changed payload choices")
    func comparesBoundValues() {
        let generated = ChoiceTree.bind(fingerprint: 7, inner: choice(1, tag: .depthControl), bound: choice(4))
        let reflected = ChoiceTree.bind(fingerprint: 7, inner: choice(9, tag: .depthControl), bound: choice(4))
        let incorrect = ChoiceTree.bind(fingerprint: 7, inner: choice(9, tag: .depthControl), bound: choice(5))
        #expect(ChoiceTree.compareValues(generated, reflected) == nil)
        #expect(ChoiceTree.compareValues(generated, incorrect) == "value mismatch: 4 vs 5")
        let ordinary = ChoiceTree.bind(fingerprint: 7, inner: choice(1), bound: choice(4))
        let changed = ChoiceTree.bind(fingerprint: 7, inner: choice(9), bound: choice(4))
        #expect(ChoiceTree.compareValues(ordinary, changed) == "bind inner: value mismatch: 1 vs 9")
    }

    @Test("Depth-control comparison still detects different selected branches")
    func comparesBranches() {
        let generated = ChoiceTree.bind(
            fingerprint: 7,
            inner: choice(1, tag: .depthControl),
            bound: .branch(fingerprint: 8, weight: 1, id: 0, branchCount: 2, choice: .just)
        )
        let reflected = ChoiceTree.bind(
            fingerprint: 7,
            inner: choice(9, tag: .depthControl),
            bound: .branch(fingerprint: 8, weight: 1, id: 1, branchCount: 2, choice: .just)
        )
        #expect(ChoiceTree.compareValues(generated, reflected) == "branch mismatch: id 0 vs 1")
    }

    @Test("Scaled depth choices retain their tag and declared range", arguments: [UInt64(1), 25, 50, 100])
    func scaledDepthMetadata(size: UInt64) throws {
        let generator = Gen.chooseDepth(in: 3 ... 20, scaling: .linear)
        var interpreter = ValueAndChoiceTreeInterpreter(generator, seed: 42, sizeOverride: size)
        let (value, tree) = try #require(try interpreter.next())
        guard case let .choice(depth, metadata) = tree else {
            Issue.record("Expected a depth-control choice, got \(tree)")
            return
        }
        #expect(depth.tag == .depthControl)
        #expect(depth.bitPattern64 == value)
        #expect(metadata.validRange == 3 ... 20)
        let effective = Gen.applyScaling(min: 3, max: 20, tag: .depthControl, scaling: .linear(originBits: nil), size: size)
        #expect(effective.contains(value))
        let reflected = try #require(try Interpreters.reflect(generator, with: UInt64(20)))
        #expect(try Interpreters.replay(generator, using: reflected) == 20)
    }

    @Test("Depth scaling preserves unsigned numeric draws and subsequent randomness", arguments: [UInt64(1), 25, 50, 100])
    func scaledDepthRandomStream(size: UInt64) throws {
        let scalings: [SizeScaling<UInt64>] = [
            .constant, .linear, .exponential,
            .linearFrom(origin: 10), .linearFrom(origin: 99),
            .exponentialFrom(origin: 10), .exponentialFrom(origin: 99),
        ]
        for scaling in scalings {
            let generator = Gen.chooseDepth(in: 3 ... 20, scaling: scaling)
            let reference = Gen.choose(in: UInt64(3) ... 20, scaling: scaling)
            try expectMatchingRandomStream(generator, reference: reference, seed: 42, size: size, draws: 30)
        }
    }

    @Test("The default depth chooser remains unscaled at small sizes")
    func defaultDepthScaling() throws {
        let generator = Gen.chooseDepth(in: 0 ... 20)
        var small = ValueAndChoiceTreeInterpreter(generator, seed: 42, sizeOverride: 1)
        var large = ValueAndChoiceTreeInterpreter(generator, seed: 42, sizeOverride: 100)
        for _ in 0 ..< 30 {
            let first = try #require(try small.next())
            let second = try #require(try large.next())
            #expect(first.0 == second.0)
        }
    }
}

// MARK: - Helpers

private func choice(_ value: UInt64, tag: TypeTag = .uint64) -> ChoiceTree {
    .choice(ChoiceValue(value, tag: tag), ChoiceMetadata(validRange: 0 ... 20))
}
