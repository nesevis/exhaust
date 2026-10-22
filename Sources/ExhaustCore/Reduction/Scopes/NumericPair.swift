/// Selects a source to simplify and a partner that may move in either direction to preserve the failure. Sampling and concrete edits belong to the search that receives the pair.
struct NumericPair: Equatable {
    let source: ReductionLeaf
    let sink: ReductionLeaf
}
