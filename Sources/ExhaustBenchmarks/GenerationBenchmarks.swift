import Benchmark
import Exhaust

func registerGenerationBenchmarks() {
    benchmark("Gen: Bound5") {
        _ = #exhaust(
            bound5Gen,
            .suppress(.issueReporting),
            .budget(.extensive),
            .replay(1337)
        ) { _ in true }
    }

    benchmark("Gen: BinaryHeap (bind)") {
        _ = #exhaust(
            #gen(.uint64(in: 0 ... 20)).bind { binaryHeapGen(depth: $0) }.unique(),
            .suppress(.issueReporting),
            .budget(.extensive),
            .replay(1337)
        ) { _ in true }
    }

    benchmark("Gen: BinaryHeap (recursive)") {
        _ = #exhaust(
            binaryHeapGenRecursive(),
            .suppress(.issueReporting),
            .budget(.extensive),
            .replay(1337)
        ) { _ in true }
    }

    benchmark("Gen: Calculator") {
        _ = #exhaust(
            calculatorExpressionGen(depth: 5),
            .suppress(.issueReporting),
            .budget(.extensive),
            .replay(1337)
        ) { _ in true }
    }

    benchmark("Gen: Coupling") {
        _ = #exhaust(
            couplingGen,
            .suppress(.issueReporting),
            .budget(.extensive),
            .replay(1337)
        ) { _ in true }
    }

    benchmark("Gen: Deletion") {
        _ = #exhaust(
            deletionGen,
            .suppress(.issueReporting),
            .budget(.extensive),
            .replay(1337)
        ) { _ in true }
    }

    benchmark("Gen: Difference") {
        _ = #exhaust(
            differenceMustNotBeZeroGen,
            .suppress(.issueReporting),
            .budget(.extensive),
            .replay(1337)
        ) { _ in true }
    }

    benchmark("Gen: Distinct") {
        _ = #exhaust(
            distinctGen,
            .suppress(.issueReporting),
            .budget(.extensive),
            .replay(1337)
        ) { _ in true }
    }

    benchmark("Gen: LargeUnionList") {
        _ = #exhaust(
            largeUnionListGen,
            .suppress(.issueReporting),
            .budget(.extensive),
            .replay(1337)
        ) { _ in true }
    }

    benchmark("Gen: LengthList") {
        _ = #exhaust(
            lengthListGen,
            .suppress(.issueReporting),
            .budget(.extensive),
            .replay(1337)
        ) { _ in true }
    }

    benchmark("Gen: NestedLists") {
        _ = #exhaust(
            nestedListsGen,
            .suppress(.issueReporting),
            .budget(.extensive),
            .replay(1337)
        ) { _ in true }
    }

    benchmark("Gen: Reverse") {
        _ = #exhaust(
            reverseGen,
            .suppress(.issueReporting),
            .budget(.extensive),
            .replay(1337)
        ) { _ in true }
    }

    benchmark("Gen: Replacement") {
        _ = #exhaust(
            replacementGen,
            .suppress(.issueReporting),
            .budget(.extensive),
            .replay(1337)
        ) { _ in true }
    }

    benchmark("Gen: Parser") {
        _ = #exhaust(
            parserLangGen,
            .suppress(.issueReporting),
            .budget(.extensive),
            .replay(1337)
        ) { _ in true }
    }

    benchmark("Gen: GraphColoring") {
        _ = #exhaust(
            graphColoringGen,
            .suppress(.issueReporting),
            .budget(.extensive),
            .replay(1337)
        ) { _ in true }
    }
}
