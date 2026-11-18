#!/usr/bin/env python3
"""Fail closed on an invalid dual-engine Mach-O dependency/symbol boundary.

Usage: python3 BuildSupport/audit_playback_isolation.py path/to/Vesper.app
Run on macOS after the Xcode build, for BOTH Debug and Release products.
"""
import argparse
from pathlib import Path
import plistlib
import re
import subprocess

RAW = re.compile(r'^_(?:av\w*_|sws_|swr_|libvlc_|vlc_|dav1d_|zimg_|zvbi_|ass_|mpv_|dovi_)')
OLD = re.compile(r'(?:KSPlayer|FFmpegKit|libmpv|^Libav|^Libsw)', re.I)
BRIDGES = {'PlaybackContracts', 'VesperAetherBridge', 'VesperVLCBridge'}
# Only Aether's explicitly named codec dependency closure may export codec APIs.
# In particular a separately emitted SwiftVLC.framework must not leak libvlc's
# static FFmpeg symbols outside VesperVLCBridge.
CODEC_OWNERS = {
    'AetherLibavcodec', 'AetherLibavformat', 'AetherLibavutil', 'AetherLibavfilter',
    'AetherLibswscale', 'AetherLibswresample', 'AetherLibdav1d', 'AetherLibzimg',
    'AetherLibzvbi', 'LibDovi', 'AetherLibdovi',
}

def run(*args):
    return subprocess.check_output(args, text=True, stderr=subprocess.STDOUT)

def binary(bundle):
    info = plistlib.loads((bundle / 'Info.plist').read_bytes())
    return bundle / info['CFBundleExecutable']

def audit(app):
    frameworks = app / 'Frameworks'
    for name in BRIDGES:
        if not (frameworks / (name + '.framework')).is_dir():
            raise RuntimeError(f'Missing isolated framework: {name}')
    binaries = [binary(app)] + [binary(p) for p in frameworks.glob('*.framework')]
    # Xcode's Debug executable is a trampoline; inspect its real image too.
    binaries += list(app.glob('*.dylib'))
    reports = []
    for path in binaries:
        if OLD.search(path.name):
            raise RuntimeError(f'Removed engine present: {path.name}')
        header = run('xcrun', 'otool', '-hv', str(path))
        loads = run('xcrun', 'otool', '-L', str(path))
        commands = run('xcrun', 'otool', '-l', str(path))
        symbols = run('xcrun', 'nm', '-gjU', str(path)).splitlines()
        is_framework = path.parent == frameworks
        reports.append(f'\n## {path.relative_to(app)}\n{header}\n{loads}\n{commands}\nEXPORTED SYMBOLS\n' + '\n'.join(symbols))
        if 'TWOLEVEL' not in header:
            raise RuntimeError(f'Flat namespace is forbidden: {path.name}')
        if is_framework and not re.search(r'\bDYLIB\b', header):
            raise RuntimeError(f'Embedded framework is not a dynamic library: {path.name}')
        if is_framework:
            install_names = re.findall(r'\bname\s+(\S+)\s+\(offset\s+\d+\)', commands)
            if len(install_names) != 1 or not install_names[0].startswith('@rpath/'):
                raise RuntimeError(f'Framework needs one @rpath LC_ID_DYLIB: {path.name}: {install_names}')
        if not re.search(r'\barm64\b', run('xcrun', 'lipo', '-archs', str(path))):
            raise RuntimeError(f'Missing iPhone arm64: {path.name}')
        if path.name not in CODEC_OWNERS:
            leaked = [s for s in symbols if RAW.match(s)]
            if leaked:
                raise RuntimeError(f'Raw codec symbols escaped {path.name}: {leaked[:12]}')
        for line in loads.splitlines()[1:]:
            dependency = line.strip().split(' (')[0]
            if dependency.startswith(('/System/Library/', '/usr/lib/')):
                continue
            if not dependency.startswith('@rpath/'):
                raise RuntimeError(f'Unexpected dependency path in {path.name}: {dependency}')
            relative = dependency.removeprefix('@rpath/')
            if not any((root / relative).is_file() for root in [frameworks, app]):
                raise RuntimeError(f'Missing embedded dependency in {path.name}: {dependency}')
            if path.stem == 'VesperVLCBridge' and ('Aether' in dependency or 'LibDovi' in dependency):
                raise RuntimeError('VLC bridge must not bind to the Aether FFmpeg closure')
        # Raw FFmpeg references in the app are also forbidden even if undefined.
        if path.parent == app:
            undefined = run('xcrun', 'nm', '-ju', str(path)).splitlines()
            if any(RAW.match(s) for s in undefined):
                raise RuntimeError(f'App directly imports a codec API: {path.name}')
        if path.stem == 'VesperAetherBridge':
            if 'AetherLibav' not in loads:
                raise RuntimeError('Aether bridge has no independently named FFmpeg dependency')
    report = app.parent / 'playback-isolation-report.txt'
    report.write_text('\n'.join(reports))
    print(f'Playback isolation checks passed. Report: {report}')

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('app', type=Path)
    args = parser.parse_args()
    audit(args.app.resolve())
