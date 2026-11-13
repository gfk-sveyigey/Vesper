@main
struct ImmersiveTitleStateChecks {
    static func main() {
        var state = ImmersiveTitleState()
        precondition(state.phase == .expanded)
        precondition(state.observe(offset: 47, isScrolling: true) == nil)
        let collapse = state.observe(offset: 49, isScrolling: true)!
        precondition(state.phase == .collapsing)
        precondition(state.observe(offset: 70, isScrolling: true) == nil)
        precondition(state.observe(offset: 60, isScrolling: false) == nil)
        state.complete(collapse)
        precondition(state.phase == .collapsed)
        precondition(state.observe(offset: 10, isScrolling: true) == nil)
        let expand = state.observe(offset: 2, isScrolling: true)!
        precondition(state.phase == .expanding)
        state.complete(collapse) // A stale completion must not override the new target.
        precondition(state.phase == .expanding)
        state.complete(expand)
        precondition(state.phase == .expanded)

        var layout = ImmersiveTitleState()
        precondition(layout.observe(offset: 100, isScrolling: false) == nil)
        precondition(layout.observe(offset: 80, isScrolling: true) == nil)
        let layoutCollapse = layout.observe(offset: 101, isScrolling: true)!
        let reverse = layout.observe(offset: -8, isScrolling: true)!
        precondition(layout.offset == 0)
        layout.complete(layoutCollapse)
        precondition(layout.phase == .expanding)
        layout.settle()
        layout.complete(reverse)
        precondition(layout.phase == .expanded)
        precondition(layout.observe(offset: .nan, isScrolling: true) == nil)
        precondition(layout.observe(offset: .infinity, isScrolling: true) == nil)
        precondition(layout.offset == 0)

        var disappearing = ImmersiveTitleState()
        let pending = disappearing.observe(offset: 50, isScrolling: true)!
        disappearing.settle()
        precondition(disappearing.phase == .collapsed)
        disappearing.complete(pending)
        precondition(disappearing.phase == .collapsed)
        precondition(layout.phase == .expanded) // Page instances remain independent.
        var shortScroll = ImmersiveTitleState()
        precondition(shortScroll.blurProgress == 0)
        precondition(shortScroll.observe(offset: 25, isScrolling: true) == nil)
        precondition(shortScroll.blurProgress == 0.5)
        let stop = shortScroll.observe(offset: 25, isScrolling: false, didStop: true)!
        precondition(shortScroll.phase == .collapsing)
        shortScroll.complete(stop)
        precondition(shortScroll.phase == .collapsed)
        precondition(shortScroll.observe(offset: 10, isScrolling: true) == nil)
        let top = shortScroll.observe(offset: 0, isScrolling: false)!
        shortScroll.complete(top)
        precondition(shortScroll.phase == .expanded && shortScroll.blurProgress == 0)
        precondition(shortScroll.observe(offset: 0, isScrolling: false, didStop: true) == nil)
        _ = shortScroll.observe(offset: 500, isScrolling: false)
        precondition(shortScroll.blurProgress == 1)
        print("Immersive title state checks passed")
    }
}
