import ExhaustCore
import Testing
@testable import Exhaust

@Suite("RunLedger properties")
struct RunLedgerPropertyTests {
    @Test("Operation generator is well-formed")
    func operationGeneratorValidation() {
        #examine(ledgerOperationsGen, .samples(50))
    }

    @Test("Ledger cells match a naive per-cell model")
    func cellsMatchNaiveModel() {
        #exhaust(ledgerOperationsGen) { operations in
            var ledger = RunLedger()
            apply(operations, to: &ledger)
            let model = modelCells(for: operations)
            for phase in RunLedger.Phase.allCases {
                var phaseTotal = 0
                for outcome in RunLedger.Outcome.allCases {
                    let expected = model[Cell(phase: phase, outcome: outcome), default: 0]
                    #expect(ledger.count(phase, outcome) == expected)
                    phaseTotal += expected
                }
                #expect(ledger.count(phase) == phaseTotal)
            }
            #expect(ledger.totalInvocations == model.values.reduce(0, +))
            #expect(ledger.totalSkips == model.filter { $0.key.outcome == .skip }.values.reduce(0, +))
        }
    }

    @Test("Aggregate recording derives the pass bucket so outcomes sum to invocations")
    func aggregateRecordingSumsToInvocations() {
        let gen = #gen(
            .element(from: RunLedger.Phase.allCases),
            .int(in: 0 ... 50),
            .int(in: 0 ... 20),
            .int(in: 0 ... 20)
        )
        #exhaust(gen) { phase, passes, skips, failures in
            var ledger = RunLedger()
            let invocations = passes + skips + failures
            ledger.record(phase, invocations: invocations, skips: skips, failures: failures)
            return ledger.count(phase) == invocations
                && ledger.count(phase, .pass) == passes
                && ledger.count(phase, .skip) == skips
                && ledger.count(phase, .fail) == failures
        }
    }

    @Test("Merging split ledgers equals recording sequentially")
    func mergeEqualsSequentialRecording() {
        let gen = #gen(ledgerOperationsGen, ledgerOperationsGen)
        #exhaust(gen) { firstOperations, secondOperations in
            var merged = RunLedger()
            apply(firstOperations, to: &merged)
            var second = RunLedger()
            apply(secondOperations, to: &second)
            merged.merge(second)

            var sequential = RunLedger()
            apply(firstOperations + secondOperations, to: &sequential)
            return merged == sequential
        }
    }
}

// MARK: - Supporting Types

private enum LedgerOperation {
    case single(RunLedger.Phase, RunLedger.Outcome, count: Int)
    case aggregate(RunLedger.Phase, passes: Int, skips: Int, failures: Int)
}

private struct Cell: Hashable {
    let phase: RunLedger.Phase
    let outcome: RunLedger.Outcome
}

// MARK: - Helpers

private let singleOperationGen = #gen(
    .element(from: RunLedger.Phase.allCases),
    .element(from: RunLedger.Outcome.allCases),
    .int(in: 0 ... 20)
) { phase, outcome, count in
    LedgerOperation.single(phase, outcome, count: count)
}

/// Aggregate operands are generated as passes, skips, and failures so `invocations == passes + skips + failures` holds by construction.
private let aggregateOperationGen = #gen(
    .element(from: RunLedger.Phase.allCases),
    .int(in: 0 ... 20),
    .int(in: 0 ... 20),
    .int(in: 0 ... 20)
) { phase, passes, skips, failures in
    LedgerOperation.aggregate(phase, passes: passes, skips: skips, failures: failures)
}

private let ledgerOperationGen: ReflectiveGenerator<LedgerOperation> = #gen(.oneOf(singleOperationGen, aggregateOperationGen))

private let ledgerOperationsGen = #gen(ledgerOperationGen.array(length: 0 ... 30))

private func apply(_ operations: [LedgerOperation], to ledger: inout RunLedger) {
    for operation in operations {
        switch operation {
            case let .single(phase, outcome, count):
                ledger.record(phase, outcome, count: count)
            case let .aggregate(phase, passes, skips, failures):
                ledger.record(phase, invocations: passes + skips + failures, skips: skips, failures: failures)
        }
    }
}

private func modelCells(for operations: [LedgerOperation]) -> [Cell: Int] {
    var cells = [Cell: Int]()
    for operation in operations {
        switch operation {
            case let .single(phase, outcome, count):
                cells[Cell(phase: phase, outcome: outcome), default: 0] += count
            case let .aggregate(phase, passes, skips, failures):
                cells[Cell(phase: phase, outcome: .pass), default: 0] += passes
                cells[Cell(phase: phase, outcome: .skip), default: 0] += skips
                cells[Cell(phase: phase, outcome: .fail), default: 0] += failures
        }
    }
    return cells
}
