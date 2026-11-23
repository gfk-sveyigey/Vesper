"""Validate appearance variants in the iOS app icon asset catalog."""
import json
from pathlib import Path
import xml.etree.ElementTree as ET
import unittest

ROOT = Path(__file__).resolve().parents[2]
ICON_SET = ROOT / "Vesper/Resources/Assets.xcassets/AppIcon.appiconset"
CLASSIC_SET = ROOT / "Vesper/Resources/Assets.xcassets/ClassicIcon.appiconset"


class AppIconAppearanceTests(unittest.TestCase):
    def test_dark_app_icon_is_declared_and_present(self):
        manifest = json.loads((ICON_SET / "Contents.json").read_text())
        variants = {
            tuple((appearance["appearance"], appearance["value"])
                  for appearance in image.get("appearances", [])): image
            for image in manifest["images"]
        }
        self.assertIn((), variants)  # Default/light appearance.
        dark = variants.get((("luminosity", "dark"),))
        self.assertIsNotNone(dark)
        icon = ICON_SET / dark["filename"]
        self.assertTrue(icon.is_file())
        self.assertEqual(icon.stat().st_size > 0, True)

        tinted = variants.get((('luminosity', 'tinted'),))
        self.assertIsNotNone(tinted)
        self.assertTrue((ICON_SET / tinted['filename']).is_file())
        self.assert_png_has_alpha(ICON_SET / dark['filename'])
        self.assert_png_has_alpha(ICON_SET / tinted['filename'])

    def test_classic_icon_is_preserved_as_an_alternate(self):
        manifest = json.loads((CLASSIC_SET / "Contents.json").read_text())
        self.assertEqual(len(manifest["images"]), 3)
        for image in manifest["images"]:
            self.assertTrue((CLASSIC_SET / image["filename"]).is_file())
            if image.get("appearances"):
                self.assert_png_has_alpha(CLASSIC_SET / image["filename"])

        import plistlib
        with (ROOT / "Info.plist").open("rb") as plist_file:
            plist = plistlib.load(plist_file)
        alternate = plist["CFBundleIcons"]["CFBundleAlternateIcons"]
        self.assertEqual(alternate["ClassicIcon"]["CFBundleIconName"], "ClassicIcon")

    def assert_png_has_alpha(self, path):
        data = path.read_bytes()
        self.assertTrue(data.startswith(b"\x89PNG\r\n\x1a\n"))
        self.assertEqual(data[25], 6, f"{path.name} must be RGBA")

    def test_dark_icon_uses_transparent_background_without_brightening_the_mark(self):
        artwork = ROOT / "BuildSupport/artwork"
        light_svg = ET.parse(artwork / "vesper-app-icon.svg").getroot()
        dark_svg = ET.parse(artwork / "vesper-app-icon-dark.svg").getroot()
        namespace = "{http://www.w3.org/2000/svg}"

        self.assertIsNone(dark_svg.find(f"{namespace}rect"))

        def gradients(root):
            return {
                gradient.get("id"): [stop.get("stop-color") for stop in gradient.findall(f"{namespace}stop")]
                for gradient in root.findall(f"{namespace}defs/{namespace}linearGradient")
            }

        self.assertEqual(gradients(dark_svg), gradients(light_svg))


if __name__ == "__main__":
    unittest.main()
