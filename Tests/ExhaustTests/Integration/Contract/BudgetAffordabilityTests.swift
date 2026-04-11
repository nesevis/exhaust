// Budget Affordability Contract Tests
//
// Requirements: https://gist.github.com/hwayne/e5a65b48ab50a2285de47cfc11fc955f
//
// A budget has a total spending limit and per-category limits. A bill is a list of items, each with a cost, an optional count multiplier (default 1), and an optional set of categories. An item's effective cost (cost times count) is always subtracted from the total limit. If the item shares one or more categories with the budget, its effective cost is also charged to exactly one of those matching categories. When multiple categories match, the function must choose the assignment that is as permissive as possible — it should return true whenever any valid assignment exists.
//
// The core algorithmic challenge is the category assignment problem: a greedy "pick the category with the most remaining capacity" heuristic can fail when an earlier item consumes capacity that a later, less flexible item needs. The correct implementation uses backtracking to explore all assignments.
//
// Two contracts are tested:
//
// 1. BudgetAffordabilitySpec — verifies that the backtracking `canAfford` agrees with an independent brute-force reference on every prefix of every generated bill. Also checks monotonicity: once a bill exceeds the budget, adding more items cannot make it affordable again.
//
// 2. BuggyBudgetAffordabilitySpec — demonstrates that a greedy assignment strategy (most-constrained-first, highest-capacity-category) disagrees with the brute-force reference. The framework finds and shrinks a minimal counterexample.

import Exhaust
import Testing

// MARK: - Tests

@Suite("Budget affordability contract tests")
struct BudgetAffordabilityTests {
    @Test("canAfford agrees with brute-force reference for all generated bills")
    func correctImplementation() {
        let result = #exhaust(
            BudgetAffordabilitySpec.self,
            .suppressIssueReporting
        )
        #expect(result == nil, "correct canAfford must agree with brute-force for all inputs")
    }

    @Test("Greedy canAfford disagrees with brute-force on optimal assignment")
    func greedyBugDetected() throws {
        let result = try #require(
            #exhaust(
                BuggyBudgetAffordabilitySpec.self,
                commandLimit: 8,
                .suppressIssueReporting
            )
        )
        #expect(result.trace.contains { step in
            if case .checkFailed = step.outcome { return true }
            return false
        })
    }
}

// MARK: - Contract: Correct implementation

@Contract
struct BudgetAffordabilitySpec {
    @Model var wasUnaffordable = false
    @SUT var items: [BillItem] = []

    @Invariant
    func monotonicity() -> Bool {
        // Once unaffordable, adding more items cannot make it affordable again.
        if wasUnaffordable {
            return canAfford(budget: testBudget, bill: items) == false
        }
        return true
    }

    @Command(weight: 3, .int(in: 1 ... 5), .int(in: 1 ... 2), .int(in: 0 ... 7))
    mutating func addItem(cost: Int, count: Int, categoryMask: Int) throws {
        items.append(BillItem(
            cost: cost,
            count: count,
            categories: categoriesFromMask(categoryMask)
        ))
        let affordable = canAfford(budget: testBudget, bill: items)
        let reference = bruteForceCanAfford(budget: testBudget, bill: items)
        try check(affordable == reference, "canAfford must agree with brute-force")
        if affordable == false {
            wasUnaffordable = true
        }
    }
}

// MARK: - Contract: Buggy greedy implementation

@Contract
struct BuggyBudgetAffordabilitySpec {
    @SUT var items: [BillItem] = []

    @Command(weight: 1, .int(in: 1 ... 5), .int(in: 1 ... 2), .int(in: 0 ... 7))
    mutating func addItem(cost: Int, count: Int, categoryMask: Int) throws {
        items.append(BillItem(
            cost: cost,
            count: count,
            categories: categoriesFromMask(categoryMask)
        ))
        try check(
            greedyCanAfford(budget: testBudget, bill: items)
                == bruteForceCanAfford(budget: testBudget, bill: items),
            "greedy canAfford must agree with brute-force"
        )
    }
}

// MARK: - Types

private let testBudget = Budget(
    totalLimit: 20,
    categoryLimits: ["a": 5, "b": 4, "c": 3]
)

struct Budget {
    let totalLimit: Int
    let categoryLimits: [String: Int]
}

struct BillItem {
    let cost: Int
    let count: Int
    let categories: [String]

    init(cost: Int, count: Int = 1, categories: [String] = []) {
        self.cost = cost
        self.count = count
        self.categories = categories
    }

    var effectiveCost: Int {
        cost * count
    }
}

// MARK: - Correct implementation (backtracking with pruning)

/// Determines whether a bill can be paid within the given budget constraints.
///
/// Each item's effective cost (cost times count) is subtracted from the budget's total limit. Items that share categories with the budget have their effective cost assigned to exactly one matching category. When multiple categories match, the function finds the most permissive assignment using backtracking.
///
/// - Returns: `true` if both the total limit and all category limits remain non-negative under an optimal category assignment.
func canAfford(budget: Budget, bill: [BillItem]) -> Bool {
    let totalCost = bill.reduce(0) { $0 + $1.effectiveCost }
    guard totalCost <= budget.totalLimit else { return false }

    let categorizedItems: [(cost: Int, categories: [String])] = bill.compactMap { item in
        let matching = item.categories.filter { budget.categoryLimits[$0] != nil }
        guard matching.isEmpty == false else { return nil }
        return (item.effectiveCost, matching)
    }
    guard categorizedItems.isEmpty == false else { return true }

    var remainingLimits = budget.categoryLimits
    return backtrackAssignment(categorizedItems, index: 0, limits: &remainingLimits)
}

// MARK: - Brute-force reference (exhaustive enumeration)

/// Reference implementation that tries every possible category assignment without pruning.
///
/// Feasibility is checked only at the leaves of the search tree, making this structurally different from the backtracking version. Serves as an independent oracle for correctness testing.
func bruteForceCanAfford(budget: Budget, bill: [BillItem]) -> Bool {
    let totalCost = bill.reduce(0) { $0 + $1.effectiveCost }
    guard totalCost <= budget.totalLimit else { return false }

    let categorizedItems: [(cost: Int, categories: [String])] = bill.compactMap { item in
        let matching = item.categories.filter { budget.categoryLimits[$0] != nil }
        guard matching.isEmpty == false else { return nil }
        return (item.effectiveCost, matching)
    }
    guard categorizedItems.isEmpty == false else { return true }

    var totals: [String: Int] = [:]
    return enumerateAssignments(
        categorizedItems,
        index: 0,
        totals: &totals,
        limits: budget.categoryLimits
    )
}

// MARK: - Buggy greedy implementation

/// A greedy implementation that assigns each item to the category with the most remaining capacity, processing the most-constrained items first.
///
/// This heuristic fails when an earlier item consumes capacity in a high-capacity category that a later, less flexible item needs. For example, with limits a=5 and b=4, assigning a cost-3 item to "a" (more capacity) before a cost-5 item that can only fit in "a" makes the bill look unaffordable when it is not.
func greedyCanAfford(budget: Budget, bill: [BillItem]) -> Bool {
    let totalCost = bill.reduce(0) { $0 + $1.effectiveCost }
    guard totalCost <= budget.totalLimit else { return false }

    var remainingLimits = budget.categoryLimits

    let categorizedItems: [(cost: Int, categories: [String])] = bill
        .compactMap { item in
            let matching = item.categories.filter { budget.categoryLimits[$0] != nil }
            guard matching.isEmpty == false else { return nil }
            return (item.effectiveCost, matching)
        }
        .sorted { $0.categories.count < $1.categories.count }

    for (cost, categories) in categorizedItems {
        guard let bestCategory = categories
            .max(by: { (remainingLimits[$0] ?? 0) < (remainingLimits[$1] ?? 0) }),
            let remaining = remainingLimits[bestCategory],
            remaining >= cost
        else {
            return false
        }
        remainingLimits[bestCategory] = remaining - cost
    }
    return true
}

// MARK: - Helpers

private func backtrackAssignment(
    _ items: [(cost: Int, categories: [String])],
    index: Int,
    limits: inout [String: Int]
) -> Bool {
    guard index < items.count else { return true }
    let (cost, categories) = items[index]
    for category in categories {
        guard let remaining = limits[category], remaining >= cost else { continue }
        limits[category] = remaining - cost
        if backtrackAssignment(items, index: index + 1, limits: &limits) {
            return true
        }
        limits[category] = remaining
    }
    return false
}

private func enumerateAssignments(
    _ items: [(cost: Int, categories: [String])],
    index: Int,
    totals: inout [String: Int],
    limits: [String: Int]
) -> Bool {
    guard index < items.count else {
        return totals.allSatisfy { category, total in
            total <= (limits[category] ?? 0)
        }
    }
    let (cost, categories) = items[index]
    for category in categories {
        totals[category, default: 0] += cost
        if enumerateAssignments(items, index: index + 1, totals: &totals, limits: limits) {
            return true
        }
        totals[category, default: 0] -= cost
    }
    return false
}

private func categoriesFromMask(_ mask: Int) -> [String] {
    var result: [String] = []
    if (mask & 1) != 0 { result.append("a") }
    if (mask & 2) != 0 { result.append("b") }
    if (mask & 4) != 0 { result.append("c") }
    return result
}
