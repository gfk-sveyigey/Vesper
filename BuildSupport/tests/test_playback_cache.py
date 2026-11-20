"""Exercise real Swift cache sizing and bitrate fallback code without UIKit."""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
SWIFTC = shutil.which(os.environ.get('SWIFTC', 'swiftc'))


@unittest.skipUnless(SWIFTC, 'Swift compiler is required')
class PlaybackCacheTests(unittest.TestCase):
    def test_budget_conversion_and_bitrate_fallbacks(self):
        contracts = (ROOT / 'Playback/Contracts/PlaybackContracts.swift').read_text()
        sizing = contracts[contracts.index('public enum PlaybackCacheSizing'):contracts.index('public struct EngineExternalSubtitle')]
        repository = (ROOT / 'Vesper/Infrastructure/Sources/EmbyIntegration.swift').read_text()
        bitrate = repository[repository.index('    static func playbackBitRate('):repository.index('    func transcodedResource(')]
        checks = (ROOT / 'Tests/EmbyRepositoryChecks.swift').read_text()
        assertions = checks[checks.index('    private static func checkPlaybackCacheSizing('):checks.index('    private static func checkSkipMarkers(')]
        source = ('import Foundation\n' + sizing + '\nenum EmbyRepository {\n' + bitrate
                  + '}\n@main struct Checks {\nstatic func main() { checkPlaybackCacheSizing() }\n'
                  + assertions + '}\n')
        with tempfile.TemporaryDirectory(prefix='vesper-cache-checks-') as directory:
            unit = Path(directory) / 'Checks.swift'
            binary = Path(directory) / 'checks'
            unit.write_text(source)
            subprocess.run([SWIFTC, '-swift-version', '6', '-parse-as-library', str(unit), '-o', str(binary)], check=True)
            subprocess.run([str(binary)], check=True)
