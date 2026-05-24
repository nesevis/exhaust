//
//  Materializer+Cursor.swift
//  Exhaust
//
//  Created by Chris Kolbu on 25/3/2026.
//

// MARK: - Cursor

/// Position-based cursor that traverses the full ``ChoiceSequence`` including structural markers.
///
/// Group markers are transparently skipped. Sequence markers are handled explicitly.
/// Bind handling (skip/suspend/resume) is mode-dependent — callers decide whether to invoke them.
extension Materializer {
    struct Cursor: ~Copyable {
        private let entries: ChoiceSequence
        private(set) var position: Int = 0
        var exhausted: Bool = false

        /// Fixed-capacity stack of position limits for nested scopes (zip children).
        /// Max nesting depth is 4 in practice. Inline storage avoids heap allocation; overflow spills to an array.
        private var scopeLimits: (Int, Int, Int, Int) = (0, 0, 0, 0)
        private var scopeOverflow: [Int]?
        private var scopeDepth: Int = 0

        /// Cached end position — updated on scope push/pop.
        private var effectiveEnd: Int

        static var empty: Cursor {
            Cursor(from: ChoiceSequence())
        }

        init(from sequence: consuming ChoiceSequence) {
            entries = sequence
            effectiveEnd = entries.count
        }

        // MARK: - Scope management

        mutating func pushScope(limit: Int) {
            switch scopeDepth {
                case 0: scopeLimits.0 = limit
                case 1: scopeLimits.1 = limit
                case 2: scopeLimits.2 = limit
                case 3: scopeLimits.3 = limit
                default:
                    if scopeOverflow == nil { scopeOverflow = [] }
                    scopeOverflow!.append(limit)
            }
            scopeDepth &+= 1
            effectiveEnd = min(entries.count, limit)
        }

        mutating func popScope() {
            scopeDepth &-= 1
            if scopeDepth >= 4 {
                guard scopeOverflow?.isEmpty == false else {
                    preconditionFailure("popScope: scopeOverflow is empty at depth \(scopeDepth + 1)")
                }
                scopeOverflow!.removeLast()
                let limit = scopeOverflow!.isEmpty
                    ? scopeLimits.3
                    : scopeOverflow!.last!
                effectiveEnd = min(entries.count, limit)
            } else if scopeDepth > 0 {
                let limit = switch scopeDepth {
                    case 1: scopeLimits.0
                    case 2: scopeLimits.1
                    case 3: scopeLimits.2
                    default: scopeLimits.3
                }
                effectiveEnd = min(entries.count, limit)
            } else {
                effectiveEnd = entries.count
            }
        }

        // MARK: - Skip transparent markers

        /// Advances past group-open, bind-open, and just markers to the first content node (value, branch, or sequence marker). Called before consuming an entry so that transparent structural wrappers do not block the cursor.
        mutating func skipGroups() {
            while position < effectiveEnd {
                switch entries[position] {
                    case .group, .bind, .just:
                        position &+= 1
                    default:
                        return
                }
            }
        }

        /// Advances past any trailing `.group(false)` and `.bind(false)` markers at the current position.
        ///
        /// Called in ``handleZip(_:continuation:inputValue:context:calleeFallback:continuationFallback:)`` after each child's scope is popped, so that `childStartPosition` reflects the start of the next child's entries rather than the closing markers of the completed child. This prevents the next child's scope from being computed too tightly: without this call, a getSize-bind child (whose `.group(false)` close marker is left unconsumed) causes the following child to receive a scope that excludes its own value entry.
        mutating func skipGroupCloses() {
            while position < effectiveEnd {
                switch entries[position] {
                    case .group(false), .bind(false):
                        position &+= 1
                    default:
                        return
                }
            }
        }

        // MARK: - Consume entries

        /// Reads and returns the next value entry from the cursor, or nil if the cursor is exhausted or the next non-marker entry is not a value. Marks the cursor as exhausted on type mismatch so callers fall through to PRNG generation.
        mutating func tryConsumeValue() -> ChoiceSequenceValue.Value? {
            guard exhausted == false else { return nil }
            skipGroups()
            guard position < effectiveEnd else {
                exhausted = true
                return nil
            }
            switch entries[position] {
                case let .value(v):
                    position &+= 1
                    return v
                default:
                    exhausted = true
                    return nil
            }
        }

        /// Reads and returns the next branch-selection entry from the cursor, or nil if the cursor is exhausted or the next non-marker entry is not a branch. Marks the cursor as exhausted on type mismatch.
        mutating func tryConsumeBranch() -> ChoiceSequenceValue.Branch? {
            guard exhausted == false else { return nil }
            skipGroups()
            guard position < effectiveEnd else {
                exhausted = true
                return nil
            }
            switch entries[position] {
                case let .branch(b):
                    position &+= 1
                    return b
                default:
                    exhausted = true
                    return nil
            }
        }

        // MARK: - Sequence markers

        /// Reads the sequence-open marker and extracts the element count by scanning forward for top-level entries until the matching sequence-close. Returns nil and marks the cursor as exhausted if the next entry is not a sequence-open marker.
        mutating func tryConsumeSequenceOpen() -> (elementCount: Int, isLengthExplicit: Bool)? {
            guard exhausted == false else { return nil }
            skipGroups()
            guard position < effectiveEnd else {
                exhausted = true
                return nil
            }
            guard case let .sequence(true, validRange: _, isLengthExplicit: isExplicit) = entries[position] else {
                exhausted = true
                return nil
            }
            position &+= 1

            guard let count = countTopLevelElements(from: position) else {
                exhausted = true
                return nil
            }
            return (elementCount: count, isLengthExplicit: isExplicit)
        }

        mutating func skipSequenceClose() {
            guard exhausted == false else { return }
            skipGroups()
            guard position < effectiveEnd else { return }
            if case .sequence(false, _, _) = entries[position] {
                position &+= 1
            }
        }

        private func countTopLevelElements(from startPos: Int) -> Int? {
            var pos = startPos
            var depth = 0
            var count = 0

            while pos < entries.count {
                switch entries[pos] {
                    case .sequence(false, _, _) where depth == 0:
                        return count
                    case .group(true), .bind(true), .sequence(true, _, _):
                        if depth == 0 { count &+= 1 }
                        depth &+= 1
                    case .group(false), .bind(false), .sequence(false, _, _):
                        depth -= 1
                    case .value, .just:
                        if depth == 0 { count &+= 1 }
                    case .branch:
                        break
                }
                pos &+= 1
            }
            return nil
        }
    }
}
