/// Scroll observations trigger transitions; animation progress is owned by SwiftUI.
struct ImmersiveTitleState {
    enum Phase: Equatable {
        case expanded, collapsing, collapsed, expanding
    }

    struct Transition: Equatable {
        let generation: UInt64
        let isCollapsed: Bool
    }

    private(set) var phase: Phase = .expanded
    private(set) var offset: Double = 0
    private var generation: UInt64 = 0
    let collapseThreshold: Double
    let topTolerance: Double

    init(collapseThreshold: Double = 48, topTolerance: Double = 2) {
        precondition(collapseThreshold > topTolerance && topTolerance >= 0)
        self.collapseThreshold = collapseThreshold
        self.topTolerance = topTolerance
    }

    var isCollapsed: Bool {
        phase == .collapsing || phase == .collapsed
    }

    mutating func observe(offset newOffset: Double, isScrolling: Bool) -> Transition? {
        guard newOffset.isFinite else { return nil }
        let previousOffset = offset
        offset = max(0, newOffset)
        if offset <= topTolerance, isCollapsed {
            return begin(isCollapsed: false)
        }
        if isScrolling, offset >= collapseThreshold, offset > previousOffset, !isCollapsed {
            return begin(isCollapsed: true)
        }
        return nil
    }

    mutating func complete(_ transition: Transition) {
        guard transition.generation == generation else { return }
        phase = transition.isCollapsed ? .collapsed : .expanded
    }

    /// A disappearing page retains its target state and invalidates stale completions.
    mutating func settle() {
        generation += 1
        phase = isCollapsed ? .collapsed : .expanded
    }

    private mutating func begin(isCollapsed: Bool) -> Transition {
        generation += 1
        phase = isCollapsed ? .collapsing : .expanding
        return Transition(generation: generation, isCollapsed: isCollapsed)
    }
}
