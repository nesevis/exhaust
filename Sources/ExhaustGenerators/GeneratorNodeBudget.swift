import ExhaustCore

/// Computes minimum structural costs at each depth before splitting a node allowance. Depth decreases across derived-type edges, so even mutually recursive types have a finite analysis. Empty containers cost one node independently of their children.
final class GeneratorNodeBudget {
    let plan: GeneratorDerivationPlan
    private var costs: [CostKey: Int?] = [:]

    /// Structural minima depend only on type and depth, not the state space or the requested allowance.
    private struct CostKey: Hashable {
        let type: ObjectIdentifier
        let depth: Int
    }

    init(plan: GeneratorDerivationPlan) {
        self.plan = plan
    }

    /// Ignores this type's own annotation at the root so an explicit root argument can override it. Payload edges enforce the nested annotation before accepting a cost.
    func minimumNodes(for reference: ObjectIdentifier, depth: Int) -> Int? {
        guard depth >= 0 else {
            return nil
        }
        let key = CostKey(type: reference, depth: depth)
        if let cost = costs[key] {
            return cost
        }
        let type = plan.types[reference]!
        let minimum = type.constructors.compactMap { entry -> Int? in
            guard let children = minimumNodes(for: entry.payloads, depth: depth),
                  let subtotal = sumNodes(children)
            else {
                return nil
            }
            return sumNodes([1, subtotal])
        }.min()
        costs[key] = .some(minimum)
        return minimum
    }

    /// Returns one minimum per payload in declaration order, or `nil` when any payload is unconstructible at this depth. The caller needs the individual minima, not their sum, because splitting reserves each child's share separately.
    func minimumNodes(for payloads: [PayloadPlan], depth: Int) -> [Int]? {
        var result: [Int] = []
        for payload in payloads {
            guard let nodes = minimumNodes(for: payload, depth: depth) else {
                return nil
            }
            result.append(nodes)
        }
        return result
    }

    /// Charges one node for anything that is not another annotated type: a supplied generator, a built-in leaf, and a container all cost one regardless of their contents. A derived-type edge costs whatever that type costs at the remaining depth, and the child's own annotated ceiling rejects the cost rather than capping it.
    func minimumNodes(for payload: PayloadPlan, depth: Int) -> Int? {
        switch payload {
            case .supplied, .standard, .container:
                return 1
            case let .derivedType(reference):
                let child = plan.types[reference]!
                let remaining = child.maximumDepth.map { min($0, depth - 1) } ?? (depth - 1)
                guard let minimum = minimumNodes(for: reference, depth: remaining),
                      child.maximumNodes.map({ minimum <= $0 }) ?? true
                else {
                    return nil
                }
                return minimum
        }
    }

    /// Reserves every child's minimum before sharing the spare allowance evenly, then rounds each share down onto the grid ``quantisedAllowance(_:)`` defines. A remainder goes to earlier fields in declaration order. Supplied generators are opaque one-node leaves; their unused allowance is not spent elsewhere.
    func split(_ allowance: Int, minima: [Int]) -> [Int]? {
        guard let minimum = sumNodes(minima), minimum <= allowance else {
            return nil
        }
        guard minima.isEmpty == false else {
            return []
        }
        let spare = allowance - minimum
        let share = spare / minima.count
        let remainder = spare % minima.count
        return minima.enumerated().map { index, minimum in
            quantisedAllowance(minimum + share + (index < remainder ? 1 : 0), notBelow: minimum)
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

/// Rounds an allowance down onto a logarithmic grid, keeping five significant bits, but never below `minimum`.
///
/// Layers are cached by allowance, so without this a ceiling of 200 builds a distinct layer for almost every integer below it. Snapping nearby allowances together makes the layer count grow with the logarithm of the ceiling rather than with the ceiling. Five bits discards under 6% of an allowance; allowances below 32 are already on the grid and pass through.
///
/// Rounding down is what keeps the ceiling exact: nothing receives more than it was allotted, so a declared `maximumNodes` still bounds the value. The budget was already under-spent before this, because splitting among children and drawing a depth meant a ceiling of 200 produced values of about 99 nodes, and the grid takes that to about 95.
///
/// `minimum` is required rather than defaulted because rounding an allowance below what its recipient needs does not make the budget coarser, it makes it infeasible: the grid would turn a constructible request into a `nil` split or an empty layer set. The floor only raises the result back toward the unrounded allowance, never past it, so the caller's own ceiling still holds.
func quantisedAllowance(_ allowance: Int, notBelow minimum: Int) -> Int {
    let retainedBits = 5
    guard allowance >= (1 << retainedBits) else {
        return allowance
    }
    let magnitude = Int.bitWidth - 1 - allowance.leadingZeroBitCount
    let shift = magnitude - (retainedBits - 1)
    return Swift.max(minimum, (allowance >> shift) << shift)
}
