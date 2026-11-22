"""Exercise the production search repository and recursive local source search."""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SWIFTC = os.environ.get('SWIFTC') or shutil.which('swiftc')

class MediaSearchTests(unittest.TestCase):
    @unittest.skipUnless(SWIFTC, 'Swift compiler is required')
    def test_emby_search_pagination_and_query_encoding(self):
        subprocess.run([sys.executable, str(ROOT / 'BuildSupport/tests/run_emby_checks.py')],
                       cwd=ROOT, check=True)

    @unittest.skipUnless(SWIFTC and sys.platform == 'darwin', 'macOS Swift compiler is required for security-scoped files')
    def test_recursive_local_search_and_source_containment(self):
        with tempfile.TemporaryDirectory(prefix='vesper-local-search-') as folder:
            binary = str(Path(folder) / 'checks')
            subprocess.run([SWIFTC, '-swift-version', '6', '-strict-concurrency=complete',
                            str(ROOT / 'Vesper/Infrastructure/Theme/VesperLocalization.swift'),
                            str(ROOT / 'Vesper/Infrastructure/Sources/LocalFileStore.swift'),
                            str(ROOT / 'Tests/LocalFileStoreChecks.swift'), '-o', binary], check=True)
            subprocess.run([binary], check=True)
