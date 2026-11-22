import importlib.util
from pathlib import Path
import unittest


spec = importlib.util.spec_from_file_location(
    "release_version", Path(__file__).resolve().parents[1] / "release_version.py"
)
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


class ReleaseVersionTests(unittest.TestCase):
    def test_first_feature_release_uses_version_floor(self):
        self.assertEqual(release.automatic_version("1.9.0", ["v1.8.1"], []), "1.9.0")

    def test_subsequent_merge_increments_patch(self):
        self.assertEqual(release.automatic_version("1.9.0", ["v1.9.0"], []), "1.9.1")

    def test_sorts_numerically_and_ignores_nonstable_tags(self):
        tags = ["v1.9.9", "v1.9.10", "v2.0.0-beta.1", "other", "v01.9.99"]
        self.assertEqual(release.automatic_version("1.9.0", tags, []), "1.9.11")

    def test_rerun_reuses_commit_tag_even_after_newer_release(self):
        self.assertEqual(release.automatic_version(
            "1.9.0", ["v1.9.0", "v1.9.1"], ["v1.9.0"]
        ), "1.9.0")

    def test_future_minor_release_can_raise_floor(self):
        self.assertEqual(release.automatic_version("1.10.0", ["v1.9.12"], []), "1.10.0")

    def test_empty_repository_uses_floor(self):
        self.assertEqual(release.automatic_version("1.9.0", [], []), "1.9.0")

    def test_explicit_versions_and_prereleases(self):
        for raw, expected in [("v1.9.0", "1.9.0"), ("1.9.1", "1.9.1"),
                              ("v2.0.0-rc.1", "2.0.0-rc.1")]:
            self.assertEqual(release.explicit_version(raw), expected)

    def test_rejects_invalid_or_unsafe_explicit_versions(self):
        for raw in ["", "1.9", "01.9.0", "1.9.0-", "1.9.0\nversion=2.0.0",
                    "1.9.0-$(id)", "1.9.0-../other"]:
            with self.subTest(raw=raw), self.assertRaises(ValueError):
                release.explicit_version(raw)


if __name__ == "__main__":
    unittest.main()
