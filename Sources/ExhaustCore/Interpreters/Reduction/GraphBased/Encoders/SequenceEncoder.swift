/// Typed identifier for a sequence encoder.
public enum EncoderName: String, Hashable, Sendable {
    /// Removes elements from sequences. Tries batch removal (halving, quartering) first for large cuts, then falls back to per-element removal. Also handles cross-sequence aligned removal where corresponding elements in sibling sequences are deleted together.
    case deletion

    /// Moves elements between sequences to consolidate content. Shifts elements from earlier sequences into later ones, enabling further deletion of the now-shorter source sequences.
    case migration

    /// Drives each integer value toward its semantic simplest form (typically zero). Starts with batch zeroing, then per-leaf search that progresses through interpolation, binary, and linear phases as the remaining range narrows. A cross-zero phase for signed types walks shortlex key space downward. Tracks convergence floors to avoid re-searching settled values.
    case valueSearch
    
    /// Drives floating-point values toward zero using the IEEE 754 bit pattern ordering. Uses the same interpolation → binary → linear progression as integer search, applied to the exponent and significand independently. Handles special values (NaN, infinity, subnormals) and searches toward both positive and negative zero.
    case floatSearch
    
    /// Joint search over a bind-inner value and the parameters it controls. Composes an upstream search on the controlling value with a downstream search on the dependent subtree. Each upstream candidate triggers a full downstream exploration, so this encoder is deferred to stall cycles where cheaper encoders have failed.
    case boundValueSearch

    /// Shifts value between type-compatible parameters to find a simpler combination. When two parameters sum to a constant that the property depends on, redistribution searches for the split closest to zero on both sides.
    case redistribution

    /// Tries selecting a different branch at a pick site. Builds a candidate by replacing the selected branch content with a minimized version of an alternative branch, using the graph's position range to splice directly into the sequence.
    case branchPivot

    /// Replaces a subtree with a smaller one from the same recursive generator (self-similar substitution) or promotes a descendant pick to replace its ancestor (descendant promotion). Both use the graph's self-similarity groups to identify structurally exchangeable sites.
    case substitution

    /// Swaps adjacent sibling elements within a sequence to improve shortlex ordering. Tries each pair once and extends rightward on success. Produces cosmetic improvements that do not change the counterexample's meaning but make it easier to read.
    case siblingSwap

    /// Wraps an upstream and downstream encoder into a single composed search. The upstream encoder proposes a value for a controlling parameter, the result is materialized to produce a fresh scope for the downstream encoder, and the downstream searches the dependent parameters. Used as the inner mechanism for bound value search.
    case composed

    /// Searches pairs of values in tandem, moving them in coordinated steps. Used when two parameters are coupled and independent search on either one stalls — for example, an array and its expected length.
    case lockstep

    /// Reorders sibling elements into ascending numeric order. Runs as a final pass after all other reduction is complete. Produces the human-expected ordering (for example, `[0, 1, 2]` instead of `[2, 0, 1]`) without changing counterexample validity.
    case humanOrderReorder

    /// Probes each converged value one step below its floor to detect stale convergence. If a value that was previously stuck at some floor can now go lower (because other values changed around it), the floor was stale and reduction continues.
    case convergenceConfirmation
}
