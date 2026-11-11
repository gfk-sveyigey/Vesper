#!/usr/bin/env python3
"""Check asset integrity and local documentation links without an Apple toolchain."""
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
assets = ROOT / 'Vesper/Resources/Assets.xcassets'
expected = {
    'VesperAccent', 'VesperAccentPressed', 'VesperAccentSoft',
    'VesperBackground', 'VesperSecondaryBackground', 'VesperSurface',
    'VesperElevatedSurface', 'VesperPrimaryText', 'VesperSecondaryText',
    'VesperTertiaryText', 'VesperSeparator', 'VesperPlaybackProgress',
    'VesperBufferedProgress', 'VesperPlayerControlBackground',
}
actual = {path.stem for path in assets.glob('*.colorset')}
assert actual == expected, f'Unexpected color resources: {actual ^ expected}'
for name in expected:
    data = json.loads((assets / f'{name}.colorset/Contents.json').read_text())
    colors = data['colors']
    assert len(colors) == 2, f'{name}: missing appearance'
    assert 'appearances' not in colors[0]
    assert colors[1]['appearances'] == [{'appearance': 'luminosity', 'value': 'dark'}]
    for entry in colors:
        components = entry['color']['components']
        assert set(components) == {'red', 'green', 'blue', 'alpha'}
        assert all(0 <= float(value) <= 1 for value in components.values())
for source in (ROOT / 'Vesper').rglob('*.swift'):
    for name in re.findall(r'Color\("([^"]+)"\)', source.read_text()):
        assert name in expected, f'{source}: unknown color {name}'
for doc in (ROOT / 'docs').glob('*.md'):
    for target in re.findall(r'\]\(([^)]+)\)', doc.read_text()):
        if '://' not in target and not target.startswith('#'):
            assert (doc.parent / target.split('#')[0]).exists(), f'{doc}: broken link {target}'
print(f'Validated {len(expected)} color sets, Swift asset references and documentation links.')
