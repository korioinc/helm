#!/usr/bin/env bash
set -euo pipefail
repository=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repository"
mode=${1:---ci}
case "$mode" in --ci|--release) ;; *) echo 'usage: scripts/verify-chart.sh [--ci|--release]' >&2; exit 2 ;; esac
chart=charts/multica-runtime-controller
scratch=$(mktemp -d "${TMPDIR:-/tmp}/multica-chart-check.XXXXXXXX")
trap 'rm -rf "$scratch"' EXIT
python3 -m unittest -v scripts.test_update_chart
for script in "$chart"/files/environments/*.sh; do bash -n "$script"; done
release_core_reference=
if [ "$mode" = --release ]; then
  # Verify the actual core; execution environments are explicit render fixtures.
  core_verification=$(python3 scripts/update_chart.py --verify-current)
  printf '%s\n' "$core_verification"
  release_core_reference=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["reference"])' <<<"$core_verification")
fi
for profile in "$chart"/ci/values-*.yaml; do
  name=$(basename "$profile" .yaml)
  values=(-f "$chart/values.yaml" -f "$chart/ci/values-default.yaml" -f "$profile")
  if [ "$mode" = --release ]; then
    values+=(--set-string "runtime.image.reference=$release_core_reference")
  fi
  helm lint "$chart" "${values[@]}"
  helm template multica-runtime-controller "$chart" --namespace multica \
    "${values[@]}" >"$scratch/$name.yaml"
  go run github.com/yannh/kubeconform/cmd/kubeconform@v0.7.0 \
    -strict -summary -kubernetes-version 1.36.0 "$scratch/$name.yaml"
done
helm package "$chart" --destination "$scratch"
