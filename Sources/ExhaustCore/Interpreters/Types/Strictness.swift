extension Interpreters {
    /// Controls how strictly the materializer enforces structural agreement between
    /// the choice sequence and the generator.
    public enum Strictness: Equatable {
        /// For reduction passes that have not changed the ``ChoiceTree`` structure.
        case normal
        /// For reduction passes that have changed the structure.
        case relaxed
    }
}
