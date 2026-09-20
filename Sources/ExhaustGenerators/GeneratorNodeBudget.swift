import ExhaustCore

/// Computes minimum structural costs before splitting a node allowance. Recursive fuel decreases only across edges inside a recursive type component, so mutually recursive types still have a finite analysis. Empty containers cost one node independently of their children.
final class GeneratorNodeBudget {
    let plan: GeneratorDerivationPlan
    private var costs: [CostKey: Int?] = [:]

    /// Structural minima depend only on type and recursive fuel, not the domain or requested node allowance.
    private struct CostKey: Hashable {
        let type: ObjectIdentifier
        let recursion: Int
    }

    init(plan: GeneratorDerivationPlan) {
        self.plan = plan
    }

    /// Ignores this type's own annotation at the root so explicit root settings can override it. Payload edges enforce nested budgets before accepting a cost.
    func minimumNodes(for reference: ObjectIdentifier, recursion: Int) -> Int? {
        guard recursion >= 0 else {
            return nil
        }
        let key = CostKey(type: reference, recursion: recursion)
        if let cost = costs[key] {
            return cost
        }
        let type = plan.plan(for: reference)
        let minimum = type.constructors.compactMap { entry -> Int? in
            guard let recursionAllowances = plan.recursionAllowances(
                for: entry.payloads,
                from: reference,
                budget: recursion
            ),
                let children = minimumNodes(
                    for: entry.payloads,
                    recursionAllowances: recursionAllowances
                ),
                let subtotal = sumNodes(children)
            else {
                return nil
            }
            return sumNodes([1, subtotal])
        }.min()
        costs[key] = .some(minimum)
        return minimum
    }

    /// Returns one minimum per payload in declaration order, or `nil` when any payload is unconstructible under its recursive allowance.
    func minimumNodes(
        for payloads: [PayloadPlan],
        recursionAllowances: [PayloadRecursionAllowance]
    ) -> [Int]? {
        var result: [Int] = []
        for (payload, recursionAllowance) in zip(payloads, recursionAllowances) {
            guard let nodes = minimumNodes(for: payload, recursionAllowance: recursionAllowance) else {
                return nil
            }
            result.append(nodes)
        }
        return result
    }

    /// Charges one node for anything that is not another annotated type. A derived edge costs its target's minimum under the selected recursive share and nested budget.
    func minimumNodes(
        for payload: PayloadPlan,
        recursionAllowance: PayloadRecursionAllowance
    ) -> Int? {
        switch payload {
            case .supplied, .standard, .container:
                return 1
            case let .derivedType(reference):
                let child = plan.plan(for: reference)
                let isRecursive = plan.isRecursiveEdge(
                    from: recursionAllowance.source,
                    to: reference
                )
                guard isRecursive == false || recursionAllowance.inherited > 0 else {
                    return nil
                }
                let selected = isRecursive
                    ? recursionAllowance.recursive
                    : recursionAllowance.inherited
                let recursion = min(selected, child.budget.recursion)
                guard let minimum = minimumNodes(for: reference, recursion: recursion),
                      minimum <= child.budget.nodes
                else {
                    return nil
                }
                return minimum
        }
    }

    /// Reserves every child's minimum before sharing the spare allowance evenly. For nonempty minima, the shares sum to the exact allowance; any remainder goes to earlier fields in declaration order. Supplied generators are opaque one-node leaves; their unused allowance is not spent elsewhere.
    func split(_ allowance: Int, minima: [Int]) -> [Int]? {
        guard let totalMinimum = sumNodes(minima), totalMinimum <= allowance else {
            return nil
        }
        guard minima.isEmpty == false else {
            return []
        }
        let spare = allowance - totalMinimum
        let share = spare / minima.count
        let remainder = spare % minima.count
        return minima.enumerated().map { index, minimum in
            minimum + share + (index < remainder ? 1 : 0)
        }
    }
}

// MARK: - Helpers

/// Treats an unrepresentable minimum as unavailable rather than wrapping a node count into a small, apparently feasible budget.
func sumNodes(_ values: [Int]) -> Int? {
    var total = 0
    for value in values {
        let (next, overflow) = total.addingReportingOverflow(value)
        guard overflow == false else {
            return nil
        }
        total = next
    }
    return total
}
