"""Guard database management actions and app-icon selection styling."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]


class AppearanceAndSkipDatabaseSettingsTests(unittest.TestCase):
    def test_skip_database_deletion_uses_identity_confirmation_not_list_offsets(self):
        source = (ROOT / "Vesper/Features/Settings/EmbySkipDatabasesView.swift").read_text()
        self.assertIn("@State private var deleting: EmbySkipDatabase?", source)
        self.assertIn(".alert(item: $deleting)", source)
        self.assertIn("databases.removeAll { $0.id == database.id }", source)
        self.assertIn("private func move(_ id: String, by offset: Int)", source)
        self.assertNotIn(".onDelete", source)
        self.assertNotIn(".environment(\.editMode", source)

    def test_selected_app_icon_only_changes_its_border(self):
        source = (ROOT / "Vesper/Features/Settings/SettingsView.swift").read_text()
        choices = source.split("struct AppIconChoices: View", 1)[1]
        self.assertIn(".stroke(selected ? Color.accentColor : Color.clear, lineWidth: 2)", choices)
        self.assertIn(".foregroundStyle(Color.primary)", choices)
        self.assertIn(".disabled(!UIApplication.shared.supportsAlternateIcons)", choices)
        self.assertNotIn(".disabled(!UIApplication.shared.supportsAlternateIcons || selected)", choices)


if __name__ == "__main__":
    unittest.main()
