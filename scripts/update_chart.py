#!/usr/bin/env python3
"""Update the chart when a newer stable runtime image appears in GHCR."""

from __future__ import annotations

import argparse
import json
import re
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Iterable


REGISTRY = "ghcr.io"
IMAGE_REPOSITORY = "korioinc/multica-runtime-controller"
IMAGE = f"{REGISTRY}/{IMAGE_REPOSITORY}"
SEMVER_PATTERN = r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)"
SEMVER_RE = re.compile(rf"^{SEMVER_PATTERN}$")
DIGEST_RE = re.compile(r"^sha256:[0-9a-f]{64}$")


def semver_key(version: str) -> tuple[int, int, int]:
    match = SEMVER_RE.fullmatch(version)
    if not match:
        raise ValueError(f"not a stable semantic version: {version!r}")
    return tuple(int(part) for part in match.groups())


def select_latest_stable(tags: Iterable[str]) -> str:
    stable = [tag for tag in tags if SEMVER_RE.fullmatch(tag)]
    if not stable:
        raise ValueError("GHCR did not return a stable semantic-version tag")
    return max(stable, key=semver_key)


def bump_patch(version: str) -> str:
    major, minor, patch = semver_key(version)
    return f"{major}.{minor}.{patch + 1}"


def _request_json(request: urllib.request.Request | str) -> object:
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.load(response)


def resolve_latest_image() -> tuple[str, str]:
    scope = f"repository:{IMAGE_REPOSITORY}:pull"
    token_url = (
        f"https://{REGISTRY}/token?"
        + urllib.parse.urlencode({"scope": scope})
    )
    token_response = _request_json(token_url)
    if not isinstance(token_response, dict) or not isinstance(
        token_response.get("token"), str
    ):
        raise ValueError("GHCR token response did not contain a token")
    token = token_response["token"]
    headers = {"Authorization": f"Bearer {token}"}

    tags_request = urllib.request.Request(
        f"https://{REGISTRY}/v2/{IMAGE_REPOSITORY}/tags/list?n=1000",
        headers=headers,
    )
    tags_response = _request_json(tags_request)
    if not isinstance(tags_response, dict) or not isinstance(
        tags_response.get("tags"), list
    ):
        raise ValueError("GHCR tag response did not contain a tag list")
    latest = select_latest_stable(tags_response["tags"])

    manifest_headers = {
        **headers,
        "Accept": ", ".join(
            [
                "application/vnd.oci.image.index.v1+json",
                "application/vnd.docker.distribution.manifest.list.v2+json",
                "application/vnd.oci.image.manifest.v1+json",
                "application/vnd.docker.distribution.manifest.v2+json",
            ]
        ),
    }
    manifest_request = urllib.request.Request(
        f"https://{REGISTRY}/v2/{IMAGE_REPOSITORY}/manifests/{latest}",
        headers=manifest_headers,
        method="HEAD",
    )
    with urllib.request.urlopen(manifest_request, timeout=30) as response:
        digest = response.headers.get("Docker-Content-Digest", "")
    if not DIGEST_RE.fullmatch(digest):
        raise ValueError(f"GHCR returned an invalid manifest digest: {digest!r}")
    return latest, digest


def _single_match(pattern: str, content: str, description: str) -> re.Match[str]:
    matches = list(re.finditer(pattern, content, flags=re.MULTILINE))
    if len(matches) != 1:
        raise ValueError(
            f"expected exactly one {description}, found {len(matches)}"
        )
    return matches[0]


def _replace_annotation(content: str, key: str, body: str) -> str:
    pattern = rf"(?ms)(^  {re.escape(key)}: \|\n).*?(?=^  [^ \n]+:|\Z)"
    match = _single_match(pattern, content, f"{key} annotation")
    replacement = match.group(1) + "".join(
        f"    {line}\n" for line in body.splitlines()
    )
    return content[: match.start()] + replacement + content[match.end() :]


def update_chart(chart_dir: Path, latest: str, digest: str) -> dict[str, object]:
    semver_key(latest)
    if not DIGEST_RE.fullmatch(digest):
        raise ValueError(f"invalid image digest: {digest!r}")

    chart_path = chart_dir / "Chart.yaml"
    values_path = chart_dir / "values.yaml"
    chart = chart_path.read_text(encoding="utf-8")
    values = values_path.read_text(encoding="utf-8")

    chart_version_match = _single_match(
        rf"^version: ({SEMVER_PATTERN})$", chart, "chart version"
    )
    app_version_match = _single_match(
        rf'^appVersion: "({SEMVER_PATTERN})"$', chart, "application version"
    )
    chart_version = chart_version_match.group(1)
    app_version = app_version_match.group(1)

    if semver_key(latest) <= semver_key(app_version):
        return {
            "changed": False,
            "app_version": app_version,
            "chart_version": chart_version,
        }

    next_chart_version = bump_patch(chart_version)
    chart = (
        chart[: chart_version_match.start(1)]
        + next_chart_version
        + chart[chart_version_match.end(1) :]
    )
    app_version_match = _single_match(
        rf'^appVersion: "({SEMVER_PATTERN})"$', chart, "application version"
    )
    chart = (
        chart[: app_version_match.start(1)]
        + latest
        + chart[app_version_match.end(1) :]
    )
    chart = _replace_annotation(
        chart,
        "artifacthub.io/changes",
        "\n".join(
            [
                "- kind: changed",
                f"  description: Update runtime image to {latest}",
            ]
        ),
    )
    chart = _replace_annotation(
        chart,
        "artifacthub.io/images",
        "\n".join(
            [
                "- name: multica-runtime-controller",
                f"  image: {IMAGE}:{latest}",
                "  platforms:",
                "    - linux/amd64",
                "    - linux/arm64",
            ]
        ),
    )

    image_pattern = re.compile(
        rf"{re.escape(IMAGE)}:{SEMVER_PATTERN}@sha256:[0-9a-f]{{64}}"
    )
    image_references = image_pattern.findall(values)
    if len(image_references) != 2:
        raise ValueError(
            "expected exactly two version-tagged, digest-pinned "
            "runtime image references, "
            f"found {len(image_references)}"
        )
    values = image_pattern.sub(f"{IMAGE}:{latest}@{digest}", values)

    chart_path.write_text(chart, encoding="utf-8")
    values_path.write_text(values, encoding="utf-8")
    return {
        "changed": True,
        "previous_app_version": app_version,
        "app_version": latest,
        "previous_chart_version": chart_version,
        "chart_version": next_chart_version,
        "digest": digest,
    }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--chart-dir",
        type=Path,
        default=Path("charts/multica-runtime-controller"),
    )
    parser.add_argument("--latest-version")
    parser.add_argument("--digest")
    args = parser.parse_args()
    if bool(args.latest_version) != bool(args.digest):
        parser.error("--latest-version and --digest must be provided together")
    return args


def main() -> int:
    args = parse_args()
    if args.latest_version:
        latest, digest = args.latest_version, args.digest
    else:
        latest, digest = resolve_latest_image()
    result = update_chart(args.chart_dir, latest, digest)
    print(json.dumps(result, separators=(",", ":"), sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
