import tempfile
import unittest
from pathlib import Path

from scripts.update_chart import (
    bump_patch,
    select_latest_stable,
    update_chart,
)


class UpdateChartTest(unittest.TestCase):
    def test_select_latest_stable_ignores_non_release_tags(self) -> None:
        tags = [
            "latest",
            "develop",
            "develop-deadbeef",
            "v0.3.99",
            "0.3.20-rc.1",
            "0.3.9",
            "0.3.20",
            "1.0.0",
        ]

        self.assertEqual(select_latest_stable(tags), "1.0.0")

    def test_bump_patch_uses_chart_version_not_application_version(self) -> None:
        self.assertEqual(bump_patch("1.2.9"), "1.2.10")

    def test_update_chart_bumps_chart_and_application_versions_and_digest(self) -> None:
        digest = "sha256:" + "b" * 64
        with tempfile.TemporaryDirectory() as temp_dir:
            chart_dir = Path(temp_dir)
            chart_path = chart_dir / "Chart.yaml"
            values_path = chart_dir / "values.yaml"
            chart_path.write_text(
                """apiVersion: v2
name: multica-runtime-controller
version: 0.1.0
appVersion: \"0.3.20\"
annotations:
  artifacthub.io/changes: |
    - kind: added
      description: Initial release
  artifacthub.io/images: |
    - name: multica-runtime-controller
      image: ghcr.io/korioinc/multica-runtime-controller:0.3.20
""",
                encoding="utf-8",
            )
            values_path.write_text(
                """runtime:
  image:
    reference: ghcr.io/korioinc/multica-runtime-controller@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
controller:
  image:
    reference: ghcr.io/korioinc/multica-runtime-controller@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
""",
                encoding="utf-8",
            )

            result = update_chart(chart_dir, "0.3.21", digest)

            self.assertEqual(
                result,
                {
                    "changed": True,
                    "previous_app_version": "0.3.20",
                    "app_version": "0.3.21",
                    "previous_chart_version": "0.1.0",
                    "chart_version": "0.1.1",
                    "digest": digest,
                },
            )
            chart = chart_path.read_text(encoding="utf-8")
            values = values_path.read_text(encoding="utf-8")
            self.assertIn('version: 0.1.1', chart)
            self.assertIn('appVersion: "0.3.21"', chart)
            self.assertIn(
                "description: Update runtime image to 0.3.21", chart
            )
            self.assertIn(
                "image: ghcr.io/korioinc/multica-runtime-controller:0.3.21",
                chart,
            )
            self.assertEqual(values.count(f"reference: ghcr.io/korioinc/multica-runtime-controller@{digest}"), 2)

    def test_update_chart_is_noop_when_latest_is_not_newer(self) -> None:
        digest = "sha256:" + "b" * 64
        with tempfile.TemporaryDirectory() as temp_dir:
            chart_dir = Path(temp_dir)
            chart_path = chart_dir / "Chart.yaml"
            values_path = chart_dir / "values.yaml"
            chart_path.write_text(
                """apiVersion: v2
name: multica-runtime-controller
version: 0.1.0
appVersion: \"0.3.20\"
""",
                encoding="utf-8",
            )
            values_path.write_text("unchanged\n", encoding="utf-8")
            before = (chart_path.read_bytes(), values_path.read_bytes())

            result = update_chart(chart_dir, "0.3.20", digest)

            self.assertFalse(result["changed"])
            self.assertEqual(before, (chart_path.read_bytes(), values_path.read_bytes()))


if __name__ == "__main__":
    unittest.main()
