#!/usr/bin/env python3
"""Update the chart when a newer stable runtime image appears in GHCR."""

from __future__ import annotations

import argparse
import hashlib
import subprocess
import tempfile
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


def core_reference(values: str) -> tuple[re.Match[str], re.Match[str]]:
    runtime = _single_match(r"^runtime:\n(?:(?:[ \t]+[^\n]*)?\n)*", values, "runtime block")
    image = _single_match(r"^    reference: ([^\n]*)$", runtime.group(), "core image reference")
    return runtime, image


def verify_core_image(reference: str, version: str) -> None:
    """Inspect both native artifact files without executing the candidate image."""
    if not re.fullmatch(r"[^\s@]+@sha256:[a-f0-9]{64}", reference):
        raise ValueError("a digest-pinned core artifact is required")
    manifest = json.loads(subprocess.check_output(
        ["docker", "manifest", "inspect", reference], text=True))
    native = {}
    for entry in manifest.get("manifests", []):
        platform = entry.get("platform", {})
        if platform.get("os") == "linux" and platform.get("architecture") in ("amd64", "arm64"):
            arch = platform["architecture"]
            if arch in native:
                raise ValueError("core image index has duplicate native platforms")
            digest = entry.get("digest", "")
            if not DIGEST_RE.fullmatch(digest):
                raise ValueError("invalid native image descriptor")
            native[arch] = digest
    if set(native) != {"amd64", "arm64"}:
        raise ValueError("core artifact requires linux/amd64 and linux/arm64")
    repository = reference.split("@", 1)[0]
    # Drop the human-readable tag; each native digest is immutable.
    last = repository.rsplit("/", 1)[-1]
    if ":" in last:
        repository = repository.rsplit(":", 1)[0]
    for arch, digest in sorted(native.items()):
        image = repository + "@" + digest
        subprocess.run(["docker", "pull", "--platform", "linux/" + arch, image], check=True,
                       stdout=subprocess.DEVNULL)
        metadata = json.loads(subprocess.check_output(["docker", "image", "inspect", image], text=True))[0]
        if metadata.get("Os") != "linux" or metadata.get("Architecture") != arch:
            raise ValueError("core image platform does not match its index")
        if metadata.get("Config", {}).get("Labels", {}).get("org.opencontainers.image.version") != version:
            raise ValueError("core image version label does not match the selected release")
        container = subprocess.check_output(
            ["docker", "create", "--platform", "linux/" + arch, "--entrypoint", "/artifact/runtime", image],
            text=True).strip()
        try:
            with tempfile.TemporaryDirectory(prefix="multica-core-contract-") as directory:
                subprocess.run(["docker", "cp", container + ":/artifact/.", directory], check=True)
                root = Path(directory)
                contract_path = root / "contract.json"
                if not contract_path.is_file() or contract_path.is_symlink():
                    raise ValueError("image is not a runtime core artifact")
                contract = json.loads(contract_path.read_text())
                if contract.get("contractVersion") != 1 or contract.get("platform") != "linux/" + arch:
                    raise ValueError("incompatible core artifact contract/platform")
                if not re.fullmatch(r"[a-f0-9]{64}", contract.get("buildID", "")):
                    raise ValueError("invalid core build identity")
                if not SEMVER_RE.fullmatch(contract.get("officialVersion", "")):
                    raise ValueError("invalid official CLI version")
                files = contract.get("files", {})
                if set(files) != {"runtime", "multica"} or contract.get("officialSHA256") != files["multica"]:
                    raise ValueError("invalid core artifact file contract")
                for name, expected in files.items():
                    artifact = root / name
                    if not artifact.is_file() or artifact.is_symlink() or not artifact.stat().st_mode & 0o111:
                        raise ValueError("core artifact must contain executable regular files")
                    with artifact.open("rb") as stream:
                        actual = hashlib.file_digest(stream, "sha256").hexdigest()
                    if actual != expected:
                        raise ValueError("core artifact file hash does not match its contract")
        finally:
            subprocess.run(["docker", "rm", container], check=True, stdout=subprocess.DEVNULL)


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

    runtime_match, image_match = core_reference(values)
    current_reference = image_match.group(1).strip().strip('"').strip("'")
    # The first compatible core fills the unpublished chart; subsequent upgrades
    # increment its patch version. A chart with an empty core cannot be released.
    next_chart_version = bump_patch(chart_version) if current_reference else chart_version
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
                f"  description: Update runtime core artifact to {latest}",
            ]
        ),
    )
    chart = _replace_annotation(
        chart,
        "artifacthub.io/images",
        "\n".join(
            [
                "- name: multica-runtime-core",
                f"  image: {IMAGE}:{latest}@{digest}",
                "  platforms:",
                "    - linux/amd64",
                "    - linux/arm64",
            ]
        ),
    )

    runtime = runtime_match.group()
    reference_start = image_match.start(1)
    reference_end = image_match.end(1)
    runtime = runtime[:reference_start] + f'"{IMAGE}:{latest}@{digest}"' + runtime[reference_end:]
    values = values[:runtime_match.start()] + runtime + values[runtime_match.end():]

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
    parser.add_argument("--verify-current", action="store_true")
    parser.add_argument("--latest-version")
    parser.add_argument("--digest")
    args = parser.parse_args()
    if args.verify_current and (args.latest_version or args.digest):
        parser.error("--verify-current cannot be combined with update inputs")
    if bool(args.latest_version) != bool(args.digest):
        parser.error("--latest-version and --digest must be provided together")
    return args


def main() -> int:
    args = parse_args()
    if args.verify_current:
        chart = (args.chart_dir / "Chart.yaml").read_text()
        values = (args.chart_dir / "values.yaml").read_text()
        version = _single_match(rf'^appVersion: "({SEMVER_PATTERN})"$', chart, "application version").group(1)
        _, image = core_reference(values)
        reference = image.group(1).strip().strip('"').strip("'")
        verify_core_image(reference, version)
        print(json.dumps({"verified": True, "app_version": version, "reference": reference}))
        return 0
    if args.latest_version:
        latest, digest = args.latest_version, args.digest
    else:
        latest, digest = resolve_latest_image()
    chart = (args.chart_dir / "Chart.yaml").read_text()
    current = _single_match(rf'^appVersion: "({SEMVER_PATTERN})"$', chart, "application version").group(1)
    if semver_key(latest) > semver_key(current):
        verify_core_image(f"{IMAGE}:{latest}@{digest}", latest)
    result = update_chart(args.chart_dir, latest, digest)
    print(json.dumps(result, separators=(",", ":"), sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
