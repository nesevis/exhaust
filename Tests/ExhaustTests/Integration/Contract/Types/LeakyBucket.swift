/// Deliberately unsynchronized — @unchecked Sendable is required because the cooperative scheduler accesses the instance from multiple Tasks via SendableBox.
final class LeakyBucket: @unchecked Sendable {
    private var _tokens: Int = 0
    private let _capacity: Int

    init(capacity: Int) {
        _capacity = capacity
    }

    var tokens: Int {
        _tokens
    }

    func refill() async {
        guard _tokens < _capacity else { return }
        _tokens += 1
    }

    func tryConsume() async {
        let current = _tokens
        guard current > 0 else { return }
        await Task.yield()
        _tokens = current - 1
    }
}
