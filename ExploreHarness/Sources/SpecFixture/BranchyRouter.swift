// The rich-coverage-surface archetype and spec-path positive control (matrix fixture MX1f, "BranchyRouter"): a 16-opcode dispatcher with real per-handler branching, so spec verdicts stop being conditioned on flat 22-edge surfaces, plateau-sensitive mechanisms get wall time on at least one spec shape, and the matrix contains one spec fixture proving guided search works when a ladder legitimately exists.
//
// ## Shape Coordinates
//
// Trigger class: mode-gated opcode sequence, deliberately gradient-reachable (the complement of the latch). Coverage surface: rich — 16 handlers, each branching on operand ranges, mode, and register parity; the instrumented-edge target is the hundreds (measured count recorded in the registry table). Vocabulary: one command with a wide two-argument domain (opcode 0...15, operand 0...9). Length scale: minimal trigger is 4 commands, far inside the limit.
//
// ## Ground-Truth Registry
//
// Fault B (armed two-opcode sequence):
//     Trigger: in armed mode (2), a route(12, _) immediately followed by route(5, _). Mode climbs through the branch structure: route(3, operand >= 7) elevates mode 0 to 1; route(9, operand >= 5) in mode 1 arms mode 2; route(0, _) resets the mode and the pair progress at any point.
//     Trigger variable: mode, plus lastOpcode for the consecutive pair.
//     Minimal: [route(3, 7), route(9, 5), route(12, 0), route(5, 0)].
//     Effect: throws BranchyRouterError.corruption.
//
// Single planted fault. Every mode transition and the arming opcode light distinct edges, and every handler branches on `mode > 0`, so each stage of the trigger opens fresh coverage — the ladder is legitimate, not a hit-count artifact.
//
// ## Blind Rate
//
// Monte Carlo over uniform spec-shaped sequences (lengths 0...40): fault B fires in ~0.14% of attempts blind — reliably found at benchmark attempt rates with or without guidance, which is the point: the router is the positive control and the plateau-avoidance surface, not a differential. Each trigger stage admits a corpus entry, so the fixture also demonstrates a legitimate ladder end to end.
//
// Pinned baseline (MX1g, 2026-07-12, seeds 1-20, 10 s, defaults, .commandLimit(40)): 20/20; 142 edges covered at 10 s — the fixture's full reachable surface, in the low hundreds as targeted.

/// A command router dispatching sixteen opcodes through mode-aware handlers; the planted fault needs an armed mode and a consecutive opcode pair.
public struct BranchyRouter: Sendable {
    /// The mode ladder: 0 normal, 1 elevated, 2 armed. Exposed for smoke tests and failure reports.
    public private(set) var mode = 0

    // Working registers the handlers mix; their parity feeds per-handler branches.
    private var alpha = 0
    private var beta = 0

    /// Fault B trigger companion: the opcode of the immediately preceding route call.
    private var lastOpcode = -1

    public init() {}

    /// The register pair, exposed for failure reports.
    public var registers: (alpha: Int, beta: Int) {
        (alpha: alpha, beta: beta)
    }

    // MARK: - Command

    public mutating func route(opcode: Int, operand: Int) throws {
        // Fault B: the consecutive pair, checked before dispatch so the pair is exactly adjacent route calls.
        if mode == 2, lastOpcode == 12, opcode == 5 {
            throw BranchyRouterError.corruption
        }
        let previousOpcode = lastOpcode
        lastOpcode = opcode
        switch opcode {
            case 0: handleReset(operand)
            case 1: handleAdd(operand)
            case 2: handleXor(operand)
            case 3: handleElevate(operand)
            case 4: handleScale(operand)
            case 5: handleSwap(operand)
            case 6: handleClamp(operand)
            case 7: handleMirror(operand)
            case 8: handleShift(operand)
            case 9: handleArm(operand)
            case 10: handleBlend(operand)
            case 11: handleCount(operand)
            case 12: handleStage(operand, previousOpcode: previousOpcode)
            case 13: handleRotate(operand)
            case 14: handleFold(operand)
            default: handleDrain(operand)
        }
    }

    // MARK: - Handlers

    private mutating func handleReset(_ operand: Int) {
        // The hostile opcode: drops the mode ladder and the pair progress.
        mode = 0
        lastOpcode = -1
        if operand >= 5 {
            alpha = 0
            beta = 0
        } else if operand >= 2 {
            alpha = operand
        } else {
            beta = operand
        }
    }

    private mutating func handleAdd(_ operand: Int) {
        if operand >= 7 {
            alpha += operand * 2
        } else if operand >= 3 {
            alpha += operand
        } else {
            beta += operand
        }
        if mode > 0 {
            beta += 1
        }
        if alpha & 1 == 1 {
            beta ^= 3
        }
    }

    private mutating func handleXor(_ operand: Int) {
        if operand >= 6 {
            alpha ^= operand << 1
        } else if operand >= 2 {
            beta ^= operand
        } else {
            alpha ^= 1
        }
        if mode > 0, beta & 1 == 0 {
            alpha += 2
        }
    }

    private mutating func handleElevate(_ operand: Int) {
        // Mode rung 1: a distinct edge lights on the elevation itself.
        if mode == 0, operand >= 7 {
            mode = 1
            alpha += 16
            return
        }
        if operand >= 4 {
            beta += operand
        } else {
            alpha -= operand
        }
    }

    private mutating func handleScale(_ operand: Int) {
        if operand >= 8 {
            alpha *= 2
        } else if operand >= 4 {
            beta *= 2
        } else if operand >= 1 {
            alpha += beta
        } else {
            beta = alpha
        }
        if mode > 0, alpha > 64 {
            alpha /= 2
        }
    }

    private mutating func handleSwap(_ operand: Int) {
        if operand & 1 == 1 {
            let held = alpha
            alpha = beta
            beta = held
        } else if operand >= 6 {
            alpha = beta - alpha
        } else {
            beta = alpha - beta
        }
        if mode == 2 {
            beta += 5
        }
    }

    private mutating func handleClamp(_ operand: Int) {
        if alpha > operand * 10 {
            alpha = operand * 10
        } else if alpha < -operand {
            alpha = -operand
        }
        if mode > 0, operand >= 5 {
            beta = min(beta, 100)
        }
    }

    private mutating func handleMirror(_ operand: Int) {
        if operand >= 7 {
            alpha = -alpha
        } else if operand >= 3 {
            beta = -beta
        } else {
            alpha = -beta
        }
        if alpha < 0, beta < 0 {
            mode = min(mode, 1)
        }
    }

    private mutating func handleShift(_ operand: Int) {
        if operand >= 6 {
            alpha <<= 1
        } else if operand >= 2 {
            alpha >>= 1
        } else {
            beta <<= 1
        }
        if mode > 0, beta > 32 {
            beta >>= 2
        }
    }

    private mutating func handleArm(_ operand: Int) {
        // Mode rung 2: arming from elevated lights its own edge.
        if mode == 1, operand >= 5 {
            mode = 2
            beta += 32
            return
        }
        if mode == 2, operand < 2 {
            // A soft de-arm path: armed mode survives only away from tiny operands.
            mode = 1
            return
        }
        if operand >= 5 {
            alpha += 3
        } else {
            beta -= 1
        }
    }

    private mutating func handleBlend(_ operand: Int) {
        if operand >= 5 {
            alpha = (alpha + beta) / 2
        } else if operand >= 1 {
            beta = (alpha * 3 + beta) / 4
        } else {
            alpha += 1
        }
        if mode > 0, alpha == beta {
            beta += 7
        }
    }

    private mutating func handleCount(_ operand: Int) {
        if operand >= 8 {
            alpha += 10
        } else if operand >= 5 {
            alpha += 5
        } else if operand >= 2 {
            alpha += 2
        } else {
            alpha += 1
        }
        if mode == 2, alpha & 1 == 1 {
            beta ^= 1
        }
    }

    private mutating func handleStage(_ operand: Int, previousOpcode: Int) {
        // The arming half of the fault pair: staging in armed mode lights a distinct edge, so the pair's first half is corpus-visible.
        if mode == 2 {
            alpha += 64
            if previousOpcode == 12 {
                beta += 64
            }
            return
        }
        if operand >= 5 {
            beta += operand
        } else {
            alpha -= 1
        }
    }

    private mutating func handleRotate(_ operand: Int) {
        if operand >= 6 {
            let held = alpha
            alpha = beta
            beta = -held
        } else if operand >= 3 {
            alpha = (alpha << 1) | (alpha & 1)
        } else {
            beta = (beta >> 1) ^ operand
        }
        if mode > 0, alpha & 3 == 0 {
            alpha += operand
        }
    }

    private mutating func handleFold(_ operand: Int) {
        if operand >= 7 {
            alpha = alpha % 17
        } else if operand >= 4 {
            beta = beta % 13
        } else if operand >= 1 {
            alpha = (alpha + operand) % 29
        } else {
            beta = 0
        }
        if mode > 0, beta & 1 == 1 {
            alpha ^= 5
        }
    }

    private mutating func handleDrain(_ operand: Int) {
        if operand >= 5 {
            alpha -= operand
        } else if operand >= 2 {
            beta -= operand
        } else {
            alpha -= 1
            beta -= 1
        }
        if mode == 1, operand == 0 {
            mode = 0
        }
    }
}

public enum BranchyRouterError: Error, Equatable, Sendable {
    case corruption
}
