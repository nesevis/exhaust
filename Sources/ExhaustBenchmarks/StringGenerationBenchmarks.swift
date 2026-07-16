import Benchmark
import Exhaust
import ExhaustCore
import Foundation

// MARK: - String generation performance isolation

//
// Mirrors the user-reported case where an unconstrained `.string(length:)` inside an
// order generator tripled total property-test time. Each case runs a passing property
// so the cost measured is pure generation.

func registerStringGenerationBenchmarks() {
    let budget = ExhaustBudget.standard

    benchmark("String: unconstrained") {
        _ = #exhaust(
            #gen(.string()),
            .suppress(.issueReporting),
            .budget(budget),
            .replay(1337)
        ) { _ in true }
    }

    benchmark("String: length 1...10") {
        _ = #exhaust(
            #gen(.string(length: 1 ... 10)),
            .suppress(.issueReporting),
            .budget(budget),
            .replay(1337)
        ) { _ in true }
    }

    benchmark("String: array of unconstrained") {
        _ = #exhaust(
            #gen(.string().array(length: 1 ... 20)),
            .suppress(.issueReporting),
            .budget(budget),
            .replay(1337)
        ) { _ in true }
    }

    benchmark("Order: unconstrained name") {
        _ = #exhaust(
            orderGenerator(nameLength: nil),
            .suppress(.issueReporting),
            .budget(budget),
            .replay(1337)
        ) { _ in true }
    }

    benchmark("Order: name length 1...10") {
        _ = #exhaust(
            orderGenerator(nameLength: 1 ... 10),
            .suppress(.issueReporting),
            .budget(budget),
            .replay(1337)
        ) { _ in true }
    }

    // Mirrors the `longStringReduction` experimental challenge: reduce a ~2,800-character haystack to the needle. Reduction replay is Materializer-bound and almost every choice is a character chooseBits, so this isolates per-character materialization cost.
    let needle = "syzygy"
    let reductionGen = #gen(.string()).gen
    let reductionProperty: @Sendable (String) -> Bool = { $0.contains(needle) == false }
    let haystackTree = try? Interpreters.reflect(reductionGen, with: longStringHaystack)

    benchmark("String: long reduction") {
        guard let haystackTree else { fatalError("haystack failed to reflect") }
        _ = try? Interpreters.choiceGraphReduce(
            gen: reductionGen,
            tree: haystackTree,
            output: longStringHaystack,
            config: .init(maxStalls: 2),
            property: reductionProperty
        )
    }
}

// MARK: - Order fixture (mirrors the reported generator)

private struct BenchItem {
    let name: String
    let price: Double
}

private struct BenchCoupon {
    let discountPercentage: Double
}

private struct BenchOrder {
    let items: [BenchItem]
    let coupon: BenchCoupon?
    let purchaseDate: Date
}

// MARK: - Long string reduction fixture (mirrors the longStringReduction experimental challenge)

private let longStringHaystack = """
Elena had always believed that the universe spoke in geometry. Not in words, not in feelings, but in the precise language of angles and arcs. It was why she'd become a clockmaker — or, more accurately, why clockmaking had claimed her.
Her workshop sat at the end of a narrow lane in a town that rarely appeared on maps. The shelves were cluttered with brass gears, coiled springs, and the skeletal remains of timepieces that had outlived their owners. She repaired them all, but the clock she truly cared about was her own.
She called it the Orrery, though it was far more than that. Three concentric rings of hammered silver orbited a central golden disc, each carrying a polished stone — onyx, pearl, and garnet. The mechanism tracked no known celestial body. It tracked something else entirely, something she'd spent eleven years trying to understand.
Her grandmother had left it to her with a single instruction written on a scrap of linen: Wait for the syzygy.
Elena had looked the word up as a teenager. A syzygy — the alignment of three celestial bodies along a single gravitational axis. Sun, Earth, Moon drawn into a line. She'd assumed it was metaphorical, a poetic flourish from a woman who kept dried lavender in her pockets and sang to house spiders.
But on the first night of her eleventh year with the Orrery, the three stones began to drift from their usual paths. The onyx slowed. The pearl accelerated. The garnet held steady, a fulcrum around which the others negotiated. By midnight, they formed a perfect line through the golden center.
The workshop filled with a sound like a tuning fork pressed to water. The air thinned. And in the space above the clock, Elena saw it — not light exactly, but the absence of shadow. A window into a place where geometry was not a description of reality but reality itself. Pure structure without substance.
She reached toward it, and the vision folded shut like a closing eye. The stones resumed their wandering orbits. The ordinary sounds of the lane — a cat, a distant engine, wind against the shutters — returned as though they'd merely been holding their breath.
Elena sat for a long time in the dark. Then she picked up her grandmother's note, turned it over, and read what she'd somehow never noticed on the back:
Now build the next one.
"""

private let benchStart = Date(timeIntervalSince1970: 1_767_225_600) // 2026-01-01
private let benchEnd = Date(timeIntervalSince1970: 1_785_456_000) // 2026-07-31
private let benchMelbourne = TimeZone(identifier: "Australia/Melbourne")!

private func orderGenerator(nameLength: ClosedRange<Int>?) -> ReflectiveGenerator<BenchOrder> {
    let itemGenerator = #gen(
        nameLength.map { .string(length: $0) } ?? .string(),
        .double(in: 1 ... Double.greatestFiniteMagnitude)
    ) { name, price in
        BenchItem(name: name, price: price)
    }
    let couponGenerator = #gen(.double(in: -50.0 ... 100)) {
        BenchCoupon(discountPercentage: $0)
    }.optional()
    return #gen(
        itemGenerator.array(length: 1 ... 20),
        couponGenerator,
        .date(
            between: benchStart ... benchEnd,
            interval: .hours(1),
            timeZone: benchMelbourne
        )
    ) { items, coupon, date in
        BenchOrder(
            items: items,
            coupon: coupon,
            purchaseDate: date
        )
    }
}
