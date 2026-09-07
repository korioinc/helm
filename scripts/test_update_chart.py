import tempfile
import unittest
from pathlib import Path

from scripts.update_chart import bump_patch, select_latest_stable, update_chart


class UpdateChartTest(unittest.TestCase):
    def test_select_latest_stable_ignores_non_release_tags(self) -> None:
        tags = ["latest", "develop", "develop-deadbeef", "v0.3.99", "0.3.20-rc.1", "0.3.9", "0.3.20", "1.0.0"]
        self.assertEqual(select_latest_stable(tags), "1.0.0")

    def test_bump_patch_uses_chart_version_not_application_version(self) -> None:
        self.assertEqual(bump_patch("1.2.9"), "1.2.10")

    def write_chart(self, chart_dir: Path, core_reference: str) -> str:
        (chart_dir / "Chart.yaml").write_text('''apiVersion: v2
name: multica-runtime-controller
version: 0.2.0
appVersion: "0.3.36"
annotations:
  artifacthub.io/changes: |
    - kind: changed
      description: Initial environment contract
  artifacthub.io/images: |
    - name: multica-runtime-core
      image: ""
  artifacthub.io/links: |
    - name: source
      url: https://github.com/korioinc/multica-runtime-controller
''')
        # A valid operator image can use this repository too. Replacing matching
        # image strings globally would silently change its OS/environment policy.
        operator = '''environment:
  image:
    reference: ghcr.io/korioinc/multica-runtime-controller:0.3.36@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  bootstrap:
    script: "literal $(contents)"
    revision: operator-owned-1
operator:
  env:
    - name: EXAMPLE
      value: private-input
'''
        (chart_dir / "values.yaml").write_text('runtime:\n  image:\n    reference: ' + core_reference + '\n  capacity: 20\n' + operator)
        return operator

    def test_update_changes_only_core_while_preserving_operator_environment(self) -> None:
        digest = "sha256:" + "b" * 64
        with tempfile.TemporaryDirectory() as directory:
            chart_dir = Path(directory)
            operator = self.write_chart(chart_dir, "ghcr.io/korioinc/multica-runtime-controller:0.3.36@sha256:" + "a" * 64)
            result = update_chart(chart_dir, "0.3.37", digest)
            values = (chart_dir / "values.yaml").read_text()
            self.assertTrue(result["changed"])
            self.assertEqual(values[values.index("environment:"):], operator)
            self.assertIn('reference: "ghcr.io/korioinc/multica-runtime-controller:0.3.37@' + digest + '"', values)
            self.assertIn('version: 0.2.1\n', (chart_dir / "Chart.yaml").read_text())
            self.assertIn('appVersion: "0.3.37"', (chart_dir / "Chart.yaml").read_text())

    def test_first_core_preserves_unpublished_chart_version(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            chart_dir = Path(directory)
            self.write_chart(chart_dir, '""')
            update_chart(chart_dir, "0.3.37", "sha256:" + "b" * 64)
            self.assertIn('version: 0.2.0\n', (chart_dir / "Chart.yaml").read_text())
            self.assertIn('0.3.37@sha256:', (chart_dir / "values.yaml").read_text())

    def test_update_is_noop_when_latest_is_not_newer(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            chart_dir = Path(directory)
            self.write_chart(chart_dir, '""')
            paths = [chart_dir / "Chart.yaml", chart_dir / "values.yaml"]
            before = [path.read_bytes() for path in paths]
            result = update_chart(chart_dir, "0.3.36", "sha256:" + "b" * 64)
            self.assertFalse(result["changed"])
            self.assertEqual(before, [path.read_bytes() for path in paths])


if __name__ == "__main__":
    unittest.main()
