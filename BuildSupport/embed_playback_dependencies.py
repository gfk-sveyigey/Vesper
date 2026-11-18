#!/usr/bin/env python3
"""Embed the dynamic dependency closure of our isolated bridge frameworks.

Invoked by Vesper's final build phase. Static XCFrameworks stay inside their
own bridge and are NEVER copied or relinked into the application executable.
"""
import os
from pathlib import Path
import plistlib
import re
import shutil
import stat
import subprocess

def output(*args):
    return subprocess.check_output(args, text=True)

def executable(bundle):
    with (bundle / 'Info.plist').open('rb') as stream:
        info = plistlib.load(stream)
    return bundle / info['CFBundleExecutable']

def prepare_for_external_signing(app):
    """Remove vendor signatures and read-only modes from unsigned app bundles.

    Self-signing tools replace nested framework signatures after extracting an
    IPA. Preserved XCFramework CodeResources are commonly mode 0444, causing
    those tools to fail before they can sign the app.
    """
    for signature in list(app.rglob('_CodeSignature')):
        if signature.is_dir() and not signature.is_symlink():
            shutil.rmtree(signature)
    for root, directories, files in os.walk(app, followlinks=False):
        for name in directories + files:
            path = Path(root) / name
            if path.is_symlink():
                continue
            mode = path.lstat().st_mode
            os.chmod(path, mode | stat.S_IWUSR)

def main():
    products = Path(os.environ['BUILT_PRODUCTS_DIR'])
    app = Path(os.environ['TARGET_BUILD_DIR']) / os.environ['WRAPPER_NAME']
    destination = app / 'Frameworks'
    destination.mkdir(exist_ok=True)
    artifacts = Path(os.environ['BUILD_DIR']).parents[1] / 'SourcePackages' / 'artifacts'
    platform = 'iphonesimulator' if os.environ.get('PLATFORM_NAME') == 'iphonesimulator' else 'iphoneos'
    index = {}
    # Built products take precedence over other XCFramework slices.
    for root in [products, artifacts]:
        if not root.exists():
            continue
        for bundle in root.rglob('*.framework'):
            if app in bundle.parents or bundle.name in index:
                continue
            # Artifact candidates must match the platform and arm64 slice.
            if root == artifacts:
                identifiers = '/'.join(bundle.parts).lower()
                if '/ios-' not in identifiers or 'maccatalyst' in identifiers:
                    continue
                if ('simulator' in identifiers) != (platform == 'iphonesimulator'):
                    continue
            try:
                binary = executable(bundle)
                if not re.search(r'\b(?:MH_)?DYLIB\b', output('xcrun', 'otool', '-hv', str(binary))):
                    continue
                index[bundle.name] = bundle
            except (OSError, subprocess.CalledProcessError, KeyError):
                continue
    pending = list(destination.glob('*.framework'))
    seen = set()
    while pending:
        bundle = pending.pop()
        if bundle.name in seen:
            continue
        seen.add(bundle.name)
        for line in output('xcrun', 'otool', '-L', str(executable(bundle))).splitlines()[1:]:
            dependency = line.strip().split(' (')[0]
            if not dependency.startswith('@rpath/') or '.framework/' not in dependency:
                continue
            name = dependency.removeprefix('@rpath/').split('/')[0]
            target = destination / name
            if not target.exists():
                source = index.get(name)
                if source is None:
                    raise SystemExit(f'Missing dynamic playback dependency: {dependency}')
                shutil.copytree(source, target, symlinks=True)
                # Preserve signatures only for unsigned workflows. Signed local
                # builds must sign every embedded dynamic dependency again.
                if os.environ.get('CODE_SIGNING_ALLOWED') != 'NO' and os.environ.get('EXPANDED_CODE_SIGN_IDENTITY'):
                    subprocess.run(['codesign', '--force', '--sign', os.environ['EXPANDED_CODE_SIGN_IDENTITY'], '--preserve-metadata=identifier,entitlements', str(target)], check=True)
            pending.append(target)
    for bundle in products.glob('*.bundle'):
        target = app / bundle.name
        if target.exists():
            shutil.rmtree(target)
        shutil.copytree(bundle, target, symlinks=True)
    if os.environ.get('CODE_SIGNING_ALLOWED') == 'NO':
        prepare_for_external_signing(app)

if __name__ == '__main__':
    main()
