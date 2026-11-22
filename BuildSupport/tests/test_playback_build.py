"""Portable regression tests for the final-product isolation gate.

These exercise audit decisions with synthetic tool output. They do not replace
running otool/nm on a real iOS product.
"""
import importlib.util
from pathlib import Path
import plistlib
import tempfile
import unittest
from unittest.mock import patch


SUPPORT = Path(__file__).resolve().parents[1]


def module(name):
    spec = importlib.util.spec_from_file_location(name, SUPPORT / (name + '.py'))
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


audit = module('audit_playback_isolation')
embed = module('embed_playback_dependencies')


def bundle(path, name):
    path.mkdir(parents=True, exist_ok=True)
    (path / 'Info.plist').write_bytes(plistlib.dumps({'CFBundleExecutable': name}))
    (path / name).write_bytes(b'synthetic fixture, not Mach-O')


class IsolationGateTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.app = self.root / 'Vesper.app'
        bundle(self.app, 'Vesper')
        for name in [*audit.BRIDGES, 'AetherLibavformat']:
            bundle(self.app / 'Frameworks' / (name + '.framework'), name)
        self.loads = {
            'Vesper': ['@rpath/PlaybackContracts.framework/PlaybackContracts',
                       '@rpath/VesperAetherBridge.framework/VesperAetherBridge',
                       '@rpath/VesperVLCBridge.framework/VesperVLCBridge'],
            'VesperAetherBridge': ['@rpath/AetherLibavformat.framework/AetherLibavformat'],
        }
        self.exports = {}
        self.imports = {}
        self.flat = set()

    def run_tool(self, *args):
        path = Path(args[-1])
        name = path.name
        if args[1:3] == ('otool', '-hv'):
            return 'MH_MAGIC_64 ARM64 DYLIB ' + ('' if name in self.flat else 'TWOLEVEL')
        if args[1:3] == ('otool', '-L'):
            return str(path) + ':\n' + '\n'.join('    ' + p + ' (compatibility version 1.0.0)' for p in self.loads.get(name, []))
        if args[1:3] == ('otool', '-l'):
            return 'cmd LC_ID_DYLIB\n name @rpath/' + name + '.framework/' + name + ' (offset 24)\nLC_RPATH @executable_path/Frameworks'
        if args[1:3] == ('lipo', '-archs'):
            return 'arm64'
        if args[1:3] == ('nm', '-gjU'):
            return '\n'.join(self.exports.get(name, []))
        if args[1:3] == ('nm', '-ju'):
            return '\n'.join(self.imports.get(name, []))
        raise AssertionError(args)

    def check(self):
        with patch.object(audit, 'run', side_effect=self.run_tool):
            audit.audit(self.app)

    def test_valid_dynamic_closure_writes_report(self):
        self.check()
        self.assertTrue((self.root / 'playback-isolation-report.txt').is_file())

    def test_debug_image_cannot_import_raw_codec_api(self):
        (self.app / 'Vesper.debug.dylib').touch()
        self.imports['Vesper.debug.dylib'] = ['_avformat_open_input']
        with self.assertRaisesRegex(RuntimeError, 'directly imports'):
            self.check()

    def test_vlc_cannot_bind_aether_ffmpeg(self):
        self.loads['VesperVLCBridge'] = ['@rpath/AetherLibavformat.framework/AetherLibavformat']
        with self.assertRaisesRegex(RuntimeError, 'VLC bridge must not bind'):
            self.check()

    def test_codec_symbols_cannot_escape_bridge(self):
        self.exports['VesperVLCBridge'] = ['_avcodec_send_packet', '_libvlc_new']
        with self.assertRaisesRegex(RuntimeError, 'Raw codec symbols escaped'):
            self.check()

    def test_missing_embedded_dependency_fails_closed(self):
        self.loads['VesperAetherBridge'].append('@rpath/AetherLibavcodec.framework/AetherLibavcodec')
        with self.assertRaisesRegex(RuntimeError, 'Missing embedded dependency'):
            self.check()

    def test_unexpected_vlc_dynamic_library_cannot_leak_codecs(self):
        bundle(self.app / 'Frameworks' / 'SwiftVLC.framework', 'SwiftVLC')
        self.exports['SwiftVLC'] = ['_avformat_open_input']
        with self.assertRaisesRegex(RuntimeError, 'Raw codec symbols escaped'):
            self.check()

    def test_flat_namespace_fails_closed(self):
        self.flat.add('VesperVLCBridge')
        with self.assertRaisesRegex(RuntimeError, 'Flat namespace'):
            self.check()

    def test_old_engine_cannot_be_packaged(self):
        bundle(self.app / 'Frameworks' / 'KSPlayer.framework', 'KSPlayer')
        with self.assertRaisesRegex(RuntimeError, 'Removed engine present'):
            self.check()


class EmbedClosureTests(unittest.TestCase):
    def test_unsigned_package_is_prepared_for_resigning(self):
        with tempfile.TemporaryDirectory() as temp:
            app = Path(temp) / 'Vesper.app'
            signature = app / 'Frameworks/Codec.framework/_CodeSignature'
            signature.mkdir(parents=True)
            resources = signature / 'CodeResources'
            resources.write_text('upstream signature')
            binary = signature.parent / 'Codec'
            binary.write_text('framework binary')
            resources.chmod(0o444)
            binary.chmod(0o555)

            embed.prepare_for_external_signing(app)

            self.assertFalse(signature.exists())
            self.assertTrue(binary.stat().st_mode & 0o200)

    def test_transitive_dynamic_dependencies_are_embedded(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            products = root / 'Build' / 'Products' / 'Debug-iphoneos'
            app = products / 'Vesper.app'
            bundle(app, 'Vesper')
            bundle(app / 'Frameworks' / 'VesperAetherBridge.framework', 'VesperAetherBridge')
            for name in ['AetherLibavformat', 'AetherLibavutil']:
                bundle(products / (name + '.framework'), name)
            loads = {
                'VesperAetherBridge': ['AetherLibavformat'],
                'AetherLibavformat': ['AetherLibavutil'],
            }

            def output(*args):
                path = Path(args[-1])
                if '-hv' in args:
                    return 'MH_MAGIC_64 ARM64 DYLIB TWOLEVEL'
                if '-L' in args:
                    return str(path) + ':\n' + '\n'.join(
                        f'  @rpath/{name}.framework/{name} (compatibility version 1.0.0)'
                        for name in loads.get(path.name, []))
                raise AssertionError(args)

            env = {'BUILT_PRODUCTS_DIR': str(products), 'TARGET_BUILD_DIR': str(products),
                   'WRAPPER_NAME': 'Vesper.app', 'BUILD_DIR': str(root / 'Build' / 'Products'),
                   'PLATFORM_NAME': 'iphoneos', 'CODE_SIGNING_ALLOWED': 'NO'}
            with patch.dict(embed.os.environ, env), patch.object(embed, 'output', side_effect=output):
                embed.main()
            self.assertTrue((app / 'Frameworks/AetherLibavformat.framework/AetherLibavformat').is_file())
            self.assertTrue((app / 'Frameworks/AetherLibavutil.framework/AetherLibavutil').is_file())


if __name__ == '__main__':
    unittest.main()
