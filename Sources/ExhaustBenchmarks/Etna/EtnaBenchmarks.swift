// MARK: - Etna Mutation-Testing Benchmarks

//
// Measures bug-finding effectiveness: for each (mutant, property) task,
// how many iterations until Exhaust detects the injected bug?
// Methodology matches Keles et al. "Etna: An Evaluation Platform for PBT" (2026).

import Benchmark
import Exhaust

// MARK: - Shared Generators

/// Haskell's `Int` arbitrary is effectively -100 ... 100 at size 100
let intGen = #gen(.int(in: -100 ... 100, scaling: .exponential))

// MARK: - Result Types

private final class PropertyTimer: @unchecked Sendable {
    var accumulatedNanos: UInt64 = 0
    @inline(__always) func start() -> UInt64 {
        monotonicNanoseconds()
    }

    @inline(__always) func stop(_ startNanos: UInt64) {
        accumulatedNanos &+= monotonicNanoseconds() &- startNanos
    }

    var milliseconds: Double {
        Double(accumulatedNanos) / 1_000_000
    }
}

private struct EtnaResult {
    let seed: UInt64
    let solved: Bool
    let coverageInvocations: Int
    let randomInvocations: Int
    let reductionInvocations: Int
    let totalInvocations: Int
    let coverageMs: Double
    let generationMs: Double
    let propertyMs: Double
    let reductionMs: Double
    let totalMs: Double
    let counterexample: String?

    var generationOnlyMs: Double {
        generationMs + coverageMs - propertyMs
    }
}

// MARK: - Task Runner

private func runEtnaSeeds<Input>(
    refGen: ReflectiveGenerator<Input>,
    property: @Sendable @escaping (Input) -> Bool,
    seedCount: Int,
    baseSeed: UInt64,
    coverageBudget: Int,
    samplingBudget: Int
) -> [EtnaResult] {
    var results: [EtnaResult] = []

    for index in 0 ..< seedCount {
        let seed = baseSeed &+ UInt64(index)

        var capturedReport: ExhaustReport?
        let timer = PropertyTimer()
        let counterexample = #exhaust(
            refGen,
            .suppress(.all),
            .budget(.custom(coverage: coverageBudget, sampling: samplingBudget)),
            .replay(ReplaySeed.numeric(seed)),
            .onReport { capturedReport = $0 }
        ) { value in
            let lap = timer.start()
            let result = property(value)
            timer.stop(lap)
            return result
        }

        guard let report = capturedReport else { continue }
        results.append(EtnaResult(
            seed: seed,
            solved: counterexample != nil,
            coverageInvocations: report.coverageInvocations,
            randomInvocations: report.randomSamplingInvocations,
            reductionInvocations: report.reductionInvocations,
            totalInvocations: report.propertyInvocations,
            coverageMs: report.coverageMilliseconds,
            generationMs: report.generationMilliseconds,
            propertyMs: timer.milliseconds,
            reductionMs: report.reductionMilliseconds,
            totalMs: report.totalMilliseconds,
            counterexample: counterexample.map { String(describing: $0) }
        ))
    }
    return results
}

// MARK: - Reporting

private func printEtnaTaskReport(name: String, seedCount: Int, results: [EtnaResult]) {
    return
    let solved = results.filter(\.solved)
    let solvedCount = solved.count

    guard solvedCount > 0 else {
        print("[\(name)] solved=0/\(seedCount)")
        return
    }

    let bugFindingInvocations = solved.map { $0.coverageInvocations + $0.randomInvocations }
    let meanInvoc = Double(bugFindingInvocations.reduce(0, +)) / Double(solvedCount)
    let meanCov = Double(solved.map(\.coverageInvocations).reduce(0, +)) / Double(solvedCount)
    let meanRand = Double(solved.map(\.randomInvocations).reduce(0, +)) / Double(solvedCount)

    let bucketUnder100 = bugFindingInvocations.count(where: { $0 < 100 })
    let bucketUnder1K = bugFindingInvocations.count(where: { $0 >= 100 && $0 < 1000 })
    let bucketUnder10K = bugFindingInvocations.count(where: { $0 >= 1000 && $0 < 10000 })
    let unsolved = seedCount - solvedCount

    let f1 = { (value: Double) in String(format: "%.1f", value) }
    let f2 = { (value: Double) in String(format: "%.2f", value) }

    let meanMs = solved.map { $0.generationMs + $0.coverageMs }.reduce(0, +) / Double(solvedCount)
    let reductionInvocs = solved.map(\.reductionInvocations)
    let hasReduction = reductionInvocs.contains { $0 > 0 }

    let unsolvableAttempts = results.filter { $0.solved == false }.map(\.totalInvocations)
    let meanUnsolvedAttempts = unsolvableAttempts.isEmpty ? 0 : Double(unsolvableAttempts.reduce(0, +)) / Double(unsolvableAttempts.count)

    var line = "[\(name)] solved=\(solvedCount)/\(seedCount) invoc=\(f1(meanInvoc)) (cov=\(f1(meanCov)) rand=\(f1(meanRand))) \(f2(meanMs))ms (< 100: \(bucketUnder100) | < 1K: \(bucketUnder1K) | < 10K: \(bucketUnder10K) | unsolved: \(unsolved))"
    if unsolved > 0 {
        line += " unsolved_attempts=\(f1(meanUnsolvedAttempts))"
    }

    if hasReduction {
        let meanRedInvoc = Double(reductionInvocs.reduce(0, +)) / Double(solvedCount)
        let meanRedMs = solved.map(\.reductionMs).reduce(0, +) / Double(solvedCount)
        line += " reduce=\(f1(meanRedInvoc))invoc/\(f2(meanRedMs))ms"
    }

    print(line)
}

private func printEtnaSummary(workload: String, taskResults: [(name: String, results: [EtnaResult])], seedCount: Int) {
    let totalTasks = taskResults.count
    var solvedBuckets = (under100: 0, under1K: 0, under10K: 0)
    var unsolvedNames: [String] = []

    for task in taskResults {
        let solved = task.results.filter(\.solved)
        let solveRate = Double(solved.count) / Double(seedCount)
        if solveRate <= 0.5 {
            unsolvedNames.append(task.name)
            continue
        }
        let meanIter = Double(solved.map { $0.coverageInvocations + $0.randomInvocations }.reduce(0, +)) / Double(solved.count)
        if meanIter < 100 {
            solvedBuckets.under100 += 1
        } else if meanIter < 1000 {
            solvedBuckets.under1K += 1
        } else {
            solvedBuckets.under10K += 1
        }
    }

    let detected = totalTasks - unsolvedNames.count

    let f2 = { (value: Double) in String(format: "%.2f", value) }
    var totalGenMs = 0.0
    var totalGenOnlyMs = 0.0
    for task in taskResults {
        let taskGenMs = task.results.map { $0.generationMs + $0.coverageMs }.reduce(0, +) / Double(seedCount)
        let taskGenOnlyMs = task.results.map(\.generationOnlyMs).reduce(0, +) / Double(seedCount)
        totalGenMs += taskGenMs
        totalGenOnlyMs += taskGenOnlyMs
    }

    print("[Etna \(workload)] \(detected)/\(totalTasks) bugs detected | gen time: \(f2(totalGenMs))ms (gen only: \(f2(totalGenOnlyMs))ms) | < 100: \(solvedBuckets.under100) | < 1K: \(solvedBuckets.under1K) | < 10K: \(solvedBuckets.under10K)")
    if unsolvedNames.isEmpty == false {
        print("[Etna \(workload)] Unsolved (\(unsolvedNames.count)): \(unsolvedNames.joined(separator: ", "))")
    }
}

// MARK: - BST Task Registration

//
// 52 tasks from etna.toml, each a specific (mutant, property) pair.
// Insert operations: insert_1, insert_2, insert_3
// Delete operations: delete_4, delete_5
// Union operations: union_6, union_7, union_8

private func registerEtnaBSTBenchmark(
    seedCount: Int,
    baseSeed: UInt64,
    coverageBudget: Int,
    samplingBudget: Int
) {
    typealias InsertFn = @Sendable (Int, Int, EtnaBST) -> EtnaBST
    typealias DeleteFn = @Sendable (Int, EtnaBST) -> EtnaBST
    typealias UnionFn = @Sendable (EtnaBST, EtnaBST) -> EtnaBST

    let insertMutants: [(String, InsertFn)] = [
        ("insert_1", bstInsert_1), ("insert_2", bstInsert_2), ("insert_3", bstInsert_3),
    ]
    let deleteMutants: [(String, DeleteFn)] = [
        ("delete_4", bstDelete_4), ("delete_5", bstDelete_5),
    ]
    let unionMutants: [(String, UnionFn)] = [
        ("union_6", bstUnion_6), ("union_7", bstUnion_7), ("union_8", bstUnion_8),
    ]

    // Bespoke generator guarantees valid BSTs; precondition guards omitted.

    func insertPost(_ insert: @escaping InsertFn) -> (ReflectiveGenerator<(EtnaBST, Int, Int, Int)>, @Sendable ((EtnaBST, Int, Int, Int)) -> Bool) {
        (etnaBSTInsertPostInputGen, { input in
            let (tree, key, queryKey, value) = input
            let expected = key == queryKey ? value : bstFind(queryKey, tree)
            return bstFind(queryKey, insert(key, value, tree)) == expected
        })
    }
    func insertModel(_ insert: @escaping InsertFn) -> (ReflectiveGenerator<(EtnaBST, Int, Int)>, @Sendable ((EtnaBST, Int, Int)) -> Bool) {
        (etnaBSTInsertInputGen, { input in
            let (tree, key, value) = input
            return bstListsEqual(bstToList(insert(key, value, tree)), bstSortedInsert(key, value, bstToList(tree)))
        })
    }
    func deletePost(_ delete: @escaping DeleteFn) -> (ReflectiveGenerator<(EtnaBST, Int, Int)>, @Sendable ((EtnaBST, Int, Int)) -> Bool) {
        (etnaBSTDeletePostInputGen, { input in
            let (tree, key, queryKey) = input
            let expected = key == queryKey ? nil : bstFind(queryKey, tree)
            return bstFind(queryKey, delete(key, tree)) == expected
        })
    }
    func deleteModel(_ delete: @escaping DeleteFn) -> (ReflectiveGenerator<(EtnaBST, Int)>, @Sendable ((EtnaBST, Int)) -> Bool) {
        (etnaBSTDeleteInputGen, { input in
            let (tree, key) = input
            return bstListsEqual(bstToList(delete(key, tree)), bstDeleteKey(key, bstToList(tree)))
        })
    }
    func unionValid(_ union: @escaping UnionFn) -> (ReflectiveGenerator<(EtnaBST, EtnaBST)>, @Sendable ((EtnaBST, EtnaBST)) -> Bool) {
        (etnaBSTUnionInputGen, { input in
            let (tree1, tree2) = input
            return bstIsBST(union(tree1, tree2))
        })
    }
    func unionPost(_ union: @escaping UnionFn) -> (ReflectiveGenerator<(EtnaBST, EtnaBST, Int)>, @Sendable ((EtnaBST, EtnaBST, Int)) -> Bool) {
        (etnaBSTUnionPostInputGen, { input in
            let (tree1, tree2, key) = input
            let expected = bstFind(key, tree1) ?? bstFind(key, tree2)
            return bstFind(key, union(tree1, tree2)) == expected
        })
    }
    func unionModel(_ union: @escaping UnionFn) -> (ReflectiveGenerator<(EtnaBST, EtnaBST)>, @Sendable ((EtnaBST, EtnaBST)) -> Bool) {
        (etnaBSTUnionInputGen, { input in
            let (tree1, tree2) = input
            return bstListsEqual(bstToList(union(tree1, tree2)), bstSortedUnion(bstToList(tree1), bstToList(tree2)))
        })
    }
    func insertInsert(_ insert: @escaping InsertFn) -> (ReflectiveGenerator<(EtnaBST, Int, Int, Int, Int)>, @Sendable ((EtnaBST, Int, Int, Int, Int)) -> Bool) {
        (etnaBSTInsertInsertInputGen, { input in
            let (tree, key, otherKey, value, otherValue) = input
            let lhs = insert(key, value, insert(otherKey, otherValue, tree))
            let rhs = key == otherKey ? insert(key, value, tree) : insert(otherKey, otherValue, insert(key, value, tree))
            return bstStructurallyEqual(lhs, rhs)
        })
    }
    func insertDelete(_ insert: @escaping InsertFn, _ delete: @escaping DeleteFn) -> (ReflectiveGenerator<(EtnaBST, Int, Int, Int)>, @Sendable ((EtnaBST, Int, Int, Int)) -> Bool) {
        (etnaBSTInsertDeleteInputGen, { input in
            let (tree, key, otherKey, value) = input
            let lhs = insert(key, value, delete(otherKey, tree))
            let rhs = key == otherKey ? insert(key, value, tree) : delete(otherKey, insert(key, value, tree))
            return bstStructurallyEqual(lhs, rhs)
        })
    }
    func deleteInsert(_ insert: @escaping InsertFn, _ delete: @escaping DeleteFn) -> (ReflectiveGenerator<(EtnaBST, Int, Int, Int)>, @Sendable ((EtnaBST, Int, Int, Int)) -> Bool) {
        (etnaBSTInsertDeleteInputGen, { input in
            let (tree, key, otherKey, otherValue) = input
            let lhs = delete(key, insert(otherKey, otherValue, tree))
            let rhs = key == otherKey ? delete(key, tree) : insert(otherKey, otherValue, delete(key, tree))
            return bstStructurallyEqual(lhs, rhs)
        })
    }
    func deleteDelete(_ delete: @escaping DeleteFn) -> (ReflectiveGenerator<(EtnaBST, Int, Int)>, @Sendable ((EtnaBST, Int, Int)) -> Bool) {
        (etnaBSTDeleteDeleteInputGen, { input in
            let (tree, key, otherKey) = input
            return bstStructurallyEqual(delete(key, delete(otherKey, tree)), delete(otherKey, delete(key, tree)))
        })
    }
    func insertUnion(_ insert: @escaping InsertFn, _ union: @escaping UnionFn) -> (ReflectiveGenerator<(EtnaBST, EtnaBST, Int, Int)>, @Sendable ((EtnaBST, EtnaBST, Int, Int)) -> Bool) {
        (etnaBSTInsertUnionInputGen, { input in
            let (tree1, tree2, key, value) = input
            return bstStructurallyEqual(insert(key, value, union(tree1, tree2)), union(insert(key, value, tree1), tree2))
        })
    }
    func deleteUnion(_ delete: @escaping DeleteFn, _ union: @escaping UnionFn) -> (ReflectiveGenerator<(EtnaBST, EtnaBST, Int)>, @Sendable ((EtnaBST, EtnaBST, Int)) -> Bool) {
        (etnaBSTUnionPostInputGen, { input in
            let (tree1, tree2, key) = input
            return bstStructurallyEqual(delete(key, union(tree1, tree2)), union(delete(key, tree1), delete(key, tree2)))
        })
    }
    func unionDeleteInsert(_ insert: @escaping InsertFn, _ delete: @escaping DeleteFn, _ union: @escaping UnionFn) -> (ReflectiveGenerator<(EtnaBST, EtnaBST, Int, Int)>, @Sendable ((EtnaBST, EtnaBST, Int, Int)) -> Bool) {
        (etnaBSTInsertUnionInputGen, { input in
            let (tree1, tree2, key, value) = input
            return bstStructurallyEqual(union(delete(key, tree1), insert(key, value, tree2)), insert(key, value, union(tree1, tree2)))
        })
    }
    func unionUnionAssoc(_ union: @escaping UnionFn) -> (ReflectiveGenerator<(EtnaBST, EtnaBST, EtnaBST)>, @Sendable ((EtnaBST, EtnaBST, EtnaBST)) -> Bool) {
        (etnaBSTUnionUnionInputGen, { input in
            let (tree1, tree2, tree3) = input
            return union(union(tree1, tree2), tree3) == union(tree1, union(tree2, tree3))
        })
    }

    /// Helper to register a single task.
    func task<Input>(_ name: String, _ gen: ReflectiveGenerator<Input>, _ property: @Sendable @escaping (Input) -> Bool,
                     _ allResults: inout [(name: String, results: [EtnaResult])])
    {
        let results = runEtnaSeeds(refGen: gen, property: property, seedCount: seedCount, baseSeed: baseSeed,
                                   coverageBudget: coverageBudget, samplingBudget: samplingBudget)
        printEtnaTaskReport(name: name, seedCount: seedCount, results: results)
        allResults.append((name, results))
    }

    benchmark("Etna BST") {
        var allResults: [(name: String, results: [EtnaResult])] = []
        let ins = bstInsert as InsertFn
        let del = bstDelete as DeleteFn
        let uni = bstUnion as UnionFn

        // 52 tasks from etna.toml, grouped by mutant.

        for (mutName, mutIns) in insertMutants {
            let p1 = insertPost(mutIns); task("\(mutName) × InsertPost", p1.0, p1.1, &allResults)
            let p2 = insertModel(mutIns); task("\(mutName) × InsertModel", p2.0, p2.1, &allResults)
            let p3 = insertInsert(mutIns); task("\(mutName) × InsertInsert", p3.0, p3.1, &allResults)
            let p4 = insertUnion(mutIns, uni); task("\(mutName) × InsertUnion", p4.0, p4.1, &allResults)
            let p5 = unionDeleteInsert(mutIns, del, uni); task("\(mutName) × UnionDeleteInsert", p5.0, p5.1, &allResults)
            // Per etna.toml: insert_1 and insert_2 have DeleteInsert; insert_3 does not
            if mutName != "insert_3" {
                let p6 = deleteInsert(mutIns, del); task("\(mutName) × DeleteInsert", p6.0, p6.1, &allResults)
            }
            // Per etna.toml: insert_2 and insert_3 have InsertDelete; insert_1 does not
            if mutName != "insert_1" {
                let p7 = insertDelete(mutIns, del); task("\(mutName) × InsertDelete", p7.0, p7.1, &allResults)
            }
        }

        for (mutName, mutDel) in deleteMutants {
            let p1 = deletePost(mutDel); task("\(mutName) × DeletePost", p1.0, p1.1, &allResults)
            let p2 = deleteModel(mutDel); task("\(mutName) × DeleteModel", p2.0, p2.1, &allResults)
            let p3 = deleteDelete(mutDel); task("\(mutName) × DeleteDelete", p3.0, p3.1, &allResults)
            let p4 = deleteInsert(ins, mutDel); task("\(mutName) × DeleteInsert", p4.0, p4.1, &allResults)
            let p5 = deleteUnion(mutDel, uni); task("\(mutName) × DeleteUnion", p5.0, p5.1, &allResults)
            let p6 = unionDeleteInsert(ins, mutDel, uni); task("\(mutName) × UnionDeleteInsert", p6.0, p6.1, &allResults)
            // Per etna.toml: delete_4 has InsertDelete; delete_5 does not
            if mutName == "delete_4" {
                let p7 = insertDelete(ins, mutDel); task("\(mutName) × InsertDelete", p7.0, p7.1, &allResults)
            }
        }

        for (mutName, mutUni) in unionMutants {
            let p1 = unionPost(mutUni); task("\(mutName) × UnionPost", p1.0, p1.1, &allResults)
            let p2 = unionModel(mutUni); task("\(mutName) × UnionModel", p2.0, p2.1, &allResults)
            let p3 = deleteUnion(del, mutUni); task("\(mutName) × DeleteUnion", p3.0, p3.1, &allResults)
            let p4 = insertUnion(ins, mutUni); task("\(mutName) × InsertUnion", p4.0, p4.1, &allResults)
            let p5 = unionDeleteInsert(ins, del, mutUni); task("\(mutName) × UnionDeleteInsert", p5.0, p5.1, &allResults)
            let p6 = unionUnionAssoc(mutUni); task("\(mutName) × UnionUnionAssoc", p6.0, p6.1, &allResults)
            // union_6 also has UnionValid; union_7 and union_8 do not
            if mutName == "union_6" || mutName == "union_7" {
                let p7 = unionValid(mutUni); task("\(mutName) × UnionValid", p7.0, p7.1, &allResults)
            }
        }

        printEtnaSummary(workload: "BST", taskResults: allResults, seedCount: seedCount)
    }
}

// MARK: - RBT Task Registration

//
// 58 tasks from etna.toml, each a specific (mutant, property) pair.
// 15 mutants across insert, delete, balance, balLeft, balRight, and join.
// 10 properties: InsertValid, InsertPost, InsertModel, DeleteValid, DeletePost,
//   DeleteModel, InsertInsert, InsertDelete, DeleteInsert, DeleteDelete.

private func registerEtnaRBTBenchmark(
    seedCount: Int,
    baseSeed: UInt64,
    coverageBudget: Int,
    samplingBudget: Int
) {
    typealias InsertFn = @Sendable (Int, Int, EtnaRBT) -> EtnaRBT
    typealias DeleteFn = @Sendable (Int, EtnaRBT) -> Result<EtnaRBT, RBTError>

    let ins = rbtInsert as InsertFn
    let del = rbtDelete as DeleteFn

    // MARK: Property builders

    // Bespoke generator guarantees valid RBTs; precondition guards omitted.

    func insertValid(_ insert: @escaping InsertFn) -> (ReflectiveGenerator<(EtnaRBT, Int, Int)>, @Sendable ((EtnaRBT, Int, Int)) -> Bool) {
        (etnaRBTInsertInputGen, { input in
            let (tree, key, value) = input
            return insert(key, value, tree).isValidRBT
        })
    }
    func insertPost(_ insert: @escaping InsertFn) -> (ReflectiveGenerator<(EtnaRBT, Int, Int, Int)>, @Sendable ((EtnaRBT, Int, Int, Int)) -> Bool) {
        (etnaRBTInsertPostInputGen, { input in
            let (tree, key, queryKey, value) = input
            let expected = key == queryKey ? value : rbtFind(queryKey, tree)
            return rbtFind(queryKey, insert(key, value, tree)) == expected
        })
    }
    func insertModel(_ insert: @escaping InsertFn) -> (ReflectiveGenerator<(EtnaRBT, Int, Int)>, @Sendable ((EtnaRBT, Int, Int)) -> Bool) {
        (etnaRBTInsertInputGen, { input in
            let (tree, key, value) = input
            return bstListsEqual(rbtToList(insert(key, value, tree)), bstSortedInsert(key, value, rbtToList(tree)))
        })
    }
    func deleteValid(_ delete: @escaping DeleteFn) -> (ReflectiveGenerator<(EtnaRBT, Int)>, @Sendable ((EtnaRBT, Int)) -> Bool) {
        (etnaRBTDeleteInputGen, { input in
            let (tree, key) = input
            switch delete(key, tree) {
                case let .success(result): return result.isValidRBT
                case .failure: return false
            }
        })
    }
    func deletePost(_ delete: @escaping DeleteFn) -> (ReflectiveGenerator<(EtnaRBT, Int, Int)>, @Sendable ((EtnaRBT, Int, Int)) -> Bool) {
        (etnaRBTDeletePostInputGen, { input in
            let (tree, key, queryKey) = input
            switch delete(key, tree) {
                case let .success(result):
                    let expected = key == queryKey ? nil : rbtFind(queryKey, tree)
                    return rbtFind(queryKey, result) == expected
                case .failure:
                    return false
            }
        })
    }
    func deleteModel(_ delete: @escaping DeleteFn) -> (ReflectiveGenerator<(EtnaRBT, Int)>, @Sendable ((EtnaRBT, Int)) -> Bool) {
        (etnaRBTDeleteInputGen, { input in
            let (tree, key) = input
            switch delete(key, tree) {
                case let .success(result):
                    return bstListsEqual(rbtToList(result), bstDeleteKey(key, rbtToList(tree)))
                case .failure:
                    return false
            }
        })
    }
    func insertInsert(_ insert: @escaping InsertFn) -> (ReflectiveGenerator<(EtnaRBT, Int, Int, Int, Int)>, @Sendable ((EtnaRBT, Int, Int, Int, Int)) -> Bool) {
        (etnaRBTInsertInsertInputGen, { input in
            let (tree, key, otherKey, value, otherValue) = input
            let lhs = insert(key, value, insert(otherKey, otherValue, tree))
            let rhs = key == otherKey ? insert(key, value, tree) : insert(otherKey, otherValue, insert(key, value, tree))
            return bstListsEqual(rbtToList(lhs), rbtToList(rhs))
        })
    }
    func insertDelete(_ insert: @escaping InsertFn, _ delete: @escaping DeleteFn) -> (ReflectiveGenerator<(EtnaRBT, Int, Int, Int)>, @Sendable ((EtnaRBT, Int, Int, Int)) -> Bool) {
        (etnaRBTInsertDeleteInputGen, { input in
            let (tree, key, otherKey, value) = input
            guard case let .success(deleted) = delete(otherKey, tree) else { return false }
            guard case let .success(deletedInserted) = delete(otherKey, insert(key, value, tree)) else { return false }
            let lhs = insert(key, value, deleted)
            let rhs = key == otherKey ? insert(key, value, tree) : deletedInserted
            return bstListsEqual(rbtToList(lhs), rbtToList(rhs))
        })
    }
    func deleteInsert(_ insert: @escaping InsertFn, _ delete: @escaping DeleteFn) -> (ReflectiveGenerator<(EtnaRBT, Int, Int, Int)>, @Sendable ((EtnaRBT, Int, Int, Int)) -> Bool) {
        (etnaRBTInsertDeleteInputGen, { input in
            let (tree, key, otherKey, otherValue) = input
            guard case let .success(lhs) = delete(key, insert(otherKey, otherValue, tree)) else { return false }
            guard case let .success(deleted) = delete(key, tree) else { return false }
            let rhs = key == otherKey ? deleted : insert(otherKey, otherValue, deleted)
            return bstListsEqual(rbtToList(lhs), rbtToList(rhs))
        })
    }
    func deleteDelete(_ delete: @escaping DeleteFn) -> (ReflectiveGenerator<(EtnaRBT, Int, Int)>, @Sendable ((EtnaRBT, Int, Int)) -> Bool) {
        (etnaRBTDeletePostInputGen, { input in
            let (tree, key, otherKey) = input
            let lhs = delete(otherKey, tree).flatMap { delete(key, $0) }
            let rhs = delete(key, tree).flatMap { delete(otherKey, $0) }
            return rbtResultsEqual(lhs, rhs)
        })
    }

    func task<Input>(_ name: String, _ gen: ReflectiveGenerator<Input>, _ property: @Sendable @escaping (Input) -> Bool,
                     _ allResults: inout [(name: String, results: [EtnaResult])])
    {
        let results = runEtnaSeeds(refGen: gen, property: property, seedCount: seedCount, baseSeed: baseSeed,
                                   coverageBudget: coverageBudget, samplingBudget: samplingBudget)
        printEtnaTaskReport(name: name, seedCount: seedCount, results: results)
        allResults.append((name, results))
    }

    // MARK: 58 tasks from etna.toml

    benchmark("Etna RBT") {
        var allResults: [(name: String, results: [EtnaResult])] = []

        // insert_1 (4 tasks)
        do {
            let mutIns: InsertFn = rbtInsert_1
            let p1 = insertPost(mutIns); task("insert_1 × InsertPost", p1.0, p1.1, &allResults)
            let p2 = insertModel(mutIns); task("insert_1 × InsertModel", p2.0, p2.1, &allResults)
            let p3 = deleteInsert(mutIns, del); task("insert_1 × DeleteInsert", p3.0, p3.1, &allResults)
            let p4 = insertInsert(mutIns); task("insert_1 × InsertInsert", p4.0, p4.1, &allResults)
        }

        // insert_2 (5 tasks)
        do {
            let mutIns: InsertFn = rbtInsert_2
            let p1 = insertPost(mutIns); task("insert_2 × InsertPost", p1.0, p1.1, &allResults)
            let p2 = insertModel(mutIns); task("insert_2 × InsertModel", p2.0, p2.1, &allResults)
            let p3 = insertDelete(mutIns, del); task("insert_2 × InsertDelete", p3.0, p3.1, &allResults)
            let p4 = deleteInsert(mutIns, del); task("insert_2 × DeleteInsert", p4.0, p4.1, &allResults)
            let p5 = insertInsert(mutIns); task("insert_2 × InsertInsert", p5.0, p5.1, &allResults)
        }

        // insert_3 (4 tasks)
        do {
            let mutIns: InsertFn = rbtInsert_3
            let p1 = insertPost(mutIns); task("insert_3 × InsertPost", p1.0, p1.1, &allResults)
            let p2 = insertModel(mutIns); task("insert_3 × InsertModel", p2.0, p2.1, &allResults)
            let p3 = insertDelete(mutIns, del); task("insert_3 × InsertDelete", p3.0, p3.1, &allResults)
            let p4 = insertInsert(mutIns); task("insert_3 × InsertInsert", p4.0, p4.1, &allResults)
        }

        // delete_4 (5 tasks)
        do {
            let mutDel: DeleteFn = rbtDelete_4
            let p1 = deleteDelete(mutDel); task("delete_4 × DeleteDelete", p1.0, p1.1, &allResults)
            let p2 = deleteModel(mutDel); task("delete_4 × DeleteModel", p2.0, p2.1, &allResults)
            let p3 = deletePost(mutDel); task("delete_4 × DeletePost", p3.0, p3.1, &allResults)
            let p4 = deleteInsert(ins, mutDel); task("delete_4 × DeleteInsert", p4.0, p4.1, &allResults)
            let p5 = insertDelete(ins, mutDel); task("delete_4 × InsertDelete", p5.0, p5.1, &allResults)
        }

        // delete_5 (4 tasks)
        do {
            let mutDel: DeleteFn = rbtDelete_5
            let p1 = deleteModel(mutDel); task("delete_5 × DeleteModel", p1.0, p1.1, &allResults)
            let p2 = deletePost(mutDel); task("delete_5 × DeletePost", p2.0, p2.1, &allResults)
            let p3 = deleteDelete(mutDel); task("delete_5 × DeleteDelete", p3.0, p3.1, &allResults)
            let p4 = deleteInsert(ins, mutDel); task("delete_5 × DeleteInsert", p4.0, p4.1, &allResults)
        }

        // miscolor_insert (2 tasks)
        do {
            let mutIns: InsertFn = rbtInsert_miscolorInsert
            let p1 = insertValid(mutIns); task("miscolor_insert × InsertValid", p1.0, p1.1, &allResults)
            let p2 = deleteInsert(mutIns, del); task("miscolor_insert × DeleteInsert", p2.0, p2.1, &allResults)
        }

        // miscolor_delete (1 task)
        do {
            let mutDel: DeleteFn = rbtDelete_miscolorDelete
            let p1 = deleteValid(mutDel); task("miscolor_delete × DeleteValid", p1.0, p1.1, &allResults)
        }

        // miscolor_balLeft (2 tasks)
        do {
            let mutDel: DeleteFn = rbtDelete_miscolorBalLeft
            let p1 = deleteValid(mutDel); task("miscolor_balLeft × DeleteValid", p1.0, p1.1, &allResults)
            let p2 = deleteDelete(mutDel); task("miscolor_balLeft × DeleteDelete", p2.0, p2.1, &allResults)
        }

        // miscolor_balRight (2 tasks)
        do {
            let mutDel: DeleteFn = rbtDelete_miscolorBalRight
            let p1 = deleteValid(mutDel); task("miscolor_balRight × DeleteValid", p1.0, p1.1, &allResults)
            let p2 = deleteDelete(mutDel); task("miscolor_balRight × DeleteDelete", p2.0, p2.1, &allResults)
        }

        // miscolor_join_1 (1 task)
        do {
            let mutDel: DeleteFn = rbtDelete_miscolorJoin1
            let p1 = deleteValid(mutDel); task("miscolor_join_1 × DeleteValid", p1.0, p1.1, &allResults)
        }

        // miscolor_join_2 (2 tasks)
        do {
            let mutDel: DeleteFn = rbtDelete_miscolorJoin2
            let p1 = deleteValid(mutDel); task("miscolor_join_2 × DeleteValid", p1.0, p1.1, &allResults)
            let p2 = deleteDelete(mutDel); task("miscolor_join_2 × DeleteDelete", p2.0, p2.1, &allResults)
        }

        // no_balance_insert_1 (3 tasks)
        do {
            let mutIns: InsertFn = rbtInsert_noBalance1
            let p1 = insertValid(mutIns); task("no_balance_insert_1 × InsertValid", p1.0, p1.1, &allResults)
            let p2 = deleteInsert(mutIns, del); task("no_balance_insert_1 × DeleteInsert", p2.0, p2.1, &allResults)
            let p3 = insertDelete(mutIns, del); task("no_balance_insert_1 × InsertDelete", p3.0, p3.1, &allResults)
        }

        // no_balance_insert_2 (3 tasks)
        do {
            let mutIns: InsertFn = rbtInsert_noBalance2
            let p1 = insertValid(mutIns); task("no_balance_insert_2 × InsertValid", p1.0, p1.1, &allResults)
            let p2 = deleteInsert(mutIns, del); task("no_balance_insert_2 × DeleteInsert", p2.0, p2.1, &allResults)
            let p3 = insertDelete(mutIns, del); task("no_balance_insert_2 × InsertDelete", p3.0, p3.1, &allResults)
        }

        // swap_bc (10 tasks — all properties)
        do {
            let mutIns: InsertFn = rbtInsert_swapBC
            let mutDel: DeleteFn = rbtDelete_swapBC
            let p1 = insertValid(mutIns); task("swap_bc × InsertValid", p1.0, p1.1, &allResults)
            let p2 = insertModel(mutIns); task("swap_bc × InsertModel", p2.0, p2.1, &allResults)
            let p3 = insertPost(mutIns); task("swap_bc × InsertPost", p3.0, p3.1, &allResults)
            let p4 = deleteValid(mutDel); task("swap_bc × DeleteValid", p4.0, p4.1, &allResults)
            let p5 = deletePost(mutDel); task("swap_bc × DeletePost", p5.0, p5.1, &allResults)
            let p6 = deleteModel(mutDel); task("swap_bc × DeleteModel", p6.0, p6.1, &allResults)
            let p7 = deleteDelete(mutDel); task("swap_bc × DeleteDelete", p7.0, p7.1, &allResults)
            let p8 = deleteInsert(mutIns, mutDel); task("swap_bc × DeleteInsert", p8.0, p8.1, &allResults)
            let p9 = insertDelete(mutIns, mutDel); task("swap_bc × InsertDelete", p9.0, p9.1, &allResults)
            let p10 = insertInsert(mutIns); task("swap_bc × InsertInsert", p10.0, p10.1, &allResults)
        }

        // swap_cd (10 tasks — all properties)
        do {
            let mutIns: InsertFn = rbtInsert_swapCD
            let mutDel: DeleteFn = rbtDelete_swapCD
            let p1 = insertValid(mutIns); task("swap_cd × InsertValid", p1.0, p1.1, &allResults)
            let p2 = insertModel(mutIns); task("swap_cd × InsertModel", p2.0, p2.1, &allResults)
            let p3 = insertPost(mutIns); task("swap_cd × InsertPost", p3.0, p3.1, &allResults)
            let p4 = deleteValid(mutDel); task("swap_cd × DeleteValid", p4.0, p4.1, &allResults)
            let p5 = deletePost(mutDel); task("swap_cd × DeletePost", p5.0, p5.1, &allResults)
            let p6 = deleteModel(mutDel); task("swap_cd × DeleteModel", p6.0, p6.1, &allResults)
            let p7 = deleteDelete(mutDel); task("swap_cd × DeleteDelete", p7.0, p7.1, &allResults)
            let p8 = deleteInsert(mutIns, mutDel); task("swap_cd × DeleteInsert", p8.0, p8.1, &allResults)
            let p9 = insertDelete(mutIns, mutDel); task("swap_cd × InsertDelete", p9.0, p9.1, &allResults)
            let p10 = insertInsert(mutIns); task("swap_cd × InsertInsert", p10.0, p10.1, &allResults)
        }

        printEtnaSummary(workload: "RBT", taskResults: allResults, seedCount: seedCount)
    }
}

// MARK: - STLC Task Registration

//
// 20 tasks from etna.toml: 10 mutants × 2 properties (SinglePreserve, MultiPreserve).
// Mutants in shift (4), subst (4), and substTop (2).

private func registerEtnaSTLCBenchmark(
    seedCount: Int,
    baseSeed: UInt64,
    coverageBudget: Int,
    samplingBudget: Int
) {
    let mutants: [(String, STLCConfig)] = [
        ("shift_var_none", stlcConfig_shiftVarNone),
        ("shift_var_all", stlcConfig_shiftVarAll),
        ("shift_var_leq", stlcConfig_shiftVarLeq),
        ("shift_abs_no_incr", stlcConfig_shiftAbsNoIncr),
        ("subst_var_all", stlcConfig_substVarAll),
        ("subst_var_none", stlcConfig_substVarNone),
        ("subst_abs_no_shift", stlcConfig_substAbsNoShift),
        ("subst_abs_no_incr", stlcConfig_substAbsNoIncr),
        ("substTop_no_shift", stlcConfig_substTopNoShift),
        ("substTop_no_shift_back", stlcConfig_substTopNoShiftBack),
    ]

    benchmark("Etna STLC") {
        var allResults: [(name: String, results: [EtnaResult])] = []

        for (mutantName, config) in mutants {
            // SinglePreserve: isJust (getTyp [] e) --> mtypeCheck (pstep e) (fromJust (getTyp [] e))
            let singleResults = runEtnaSeeds(
                refGen: etnaSTLCExprGenRust,
                property: { @Sendable (expr: STLCExpr) -> Bool in
                    guard let originalType = stlcGetType([], expr) else { return true }
                    guard let stepped = stlcPstepImpl(expr, config: config) else { return true }
                    return stlcGetType([], stepped) == originalType
                },
                seedCount: seedCount, baseSeed: baseSeed,
                coverageBudget: coverageBudget, samplingBudget: samplingBudget
            )
            let singleName = "\(mutantName) × SinglePreserve"
            printEtnaTaskReport(name: singleName, seedCount: seedCount, results: singleResults)
            allResults.append((singleName, singleResults))

            // MultiPreserve: isJust (getTyp [] e) --> mtypeCheck (multistep 40 pstep e) (fromJust (getTyp [] e))
            let multiResults = runEtnaSeeds(
                refGen: etnaSTLCExprGenRust,
                property: { @Sendable (expr: STLCExpr) -> Bool in
                    guard let originalType = stlcGetType([], expr) else { return true }
                    guard let result = stlcMultistepImpl(40, expr, config: config) else { return true }
                    return stlcGetType([], result) == originalType
                },
                seedCount: seedCount, baseSeed: baseSeed,
                coverageBudget: coverageBudget, samplingBudget: samplingBudget
            )
            let multiName = "\(mutantName) × MultiPreserve"
            printEtnaTaskReport(name: multiName, seedCount: seedCount, results: multiResults)
            allResults.append((multiName, multiResults))
        }

        printEtnaSummary(workload: "STLC", taskResults: allResults, seedCount: seedCount)
    }
}

// MARK: - Entry Point

func registerEtnaBenchmarks() {
//    validateEtnaRBTGenerator()
//    validateEtnaSTLCGenerator()

    let seedCount = etnaSeedCount
    let baseSeed: UInt64 = 1337
    let coverageBudget = etnaCoverageBudget
    let samplingBudget = etnaSamplingBudget

    registerEtnaBSTBenchmark(
        seedCount: seedCount, baseSeed: baseSeed,
        coverageBudget: coverageBudget, samplingBudget: samplingBudget
    )
    registerEtnaRBTBenchmark(
        seedCount: seedCount, baseSeed: baseSeed,
        coverageBudget: coverageBudget, samplingBudget: samplingBudget
    )
    registerEtnaSTLCBenchmark(
        seedCount: seedCount, baseSeed: baseSeed,
        coverageBudget: coverageBudget, samplingBudget: samplingBudget
    )
}
