extension ChoiceGraphScheduler {
    /// Preserves guided branch resolution while the pivot's composition policy keeps mutation application on acceptance.
    static func makeBindPivotEncoder(gen: AnyGenerator) -> EncoderDispatch {
        .composed(BindPivotSearch.makeEncoder(lift: guidedLift(generator: gen)))
    }

    private static func guidedLift(generator: AnyGenerator) -> GraphComposedEncoder.Lift {
        { candidate, fallbackTree in
            Materializer.guidedLift(generator: generator, prefix: candidate, fallbackTree: fallbackTree)
        }
    }
}
