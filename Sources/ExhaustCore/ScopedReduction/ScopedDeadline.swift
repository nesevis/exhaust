//
//  ScopedDeadline.swift
//  Exhaust
//

// MARK: - Deadline

/// A wall-clock budget the runner, the interpreter, and the improving pivot cursor check between units of work. It holds the clock it reads, so a caller can supply its own.
struct ScopedDeadline {
    private let start: UInt64
    private let budget: UInt64
    private let clock: () -> UInt64

    /// A deadline that never expires, for the final reorder pass.
    static var none: ScopedDeadline {
        ScopedDeadline(start: 0, budget: 0, clock: { 0 })
    }

    /// - Parameter budget: Nanoseconds after `start` at which the deadline expires. Zero never expires, and the clock is then never read.
    init(start: UInt64, budget: UInt64, clock: @escaping () -> UInt64) {
        self.start = start
        self.budget = budget
        self.clock = clock
    }

    var isExpired: Bool {
        guard budget > 0 else {
            return false
        }
        return clock() - start >= budget
    }
}
