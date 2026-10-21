import Exhaust

enum PropertyTestPhase: CaseIterable, Sendable {
    case screening
    case sampling

    func budget(iterations: Int) -> ExhaustBudget {
        switch self {
            case .screening: .custom(screening: iterations, sampling: 0)
            case .sampling: .custom(screening: 0, sampling: iterations)
        }
    }
}
