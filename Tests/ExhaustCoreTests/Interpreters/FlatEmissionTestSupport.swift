import ExhaustTestSupport
import Testing
@testable import ExhaustCore

/// Generates parents with VACTI, then compares tree-building and flat-emission materialization on the parent's own flattening (exact mode) and on mutated candidates (guided mode).
func assertFlatEmissionMatchesFlatten(
    _ generator: Generator<some Any>,
    runs: UInt64 = 30,
    mutationsPerRun: Int = 8,
    seed: UInt64 = 0xF1A7_E815,
    sourceLocation: SourceLocation = #_sourceLocation
) throws {
    let erased = generator.erase()
    var interpreter = ValueAndChoiceTreeInterpreter(generator, seed: seed, maxRuns: runs)
    var prng = Xoshiro256(seed: seed ^ 0x5EED)

    var checked = 0
    while let (_, tree) = try interpreter.next() {
        let size = GenerationContext.scaledSize(forRun: UInt64(checked))
        checked += 1
        let parentSequence = ChoiceSequence.flatten(tree)
        assertBothPathsAgree(
            erased,
            prefix: parentSequence,
            mode: .exact,
            fallbackTree: tree,
            requireSuccess: true,
            size: size,
            sourceLocation: sourceLocation
        )

        for _ in 0 ..< mutationsPerRun {
            let intensity = MutationIntensity.allCases[Int(prng.next(upperBound: 3))]
            let candidate = FuzzMutator.mutate(parentSequence, intensity: intensity, prng: &prng)
            assertBothPathsAgree(
                erased,
                prefix: candidate,
                mode: .guided(seed: prng.next(), fallbackTree: tree),
                fallbackTree: tree,
                size: size,
                sourceLocation: sourceLocation
            )
        }
    }
    #expect(checked == runs, "No complete sample batch was materialized", sourceLocation: sourceLocation)
}

/// Runs both materialization paths on identical inputs and asserts outcome parity, sequence equality against the fresh tree's flattening, and convergence equality.
private func assertBothPathsAgree(
    _ erased: AnyGenerator,
    prefix: ChoiceSequence,
    mode: Materializer.Mode,
    fallbackTree: ChoiceTree,
    requireSuccess: Bool = false,
    size: UInt64,
    sourceLocation: SourceLocation
) {
    // A raw getSize read is not encoded in the prefix, so both paths need the original ambient size.
    var treeContext = Materializer.Context(prefix: prefix, mode: mode, fallbackTree: fallbackTree)
    treeContext.size = size
    var flatContext = Materializer.Context(prefix: prefix, mode: mode, fallbackTree: fallbackTree)
    flatContext.size = size
    let treeResult = Materializer.materializeAny(erased, context: treeContext)
    let flatResult = Materializer.materializeAnyFlat(erased, context: flatContext)
    switch (treeResult, flatResult) {
        case let (.success(treeValue, freshTree, treeReport), .success(flatValue, flatSequence, flatReport)):
            #expect(StructuralEquality.structurallyEqual(treeValue, flatValue), sourceLocation: sourceLocation)
            let flattened = ChoiceSequence.flatten(freshTree)
            #expect(
                flatSequence == flattened,
                "flat emission \(flatSequence.shortString) diverged from flattened tree \(flattened.shortString) for prefix \(prefix.shortString)",
                sourceLocation: sourceLocation
            )
            #expect(
                treeReport?.convergence == flatReport?.convergence,
                "convergence diverged between paths for prefix \(prefix.shortString)",
                sourceLocation: sourceLocation
            )
        case (.rejected, .rejected), (.failed, .failed):
            #expect(requireSuccess == false, "Both paths rejected the generated input", sourceLocation: sourceLocation)
        default:
            Issue.record(
                "flat emission outcome diverged from tree materialization for prefix \(prefix.shortString)",
                sourceLocation: sourceLocation
            )
    }
}
