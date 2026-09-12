# Korio Helm Charts

Helm charts for running Korio services on Kubernetes.

## Install

Add the repository:

```sh
helm repo add korioinc https://korioinc.github.io/helm
helm repo update
```

| Chart | Description |
| --- | --- |
| [multica-runtime-controller](https://github.com/korioinc/helm/tree/main/charts/multica-runtime-controller) | Run Multica agent tasks in dedicated Kubernetes Pods with shared workspace storage. |

Follow the chart's README for prerequisites, installation, provider configuration, and operations. Each chart includes its defaults in `values.yaml` and validation rules in `values.schema.json`.

## Publishing

Chart source lives in `main`. Increase the chart's `version` in `Chart.yaml` when publishing a change, then push to `main`. The release workflow lints the chart, publishes its package to GitHub Releases, updates `index.yaml` and site metadata on `gh-pages`, and builds GitHub Pages.

The workflow manages release tags, package URLs, and the repository index automatically.
