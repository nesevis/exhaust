//
//  Gen+Backtrack.swift
//  Exhaust
//

package extension Gen {
    /// Selects among partial generators by weighted draw, retrying without replacement until one produces a value, and throws ``GeneratorError/backtrackExhausted`` when none does.
    ///
    /// Lowers to a `.pick` whose tuples carry ``ReflectiveOperation/PickTuple/isBacktrack``, wrapped in an `.isomorph` that unwraps `Output?` to `Output`. Only the winning arm is recorded, so the sequence is indistinguishable from a committed pick that happened to select it and every non-generation pass reads it as one. The unwrap throws rather than traps because a nil can reach it from any pass that executes forward transforms without auditioning: a recorded or pivoted arm that fails in the materializer, a covering-array row, a derivative sample.
    ///
    /// - Parameters:
    ///   - choices: Weighted arms, each of which may produce `nil` to withdraw. Weights must be positive.
    ///   - onExhausted: Fires before the throw so the public layer can report the call site.
    static func backtrack<Output>(
        always choices: [(weight: UInt64, generator: Generator<Output?>)],
        fileID: StaticString = #fileID,
        line: UInt = #line,
        column: UInt = #column,
        onExhausted: (() -> Void)? = nil
    ) -> Generator<Output> {
        let pick: Generator<Output?> = backtrackPick(
            choices,
            fingerprint: sourceFingerprint(fileID: fileID, line: line, column: column),
            isFailable: false,
            onExhausted: onExhausted
        )
        return liftF(.transform(
            kind: .isomorph(
                forward: { boxed in
                    // Inspected through the erased optional protocol rather than `as? Output?` so the unwrap also holds when `Output` is `Any`, where a conditional cast to `Any?` cannot tell a boxed nil from a boxed value.
                    guard isNilOptional(boxed) == false else {
                        throw GeneratorError.backtrackExhausted
                    }
                    return unwrapOptional(boxed)
                },
                backward: { value in
                    // Boxing the `.some` as `Any` hands the pick an `Output?` to match against, which is what its arms produce.
                    Output?.some(value as! Output) as Any
                },
                inputType: Output?.self,
                outputType: Output.self
            ),
            inner: pick.erase()
        ))
    }

    /// Selects among partial generators by weighted draw, retrying without replacement, and produces nil when every arm withdraws.
    ///
    /// Absence is recorded through a framework-built zero-weight `.just(nil)` arm appended after the user's arms (see ``ReflectiveOperation/PickTuple/isFailable``). It is built directly rather than through ``pick(choices:fileID:line:column:)`` because that constructor's positive-weight precondition is a user-facing guard; here zero weight is the mechanism that keeps the arm out of the draw.
    static func backtrack<Output>(
        failable choices: [(weight: UInt64, generator: Generator<Output?>)],
        fileID: StaticString = #fileID,
        line: UInt = #line,
        column: UInt = #column
    ) -> Generator<Output?> {
        backtrackPick(
            choices,
            fingerprint: sourceFingerprint(fileID: fileID, line: line, column: column),
            isFailable: true,
            onExhausted: nil
        )
    }

    private static func backtrackPick<Output>(
        _ choices: [(weight: UInt64, generator: Generator<Output?>)],
        fingerprint: UInt64,
        isFailable: Bool,
        onExhausted: (() -> Void)?
    ) -> Generator<Output?> {
        precondition(choices.isEmpty == false, "At least one backtrack arm must be provided")
        var tuples = ContiguousArray<ReflectiveOperation.PickTuple>()
        tuples.reserveCapacity(choices.count + 1)
        var totalWeight: UInt64 = 0
        for index in 0 ..< choices.count {
            let choice = choices[index]
            precondition(choice.weight > 0, "Backtrack arm weights must be greater than zero")
            let (sum, overflowed) = totalWeight.addingReportingOverflow(choice.weight)
            precondition(overflowed == false, "Backtrack arm weights sum overflows UInt64")
            totalWeight = sum
            tuples.append(ReflectiveOperation.PickTuple(
                fingerprint: fingerprint,
                id: UInt64(index),
                weight: choice.weight,
                generator: choice.generator.erase(),
                isBacktrack: true,
                isFailable: isFailable,
                onBacktrackExhausted: onExhausted
            ))
        }
        if isFailable {
            tuples.append(ReflectiveOperation.PickTuple(
                fingerprint: fingerprint,
                id: UInt64(choices.count),
                weight: 0,
                generator: Gen.just(Output?.none).erase(),
                isBacktrack: true,
                isFailable: true,
                onBacktrackExhausted: nil
            ))
        }
        return liftF(.pick(choices: tuples, totalWeight: totalWeight))
    }
}
