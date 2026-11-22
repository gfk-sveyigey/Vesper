"""Exercise the shared speed sampler using its production Swift implementation."""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SWIFTC = shutil.which(os.environ.get('SWIFTC', 'swiftc'))


@unittest.skipUnless(SWIFTC, 'Swift compiler is required')
class DownloadSpeedTests(unittest.TestCase):
    def test_idle_smoothing_and_counter_lifecycle(self):
        contracts = (ROOT / 'Playback/Contracts/PlaybackContracts.swift').read_text()
        start = contracts.index('public struct EngineDownloadSample:')
        end = contracts.index('public struct MediaProbe:')
        source = contracts[start:end]
        checks = r'''
precondition(DownloadSpeedSampler.megabytesPerSecond(nil) == "—")
precondition(DownloadSpeedSampler.megabytesPerSecond(Double.nan) == "—")
precondition(DownloadSpeedSampler.megabytesPerSecond(-1) == "—")
precondition(DownloadSpeedSampler.megabytesPerSecond(1_500_000) == "1.50 MB/s")
var sampler = DownloadSpeedSampler()
func sample(_ bytes: Int64, _ id: String = "a") -> EngineDownloadSample {
    .init(counterID: id, bytes: bytes)
}
func expect(_ actual: Double?, _ expected: Double) {
    precondition(actual != nil && abs(actual! - expected) < 0.001)
}
precondition(sampler.update(sample(100), at: 0) == nil)
expect(sampler.update(sample(1_000_100), at: 1), 1_000_000)
expect(sampler.update(sample(1_000_100), at: 2), 500_000)
expect(sampler.update(sample(1_000_100), at: 3), 0)
expect(sampler.update(sample(2_000_100), at: 4), 1_000_000 / 3)
// The same byte count on another engine/route is a new baseline.
precondition(sampler.update(sample(1_000_100, "b"), at: 5) == nil)
expect(sampler.update(sample(2_000_100, "b"), at: 7), 500_000)
// Reconnect resets, unavailable counters, and background suspension must not spike.
precondition(sampler.update(sample(0, "b"), at: 8) == nil)
expect(sampler.update(sample(1_000_000, "b"), at: 9), 1_000_000)
precondition(sampler.update(nil, at: 10) == nil)
precondition(sampler.update(sample(8_000_000), at: 11) == nil)
precondition(sampler.update(sample(20_000_000), at: 20) == nil)
precondition(sampler.update(sample(21_000_000), at: 21) == nil)
precondition(sampler.update(sample(22_000_000), at: 22) == nil)
expect(sampler.update(sample(23_000_000), at: 23), 1_000_000)
precondition(sampler.update(sample(22_000_000), at: 23) == nil)
precondition(sampler.update(sample(-1), at: 24) == nil)
'''
        with tempfile.TemporaryDirectory(prefix='vesper-speed-checks-') as directory:
            unit = Path(directory) / 'Checks.swift'
            binary = Path(directory) / 'checks'
            unit.write_text('import Foundation\n' + source + '\n' + checks)
            subprocess.run([SWIFTC, '-swift-version', '6', str(unit), '-o', str(binary)], check=True)
            subprocess.run([str(binary)], check=True)
