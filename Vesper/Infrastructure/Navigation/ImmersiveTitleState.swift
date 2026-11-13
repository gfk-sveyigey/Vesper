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
    let fadeDistance: Double
    let topTolerance: Double

    init(fadeDistance: Double = 48, topTolerance: Double = 2) {
        precondition(fadeDistance > topTolerance && topTolerance >= 0)
        self.fadeDistance = fadeDistance
        self.topTolerance = topTolerance
    }

    var isCollapsed: Bool {
        phase == .collapsing || phase == .collapsed
    }

    var fadeProgress: Double {
        min(1, max(0, (offset - topTolerance) / (fadeDistance - topTolerance)))
    }

    mutating func observe(offset newOffset: Double, didStop: Bool = false) -> Transition? {
        guard newOffset.isFinite else { return nil }
        offset = max(0, newOffset)
        if offset <= topTolerance, isCollapsed {
            return begin(isCollapsed: false)
        }
        // Geometry only drives fade and restoration. Collapse is exclusively
        // triggered when the scroll phase reaches idle, never during dragging.
        if didStop, offset > topTolerance, !isCollapsed {
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
