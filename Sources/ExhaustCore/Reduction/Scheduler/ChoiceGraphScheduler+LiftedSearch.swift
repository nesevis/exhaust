extension ChoiceGraphScheduler {
    /// Preserves guided branch resolution while the pivot's composition policy keeps mutation application on acceptance.
    static func makeBindPivotEncoder(gen: AnyGenerator) -> EncoderDispatch {
        .init(BindPivotSearch.makeEncoder(lift: guidedLift(generator: gen)))
    }

    /// Re-resolves out-of-range entries before exchange validates the sink against its proposal-specific expected value.
    static func makeBoundExchangeEncoder(gen: AnyGenerator) -> EncoderDispatch {
        .init(BoundExchangeSearch.makeEncoder(lift: guidedLift(generator: gen)))
    }

    private static func guidedLift(generator: AnyGenerator) -> GraphComposedEncoder.Lift {
        { candidate, fallbackTree in
            Materializer.guidedLift(generator: generator, prefix: candidate, fallbackTree: fallbackTree)
        }
    }
}
