"""Validate appearance variants in the iOS app icon asset catalog."""
import json
from pathlib import Path
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

    def test_classic_icon_is_preserved_as_an_alternate(self):
        manifest = json.loads((CLASSIC_SET / "Contents.json").read_text())
        self.assertEqual(len(manifest["images"]), 2)
        for image in manifest["images"]:
            self.assertTrue((CLASSIC_SET / image["filename"]).is_file())

        import plistlib
        with (ROOT / "Info.plist").open("rb") as plist_file:
            plist = plistlib.load(plist_file)
        alternate = plist["CFBundleIcons"]["CFBundleAlternateIcons"]
        self.assertEqual(alternate["ClassicIcon"]["CFBundleIconName"], "ClassicIcon")


if __name__ == "__main__":
    unittest.main()
