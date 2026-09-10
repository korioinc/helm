#!/usr/bin/env bash
set -euo pipefail
repository=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repository"
mode=${1:---ci}
[ "$#" -le 1 ] || { echo 'usage: scripts/verify-chart.sh [--ci|--release]' >&2; exit 2; }
case "$mode" in --ci|--release) ;; *) echo 'usage: scripts/verify-chart.sh [--ci|--release]' >&2; exit 2 ;; esac
chart=charts/multica-runtime-controller
scratch=$(mktemp -d "${TMPDIR:-/tmp}/multica-chart-check.XXXXXXXX")
trap 'rm -rf "$scratch"' EXIT
for tool in helm curl tar shasum; do command -v "$tool" >/dev/null; done
# Use the upstream native release, never a Go/Python program wrapped by shell.
# Checksums are pinned from the v0.7.0 release's CHECKSUMS asset.
case "$(uname -s)/$(uname -m)" in
  Darwin/x86_64) platform=darwin-amd64; checksum=c6771cc894d82e1b12f35ee797dcda1f7da6a3787aa30902a15c264056dd40d4 ;;
  Darwin/arm64) platform=darwin-arm64; checksum=b5d32b2cb77f9c781c976b20a85e2d0bc8f9184d5d1cfe665a2f31a19f99eeb9 ;;
  Linux/x86_64) platform=linux-amd64; checksum=c31518ddd122663b3f3aa874cfe8178cb0988de944f29c74a0b9260920d115d3 ;;
  Linux/aarch64|Linux/arm64) platform=linux-arm64; checksum=cc907ccf9e3c34523f0f32b69745265e0a6908ca85b92f41931d4537860eb83c ;;
  *) echo 'kubeconform verification supports macOS/Linux amd64/arm64' >&2; exit 2 ;;
esac
archive="$scratch/kubeconform.tar.gz"
curl --fail --silent --show-error --location \
  "https://github.com/yannh/kubeconform/releases/download/v0.7.0/kubeconform-$platform.tar.gz" \
  --output "$archive"
printf '%s  %s\n' "$checksum" "$archive" | shasum -a 256 -c - >/dev/null
tar -xzf "$archive" -C "$scratch" kubeconform
# Chart publication validates the same local contract as CI; selecting or
# publishing a runtime image belongs to the runtime repository.
for profile in "$chart"/ci/values-*.yaml; do
  name=$(basename "$profile" .yaml)
  helm lint "$chart" -f "$chart/ci/networkpolicy-fixture.yaml" -f "$profile"
  helm template multica-runtime-controller "$chart" --namespace multica \
    -f "$chart/ci/networkpolicy-fixture.yaml" -f "$profile" >"$scratch/$name.yaml"
  "$scratch/kubeconform" \
    -strict -summary -kubernetes-version 1.36.0 "$scratch/$name.yaml"
done
helm package "$chart" --destination "$scratch"
