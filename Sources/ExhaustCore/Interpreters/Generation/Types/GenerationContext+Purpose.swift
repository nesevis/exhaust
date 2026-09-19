package extension GenerationContext {
    /// Distinguishes ordinary generation from discovery of the choice-tree template used by screening. Row materialization is a separate interpreter pass, not a generation purpose.
    enum Purpose: Equatable, Sendable {
        /// Retains ordinary random depth draws and pick/bind materialization behavior.
        case sampling

        /// Pins depth controls without drawing randomness. When pick metadata is requested, records alternatives without expanding unselected payloads and retains that metadata through fixed-context binds.
        case screeningAnalysis
    }
}
