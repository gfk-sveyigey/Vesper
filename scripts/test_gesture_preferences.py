#!/usr/bin/env python3
"""Exercise the production gesture preference model using Swift on the CI Mac.

The model has no UIKit dependencies. Its localized labels are plain strings in
this harness, allowing preference routing to run without launching an iOS app.
"""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / 'Vesper/Features/Player/PlayerInteraction.swift').read_text()
model = source[source.index('enum PlayerGestureRegion:'):source.index('/// Only the unobstructed video')]
checks = r'''
let defaults = UserDefaults.standard
let original = defaults.dictionaryRepresentation().filter { $0.key.hasPrefix("player.gesture.") }
defer {
    for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("player.gesture.") { defaults.removeObject(forKey: key) }
    for (key, value) in original { defaults.set(value, forKey: key) }
}
PlayerGesturePreferences.reset()
defaults.set(30.0, forKey: "player.gesture.skipSeconds")
assert(PlayerGesturePreferences.action(.doubleTap, .left, 1) == .backward)
assert(PlayerGesturePreferences.action(.doubleTap, .center, 1) == .playback)
assert(PlayerGesturePreferences.action(.doubleTap, .right, 1) == .forward)

// Different gestures simultaneously use different layouts and shared ratios.
defaults.set(false, forKey: "player.gesture.paired.1.vertical")
defaults.set(1, forKey: PlayerGesturePreferences.layoutKey(.tap, 1))
defaults.set(2, forKey: PlayerGesturePreferences.layoutKey(.up, 1))
defaults.set(3, forKey: PlayerGesturePreferences.layoutKey(.doubleTap, 1))
defaults.set(0.4, forKey: "player.gesture.split2")
assert(PlayerGesturePreferences.count(for: .tap, fingers: 1) == 1)
assert(PlayerGesturePreferences.region(at: CGPoint(x: 10, y: 0), width: 100, kind: .tap, fingers: 1) == .center)
assert(PlayerGesturePreferences.region(at: CGPoint(x: 39, y: 0), width: 100, kind: .up, fingers: 1) == .left)
assert(PlayerGesturePreferences.region(at: CGPoint(x: 41, y: 0), width: 100, kind: .up, fingers: 1) == .right)
assert(PlayerGesturePreferences.region(at: CGPoint(x: 50, y: 0), width: 100, kind: .doubleTap, fingers: 1) == .center)

// A pair shares its layout and action, and overrides rather than destroys
// each independent binding. One-finger and two-finger preferences stay isolated.
defaults.set(PlayerGestureAction.close.rawValue, forKey: PlayerGesturePreferences.key(.up, .left, 1))
defaults.set(true, forKey: "player.gesture.paired.1.vertical")
defaults.set(2, forKey: PlayerGesturePreferences.layoutKey(.up, 1))
defaults.set(PlayerGesturePairAction.volume.rawValue, forKey: PlayerGesturePreferences.pairKey(.vertical, .left, 1))
assert(PlayerGesturePreferences.layoutKey(.up, 1) == PlayerGesturePreferences.layoutKey(.down, 1))
assert(PlayerGesturePreferences.count(for: .down, fingers: 1) == 2)
assert(PlayerGesturePreferences.action(.up, .left, 1) == .volumeUp)
assert(PlayerGesturePreferences.action(.down, .left, 1) == .volumeDown)
assert(PlayerGesturePreferences.action(.up, .left, 2) == .none)
defaults.set(false, forKey: "player.gesture.paired.1.vertical")
assert(PlayerGesturePreferences.action(.up, .left, 1) == .close)
assert(PlayerGesturePreferences.count(for: .up, fingers: 1) == 2)

// Each supported opposite motion routes to the corresponding half of a pair.
for pair in PlayerGesturePair.allCases {
    defaults.set(true, forKey: "player.gesture.paired.2.\(pair.rawValue)")
    defaults.set(PlayerGesturePairAction.seek.rawValue, forKey: PlayerGesturePreferences.pairKey(pair, .center, 2))
    assert(PlayerGesturePreferences.action(pair.positive, .center, 2) == .forward)
    assert(PlayerGesturePreferences.action(pair.negative, .center, 2) == .backward)
}

// Corrupted boundaries cannot cross; restoring gestures keeps playback settings.
defaults.set(0.95, forKey: "player.gesture.split3.first")
defaults.set(0.1, forKey: "player.gesture.split3.second")
let edges = PlayerGesturePreferences.boundaries(for: 3)
assert(edges[0] >= 0.15 && edges[1] - edges[0] >= 0.149 && edges[1] <= 0.85)
PlayerGesturePreferences.reset()
assert(PlayerGesturePreferences.skipInterval == 30)
assert(PlayerGesturePreferences.pairEnabled(.vertical, 1))
assert(PlayerGesturePreferences.count(for: .tap, fingers: 1) == 3)
for pair in PlayerGesturePair.allCases { assert(PlayerGesturePreferences.pairEnabled(pair, 2)) }
assert(PlayerGesturePairAction.fill.action(positive: true) == .fillScreen)
assert(PlayerGesturePairAction.fill.action(positive: false) == .fitScreen)
assert(PlayerGesturePairAction.orientation.action(positive: true) == .landscape)
assert(PlayerGesturePairAction.orientation.action(positive: false) == .portrait)
print("Gesture preference regression checks passed.")
'''
with tempfile.TemporaryDirectory(prefix='vesper-gestures-') as directory:
    script = Path(directory) / 'main.swift'
    script.write_text('import Foundation\ntypealias LocalizedStringKey = String\n' + model + checks)
    subprocess.run(['swift', str(script)], check=True)
