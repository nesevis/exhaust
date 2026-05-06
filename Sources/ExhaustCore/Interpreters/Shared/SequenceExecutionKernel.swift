//
//  SequenceExecutionKernel.swift
//  Exhaust
//

package enum SequenceExecutionKernel {
    public static func run(
        count: UInt64,
        step: () throws -> Bool
    ) throws -> Bool {
        var remaining = count
        while remaining > 0 {
            guard try step() else {
                return false
            }
            remaining -= 1
        }
        return true
    }

    public static func run<Script>(
        over scripts: [Script],
        step: (Script) throws -> Bool
    ) throws -> Bool {
        for script in scripts {
            guard try step(script) else {
                return false
            }
        }
        return true
    }
}
