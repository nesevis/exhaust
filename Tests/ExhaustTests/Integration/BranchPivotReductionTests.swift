import Exhaust
import Testing

@Suite("Branch pivot reduction")
struct BranchPivotReductionTests {
    @Test("The reduced counterexample does not depend on which arm sampling reached first", arguments: ArmOrder.allCases)
    func reductionCrossesArms(order: ArmOrder) throws {
        for seed in UInt64(1) ... 12 {
            let counterexample = #exhaust(order.generator, .replay(.numeric(seed)), .suppress(.issueReporting)) { shape in
                shape.area <= 100
            }
            #expect(try #require(counterexample) == .circle(6))
        }
    }
}

// MARK: - Supporting Types

enum PivotShape: Equatable {
    case circle(Int)
    case rect(Int, Int)

    var area: Int {
        switch self {
            case let .circle(radius):
                radius * radius * 3
            case let .rect(width, height):
                width * height
        }
    }
}

enum ArmOrder: CaseIterable, CustomTestStringConvertible {
    case simplerArmFirst
    case simplerArmLast

    var testDescription: String {
        "\(self)"
    }

    var generator: ReflectiveGenerator<PivotShape> {
        let circle = #gen(.int(in: 0 ... 100)) { PivotShape.circle($0) }
        let rect = #gen(.int(in: 0 ... 100), .int(in: 0 ... 100)) { PivotShape.rect($0, $1) }
        switch self {
            case .simplerArmFirst:
                return #gen(.oneOf(circle, rect))
            case .simplerArmLast:
                return #gen(.oneOf(rect, circle))
        }
    }
}
