@main
struct ImmersiveTitleStateChecks {
    static func main() {
        var state = ImmersiveTitleState()
        precondition(state.phase == .expanded && state.blurProgress == 0)
        // Geometry observations during dragging/deceleration never collapse,
        // including offsets far beyond the blur's saturation distance.
        for offset in [25.0, 49, 70, 500] {
            precondition(state.observe(offset: offset) == nil)
            precondition(state.phase == .expanded)
        }
        precondition(state.blurProgress == 1)
        let collapse = state.observe(offset: 500, didStop: true)!
        precondition(state.phase == .collapsing)
        precondition(state.observe(offset: 400, didStop: true) == nil)
        state.complete(collapse)
        precondition(state.phase == .collapsed)
        precondition(state.observe(offset: 10) == nil)
        let expand = state.observe(offset: 2)!
        precondition(state.phase == .expanding)
        state.complete(collapse)
        precondition(state.phase == .expanding)
        state.complete(expand)
        precondition(state.phase == .expanded && state.blurProgress == 0)

        var shortScroll = ImmersiveTitleState()
        precondition(shortScroll.observe(offset: 25) == nil)
        precondition(shortScroll.blurProgress == 0.5)
        let stop = shortScroll.observe(offset: 25, didStop: true)!
        shortScroll.complete(stop)
        precondition(shortScroll.phase == .collapsed)
        precondition(shortScroll.observe(offset: 10) == nil)
        let top = shortScroll.observe(offset: -8)!
        precondition(shortScroll.offset == 0)
        shortScroll.complete(top)
        precondition(shortScroll.phase == .expanded && shortScroll.blurProgress == 0)
        precondition(shortScroll.observe(offset: 0, didStop: true) == nil)

        var reversal = ImmersiveTitleState()
        let oldCollapse = reversal.observe(offset: 100, didStop: true)!
        let newExpand = reversal.observe(offset: 0)!
        reversal.complete(oldCollapse)
        precondition(reversal.phase == .expanding)
        reversal.settle()
        reversal.complete(newExpand)
        precondition(reversal.phase == .expanded)
        precondition(reversal.observe(offset: .nan, didStop: true) == nil)
        precondition(reversal.observe(offset: .infinity, didStop: true) == nil)
        precondition(reversal.offset == 0)

        var disappearing = ImmersiveTitleState()
        let pending = disappearing.observe(offset: 50, didStop: true)!
        disappearing.settle()
        disappearing.complete(pending)
        precondition(disappearing.phase == .collapsed)
        precondition(reversal.phase == .expanded) // Page instances are independent.
        print("Immersive title state checks passed")
    }
}
