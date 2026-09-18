/// Distinguishes top-level factors from factors inside one modeled sequence slot. Element scopes leave dependent binds and nested sequences opaque to bound the composite domain.
enum ScreeningScope {
    case root
    case element(Int)
}

/// Describes the parameter-bearing nodes and traversable edges shared by analysis and row reconstruction. Structural cases retain the information reconstruction needs to preserve the original tree.
enum ScreeningShape {
    case preserved
    case invalid
    case choice(ChoiceValue, ChoiceMetadata)
    case pick([ChoiceTree])
    case group([ChoiceTree], isZip: Bool)
    case singleton(BranchData, isZip: Bool)
    case resize(UInt64, [ChoiceTree])
    case bind(UInt64, inner: ChoiceTree, bound: ChoiceTree, visitsBound: Bool)
    case sequence([ChoiceTree], ChoiceMetadata)
}

extension ChoiceTree {
    /// Identifies bind inputs that screening keeps fixed, so their dependent choices can participate in the same covering array without changing shape between rows.
    ///
    /// Depth controls qualify because screening analysis pins them to their size-feasible upper bounds. This does not classify an ordinary sampled integer as a fixed context.
    var isScreeningContext: Bool {
        switch self {
            case .getSize, .just:
                true
            case let .choice(value, _):
                value.tag == .depthControl
            case .group, .bind, .sequence, .resize, .branch:
                false
        }
    }

    /// Classifies screening participation once for both model extraction and positional row substitution. Bare branches are invalid: only a recognized singleton pick exposes its payload.
    func screeningShape(in scope: ScreeningScope) -> ScreeningShape {
        switch self {
            case let .choice(value, metadata):
                guard metadata.isPinnedToSize == false, value.tag != .depthControl else { return .preserved }
                guard metadata.validRange != nil else { return .invalid }
                if case .root = scope, case .laneControl = value.tag { return .preserved }
                return .choice(value, metadata)
            case .just, .getSize, .group(_, isOpaque: true, _):
                return .preserved
            case let .group(children, _, isZip):
                let isPick = children.isEmpty == false
                    && children.contains(where: \.isSelected)
                    && children.allSatisfy { $0.isSelected || $0.isBranch }
                guard isPick else { return .group(children, isZip: isZip) }
                if children.count == 1, case let .branch(branch) = children[0], branch.branchCount == 1 {
                    return .singleton(branch, isZip: isZip)
                }
                return .pick(children)
            case let .resize(size, children):
                return .resize(size, children)
            case let .bind(fingerprint, inner, bound):
                let visitsBound = inner.isScreeningContext
                if case .element = scope, visitsBound == false { return .preserved }
                return .bind(fingerprint, inner: inner, bound: bound, visitsBound: visitsBound)
            case let .sequence(elements, metadata):
                guard metadata.validRange != nil else { return .invalid }
                if case .element = scope { return .preserved }
                return .sequence(elements, metadata)
            case .branch:
                return .invalid
        }
    }
}
