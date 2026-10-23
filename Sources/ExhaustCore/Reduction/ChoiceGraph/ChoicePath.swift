//
//  ChoicePath.swift
//  Exhaust
//

// MARK: - Choice Path

/// A single descent step in a ``ChoicePath``.
///
/// Each step identifies which child of a ``ChoiceTree`` variant to descend into when walking from the tree root to a target node. Transparent variants (``ChoiceTree/branch``, getSize-inner ``ChoiceTree/bind``) do not consume a step — they are walked through without a path increment.
package enum ChoicePathStep: Equatable, Hashable, Sendable {
    /// Descend into the nth element of a ``ChoiceTree/sequence``.
    case sequenceChild(Int)

    /// Descend into the nth element of a regular (non-pick) ``ChoiceTree/group`` or ``ChoiceTree/resize``.
    case groupChild(Int)

    /// Descend into the active branch at a pick site with the given branch id.
    case pickBranch(UInt64)

    /// Descend into the inner child of a non-getSize ``ChoiceTree/bind``.
    case bindInner

    /// Descend into the bound child of a non-getSize ``ChoiceTree/bind``.
    case bindBound
}

/// A structural address from a ``ChoiceTree`` root to any node in the tree.
///
/// The same path addresses the same position while the shape above it remains unchanged, but it does not identify the position's occupant across tree versions. For example, deleting a sequence element moves later elements into earlier paths.
///
/// Cross-rebuild consumers use the path as the first component of a continuity check instead of relying on unstable node IDs. Each state category must add the guards its semantics require. Convergence transfer also checks the type tag and current bit pattern, except when the scheduler knows that an accepted value change made the old graph value stale without shifting the path.
///
/// Up to eight small steps fit in a word. Larger indices or deeper paths use the original array representation without truncation. All constructors choose the same representation for a given sequence of steps, so synthesized equality and hashing remain structural.
package struct ChoicePath: Sendable, Hashable {
    private enum Storage: Sendable, Hashable {
        case compact(UInt64)
        case expanded([ChoicePathStep])
    }

    private let storage: Storage

    private init(storage: Storage) {
        self.storage = storage
    }

    /// Packs common paths without allocating, materializing the accumulated steps only when a path exceeds the compact representation.
    package init(_ steps: some Sequence<ChoicePathStep>) {
        var bits: UInt64 = 0
        var expanded: [ChoicePathStep] = []
        for step in steps {
            if expanded.isEmpty, bits >> 56 == 0, let code = Self.code(for: step) {
                bits = (bits << 8) | code
            } else {
                if expanded.isEmpty {
                    let prefix = ChoicePath(storage: .compact(bits))
                    expanded.reserveCapacity(Swift.max(prefix.count + 1, steps.underestimatedCount))
                    prefix.appendSteps(to: &expanded)
                }
                expanded.append(step)
            }
        }
        storage = expanded.isEmpty ? .compact(bits) : .expanded(expanded)
    }

    /// Leaves the parent path unchanged and allocates no buffer while the appended step still fits in the compact representation.
    func appending(_ step: ChoicePathStep) -> ChoicePath {
        switch storage {
            case let .compact(bits):
                if bits >> 56 == 0, let code = Self.code(for: step) {
                    return ChoicePath(storage: .compact((bits << 8) | code))
                }
                var steps: [ChoicePathStep] = []
                steps.reserveCapacity(count + 1)
                appendSteps(to: &steps)
                steps.append(step)
                return ChoicePath(storage: .expanded(steps))
            case var .expanded(steps):
                steps.append(step)
                return ChoicePath(storage: .expanded(steps))
        }
    }

    // MARK: - Compact step layout

    // Each nonzero byte identifies one step: the top two bits select indexed step kinds and the bottom six hold their index. Codes one and two denote bind steps; zero is reserved for unused bytes.

    /// Returns nil for coordinates that require expanded storage, preserving their full range.
    private static func code(for step: ChoicePathStep) -> UInt64? {
        switch step {
            case .bindInner:
                return 1
            case .bindBound:
                return 2
            case let .sequenceChild(index):
                guard index >= 0, index < 64 else {
                    return nil
                }
                return 0x40 | UInt64(index)
            case let .groupChild(index):
                guard index >= 0, index < 64 else {
                    return nil
                }
                return 0x80 | UInt64(index)
            case let .pickBranch(branchID):
                guard branchID < 64 else {
                    return nil
                }
                return 0xC0 | branchID
        }
    }
}

package extension ChoicePath {
    var count: Int {
        switch storage {
            case let .compact(bits):
                (64 - bits.leadingZeroBitCount + 7) / 8
            case let .expanded(steps):
                steps.count
        }
    }

    var isEmpty: Bool {
        switch storage {
            case let .compact(bits):
                bits == 0
            case let .expanded(steps):
                steps.isEmpty
        }
    }

    /// Returns nil when traversal has consumed the path or the index is negative.
    func step(at index: Int) -> ChoicePathStep? {
        guard index >= 0, index < count else {
            return nil
        }
        switch storage {
            case let .compact(bits):
                return Self.step(for: (bits >> ((count - index - 1) * 8)) & 0xFF)
            case let .expanded(steps):
                return steps[index]
        }
    }

    /// Retains at most the requested number of leading steps, preserving canonical storage for equality and hashing.
    func prefix(_ maximumLength: Int) -> ChoicePath {
        precondition(maximumLength >= 0)
        guard maximumLength < count else {
            return self
        }
        guard maximumLength > 0 else {
            return []
        }
        switch storage {
            case let .compact(bits):
                return ChoicePath(storage: .compact(bits >> ((count - maximumLength) * 8)))
            case let .expanded(steps):
                return ChoicePath(steps.prefix(maximumLength))
        }
    }

    /// Removes leading steps without generic slicing; an expanded suffix is repacked when it fits the compact representation.
    func droppingFirst(_ count: Int) -> ChoicePath {
        precondition(count >= 0)
        guard count > 0 else {
            return self
        }
        let remaining = self.count - Swift.min(count, self.count)
        guard remaining > 0 else {
            return []
        }
        switch storage {
            case let .compact(bits):
                return ChoicePath(storage: .compact(bits & ((1 << (remaining * 8)) - 1)))
            case let .expanded(steps):
                return ChoicePath(steps.dropFirst(count))
        }
    }

    /// Expands compact storage into an array only for consumers that need an owned sequence of steps.
    func materialized() -> [ChoicePathStep] {
        if case let .expanded(steps) = storage {
            return steps
        }
        var steps: [ChoicePathStep] = []
        steps.reserveCapacity(count)
        appendSteps(to: &steps)
        return steps
    }

    /// Appends decoded steps into the caller's reserved buffer so expansion does not require an intermediate array.
    private func appendSteps(to result: inout [ChoicePathStep]) {
        switch storage {
            case let .compact(bits):
                let stepCount = count
                for index in 0 ..< stepCount {
                    result.append(Self.step(for: (bits >> ((stepCount - index - 1) * 8)) & 0xFF))
                }
            case let .expanded(steps):
                result.append(contentsOf: steps)
        }
    }

    /// Decodes one nonzero byte produced by the compact step encoding.
    private static func step(for code: UInt64) -> ChoicePathStep {
        switch code {
            case 1:
                return .bindInner
            case 2:
                return .bindBound
            default:
                let payload = code & 0x3F
                switch code & 0xC0 {
                    case 0x40:
                        return .sequenceChild(Int(payload))
                    case 0x80:
                        return .groupChild(Int(payload))
                    case 0xC0:
                        return .pickBranch(payload)
                    default:
                        preconditionFailure("Invalid compact path step")
                }
        }
    }
}

extension ChoicePath: ExpressibleByArrayLiteral {
    package init(arrayLiteral elements: ChoicePathStep...) {
        self.init(elements)
    }
}

extension ChoicePath: CustomStringConvertible {
    package var description: String {
        String(describing: materialized())
    }
}
