// What a thread-based run requires of a spec, checked where the mode is known.
//
// The mode is a `#execute` argument, so the macro cannot know which runner will receive a spec and cannot refuse a shape a particular runner cannot use. These checks run once, before any probe, and report at the call site that named the mode.
import ExhaustCore
import IssueReporting

/// Reports whether the spec can run under `mode: .threads`, emitting an error naming what is missing when it cannot.
///
/// Two things are required, and neither is expressible in the type system: an equivalence to judge by, and a reference-typed system under test for the lanes to share.
///
/// - Returns: `true` when the run may proceed.
func threadsModeIsUsable<Spec: StateMachineSpecBase>(
    _: Spec.Type,
    fileID: StaticString,
    filePath: StaticString,
    line: UInt,
    column: UInt
) -> Bool {
    var refusals: [String] = []

    // Without an equivalence a thread-based run has nothing to judge by: invariants are order-independent claims, and the whole point of this mode is the orders it realizes. There is no default worth inventing, because only the spec knows what "the same result" means for it.
    if Spec.hasEquivalence == false {
        refusals.append("mode: .threads requires an @Equivalence method, which defines what \"the same result\" means for a concurrent run. Add one, or use mode: .tasks, where invariants alone are enough.")
    }

    // Every lane reaches the system under test through one shared spec instance, so a value type is copied per access and defends nothing. The mode exists to test whether the system under test survives concurrent access, which a struct cannot be asked.
    if Spec.SystemUnderTest.self is AnyObject.Type == false {
        refusals.append("mode: .threads requires a reference-typed @SystemUnderTest, because every lane reaches it through one shared spec instance and a value type cannot defend itself. Make \(Spec.SystemUnderTest.self) a final class, or use mode: .sequential or mode: .tasks, where commands never overlap on it.")
    }

    guard refusals.isEmpty else {
        for refusal in refusals {
            reportError(refusal, fileID: fileID, filePath: filePath, line: line, column: column)
        }
        return false
    }
    return true
}
