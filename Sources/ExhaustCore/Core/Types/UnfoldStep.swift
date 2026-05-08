/// Represents the result of one step in a ``Gen/unfold(seed:maxDepth:step:fileID:line:column:)`` loop.
public enum UnfoldStep<State, Value> {
    /// Produces the final output and stops iterating.
    case done(Value)
    /// Continues with the given state for the next iteration.
    case recurse(State)
}
