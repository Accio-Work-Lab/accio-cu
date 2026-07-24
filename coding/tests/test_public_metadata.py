from pathlib import Path
import sys
import unittest

REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPOSITORY_ROOT / "coding"))

from accio_cu_code import __version__


class PublicMetadataTests(unittest.TestCase):
    def test_python_version_matches_public_release_version(self):
        expected = (REPOSITORY_ROOT / "VERSION").read_text(encoding="utf-8").strip()

        self.assertEqual(expected, "0.0.1")
        self.assertEqual(__version__, expected)

    def test_public_version_surfaces_stay_in_sync(self):
        expected = (REPOSITORY_ROOT / "VERSION").read_text(encoding="utf-8").strip()
        swift_source = (
            REPOSITORY_ROOT
            / "packages/AccioComputerUseKit/Sources/AccioComputerUseKit/Version.swift"
        ).read_text(encoding="utf-8")
        readme = (REPOSITORY_ROOT / "README.md").read_text(encoding="utf-8")
        installer = (REPOSITORY_ROOT / "scripts/install-macos.sh").read_text(
            encoding="utf-8"
        )

        self.assertIn(f'accioComputerUseVersion = "{expected}"', swift_source)
        self.assertIn(f"version-{expected}-green.svg", readme)
        self.assertIn("CFBundleShortVersionString", installer)
        self.assertIn("<string>$PROJECT_VERSION</string>", installer)


if __name__ == "__main__":
    unittest.main()
