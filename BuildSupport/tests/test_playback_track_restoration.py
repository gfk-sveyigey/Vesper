"""Run the real track matching and restoration state machine without the iOS SDK."""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SWIFTC = shutil.which(os.environ.get('SWIFTC', 'swiftc'))


@unittest.skipUnless(SWIFTC, 'Swift compiler is required')
class PlaybackTrackRestorationTests(unittest.TestCase):
    def test_switch_restore_override_and_ambiguous_tracks(self):
        contracts = (ROOT / 'Playback/Contracts/PlaybackContracts.swift').read_text()
        track = contracts.split('public struct EngineTrack', 1)[1].split('public struct EngineDiagnosticMetric', 1)[0]
        core = (ROOT / 'Vesper/Infrastructure/Playback/PlaybackCore.swift').read_text()
        state_machine = core.split('enum PlaybackTrackIntent', 1)[1].split('/// The UI talks', 1)[0]
        matcher = core.split('    private static func match(', 1)[1].split('    private func poll(', 1)[0]
        models = (ROOT / 'Vesper/Infrastructure/Sources/Adapters/Emby/EmbyMediaModels.swift').read_text()
        language = models.split('    static func normalized(', 1)[1].split('    static func matches(', 1)[0]
        script = '''
@main struct Checks {
    static func main() {
        let hans = EngineTrack(id: "old", name: "简体中文", language: "chi", codec: "subrip")
        let hant = EngineTrack(id: "old", name: "繁體中文", language: "zh-Hant", codec: "srt", selected: true)
        let target = EngineTrack(id: "new", name: "Chinese Simplified", language: "zh-CN", codec: "srt")
        let selected = EngineTrack(id: "new", name: target.name, language: target.language, codec: target.codec, selected: true)
        let intent = PlaybackTrackIntent.track(hans).carryingSelection(from: [hant])
        if case .track(let carried) = intent { assert(carried == hans) } else { assertionFailure() }

        var pending = PlaybackTrackRestoration()
        pending.begin(intent, now: 0)
        assert(pending.update(intent, tracks: [], now: 0, match: Match.match(_:in:)) == nil)
        assert(pending.status == .restoring)
        assert(pending.update(intent, tracks: [hant], now: 2, suppressUnmatchedTrack: true, match: Match.match(_:in:)) == .off)
        assert(pending.update(intent, tracks: [hant], now: 6, match: Match.match(_:in:)) == nil)
        assert(pending.status == .unavailable)
        assert(pending.update(intent, tracks: [hant, target], now: 7, match: Match.match(_:in:)) == .select("new"))
        assert(pending.update(intent, tracks: [hant, selected], now: 8, match: Match.match(_:in:)) == nil)
        assert(pending.status == .none)

        // A manual change on the new driver supersedes any pending recovery.
        let manualIntent = PlaybackTrackIntent.track(hant)
        pending.begin(manualIntent, now: 9, localID: hant.id)
        assert(pending.update(manualIntent, tracks: [selected], now: 9, match: Match.match(_:in:)) == nil)
        assert(pending.update(manualIntent, tracks: [target, hant], now: 10, match: Match.match(_:in:)) == nil)
        assert(pending.status == .none)

        let off = PlaybackTrackIntent.off.carryingSelection(from: [selected])
        pending.begin(off, now: 11)
        assert(pending.update(off, tracks: [], now: 11, match: Match.match(_:in:)) == .off)
        assert(pending.update(off, tracks: [selected], now: 13, match: Match.match(_:in:)) == .off)
        assert(pending.status == .none)

        let japanese = EngineTrack(id: "2", name: "Track 2", language: "ja", codec: "aac")
        let jpn = EngineTrack(id: "11", name: "Japanese", language: "jpn", codec: "mp4a")
        let english = EngineTrack(id: "2", name: "Track 2", language: "eng", codec: "aac", selected: true)
        let otherJapanese = EngineTrack(id: "12", name: "Japanese commentary", language: "jpn", codec: "aac")
        let audio = PlaybackTrackIntent.track(japanese)
        pending.begin(audio, now: 0)
        assert(pending.update(audio, tracks: [english], now: 1, match: Match.match(_:in:)) == nil)
        assert(pending.update(audio, tracks: [english, jpn], now: 2, match: Match.match(_:in:)) == .select("11"))
        assert(pending.update(audio, tracks: [english, jpn], now: 2.1, match: Match.match(_:in:)) == nil)
        assert(Match.match(japanese, in: [jpn, otherJapanese]) == nil)
        assert(Match.match(hans, in: [hant, EngineTrack(id: "generic", name: "Chinese", language: "zh")]) == nil)
        let surround = EngineTrack(id: "old", name: "Track 2 (aac)", language: "jpn", codec: "aac", channels: 6)
        let stereo = EngineTrack(id: "vlc-stereo", name: "Japanese", language: "ja", codec: "mp4a", channels: 2)
        let surroundMatch = EngineTrack(id: "vlc-surround", name: "Japanese", language: "ja", codec: "mp4a", channels: 6)
        assert(Match.match(surround, in: [stereo, surroundMatch]) == surroundMatch)
        let vlcSubtitle = EngineTrack(id: "vlc-sub", name: "Track 3", language: "chi", sourceTitle: "简体中文")
        assert(Match.match(vlcSubtitle, in: [hant, hans]) == hans)
    }
}
'''
        source = (
            'import Foundation\npublic struct EngineTrack' + track
            + 'enum PlaybackTrackIntent' + state_machine
            + 'enum EmbyTrackPreferences {\nstatic func normalized(' + language + '}\n'
            + 'enum Match {\nstatic func match(' + matcher + '}\n' + script
        )
        with tempfile.TemporaryDirectory(prefix='vesper-track-checks-') as directory:
            unit = Path(directory) / 'Checks.swift'
            executable = Path(directory) / 'checks'
            unit.write_text(source)
            subprocess.run([SWIFTC, '-swift-version', '6', '-parse-as-library', str(unit), '-o', str(executable)], check=True)
            subprocess.run([str(executable)], check=True)
