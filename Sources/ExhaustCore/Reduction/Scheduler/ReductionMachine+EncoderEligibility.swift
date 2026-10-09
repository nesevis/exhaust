extension ReductionMachine {
    /// Uses one eligibility rule for dispatch, manual probes, and excursion exploitation. Nil enables every encoder; an empty set enables none.
    func isEncoderEnabled(_ name: EncoderName) -> Bool {
        enabledEncoders?.contains(name) != false
    }

    /// Filters probe-producing actions before scheduling them. Releasing bind-inner deferral changes scheduling state without emitting a probe, so it remains eligible in restricted runs.
    func isPostCycleActionEnabled(_ action: ChoiceGraphScheduler.PostCycleAction) -> Bool {
        switch action {
            case .confirmConvergence:
                isEncoderEnabled(.convergenceConfirmation)
            case .relationPass:
                isEncoderEnabled(.relationSearch)
            case .improvingPivots:
                isEncoderEnabled(.branchPivot)
            case .stagedJointPass:
                isEncoderEnabled(.stagedJointSearch)
            case .excursion:
                isEncoderEnabled(.branchPivot) || isEncoderEnabled(.substitution)
            case .releaseDeferral:
                true
        }
    }
}
