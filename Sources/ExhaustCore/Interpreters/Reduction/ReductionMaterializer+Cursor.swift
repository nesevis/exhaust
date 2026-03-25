//
//  ReductionMaterializer+Cursor.swift
//  Exhaust
//
//  Created by Chris Kolbu on 25/3/2026.
//

// MARK: - Cursor

/// Position-based cursor that traverses the full ``ChoiceSequence`` including structural markers.
///
/// Group markers are transparently skipped. Sequence markers are handled explicitly.
/// Bind handling (skip/suspend/resume) is mode-dependent — callers decide whether to invoke them.
extension ReductionMaterializer {
    struct Cursor: ~Copyable {
        private let entries: ChoiceSequence
        private(set) var position: Int = 0
        var exhausted: Bool = false

        /// When > 0, the cursor is inside a bind's bound subtree and should
        /// behave as exhausted so the materializer falls back to PRNG.
        private var bindSuspendDepth: Int = 0

        /// Stack of position limits for nested scopes (zip children).
        /// Max nesting depth ~3-4 in practice.
        private var scopeLimits: [Int] = {
            var a = [Int]()
            a.reserveCapacity(4)
            return a
        }()

        /// Cached end position — updated on scope push/pop.
        private var effectiveEnd: Int

        static var empty: Cursor {
            Cursor(from: ChoiceSequence())
        }

        init(from sequence: consuming ChoiceSequence) {
            entries = sequence
            effectiveEnd = entries.count
        }

        // MARK: Scope management

        mutating func pushScope(limit: Int) {
            scopeLimits.append(limit)
            effectiveEnd = min(entries.count, limit)
        }

        mutating func popScope() {
            scopeLimits.removeLast()
            if let limit = scopeLimits.last {
                effectiveEnd = min(entries.count, limit)
            } else {
                effectiveEnd = entries.count
            }
        }

        // MARK: Skip transparent markers

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

        /// Advances past any trailing `.group(false)` and `.bind(false)` markers at the current
        /// position.
        ///
        /// Called in ``handleZip(_:continuation:inputValue:context:calleeFallback:continuationFallback:)``
        /// after each child's scope is popped, so that `childStartPosition` reflects the start of the
        /// next child's entries rather than the closing markers of the completed child. This prevents
        /// the next child's scope from being computed too tightly: without this call, a getSize-bind
        /// child (whose `.group(false)` close marker is left unconsumed) causes the following child
        /// to receive a scope that excludes its own value entry.
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

        // MARK: Bind support

        /// Returns the top-level element count of the sequence starting at the current cursor
        /// position, without advancing. Returns `nil` if the position does not hold a `.sequence(true)`
        /// marker (after skipping transparent markers).
        ///
        /// Called before ``skipBindBound()`` to capture array lengths that bind-bound skipping would
        /// otherwise discard from the prefix.
        func peekSequenceLength() -> Int? {
            var pos = position
            while pos < effectiveEnd {
                switch entries[pos] {
                case .group, .bind, .just:
                    pos &+= 1
                default:
                    guard case .sequence(true, _) = entries[pos] else { return nil }
                    return countTopLevelElements(from: pos &+ 1)
                }
            }
            return nil
        }

        /// Advance past the bound content of a `.bind` node.
        mutating func skipBindBound() {
            var depth = 0
            while position < effectiveEnd {
                switch entries[position] {
                case .bind(true):
                    depth &+= 1
                    position += 1
                case .bind(false):
                    if depth == 0 {
                        position &+= 1
                        return
                    }
                    depth &-= 1
                    position &+= 1
                default:
                    position &+= 1
                }
            }
        }

        private(set) var bindEncounterCount: Int = 0

        mutating func suspendForBind() {
            bindSuspendDepth &+= 1
            bindEncounterCount += 1
        }

        mutating func resumeAfterBind() {
            bindSuspendDepth &-= 1
        }

        var isSuspended: Bool {
            bindSuspendDepth > 0
        }

        // MARK: Consume entries

        mutating func tryConsumeValue() -> ChoiceSequenceValue.Value? {
            guard exhausted == false, isSuspended == false else { return nil }
            skipGroups()
            guard position < effectiveEnd else {
                exhausted = true
                return nil
            }
            switch entries[position] {
            case let .value(v), let .reduced(v):
                position &+= 1
                return v
            default:
                exhausted = true
                return nil
            }
        }

        mutating func tryConsumeBranch() -> ChoiceSequenceValue.Branch? {
            guard exhausted == false, isSuspended == false else { return nil }
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

        // MARK: Sequence markers

        mutating func tryConsumeSequenceOpen() -> (elementCount: Int, isLengthExplicit: Bool)? {
            guard exhausted == false, isSuspended == false else { return nil }
            skipGroups()
            guard position < effectiveEnd else {
                exhausted = true
                return nil
            }
            guard case let .sequence(true, isLengthExplicit: isExplicit) = entries[position] else {
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
            if case .sequence(false, _) = entries[position] {
                position &+= 1
            }
        }

        private func countTopLevelElements(from startPos: Int) -> Int? {
            var pos = startPos
            var depth = 0
            var count = 0

            while pos < entries.count {
                switch entries[pos] {
                case .sequence(false, _) where depth == 0:
                    return count
                case .group(true), .bind(true), .sequence(true, _):
                    if depth == 0 { count &+= 1 }
                    depth &+= 1
                case .group(false), .bind(false), .sequence(false, _):
                    depth -= 1
                case .value, .reduced, .just:
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
