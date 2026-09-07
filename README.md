# Korio Helm Charts

[![Artifact Hub](https://img.shields.io/endpoint?url=https://artifacthub.io/badge/repository/korioinc)](https://artifacthub.io/packages/search?repo=korioinc)

Official Helm charts maintained by Korio for deploying Multica components on
Kubernetes.

## Available Charts

- [multica-runtime-controller](charts/multica-runtime-controller): Deploys the
  official Multica daemon and runs provider processes in isolated Kubernetes
  task Pods.

## Getting Started

Add the Korio Helm repository and update its local index:

```shell
helm repo add korioinc https://korioinc.github.io/helm
helm repo update
```

List the available charts:

```shell
helm search repo korioinc
```

You can also browse the repository on
[Artifact Hub](https://artifacthub.io/packages/search?repo=korioinc).

## Install

Create the namespace and controller token Secret:

```shell
kubectl create namespace multica
kubectl --namespace multica create secret generic multica-runtime-controller-token \
  --from-literal=token='mul_...'
```

Install or upgrade the runtime controller:

```shell
helm upgrade --install multica-runtime-controller \
  korioinc/multica-runtime-controller \
  --namespace multica \
  --set-string runtime.image.reference="$CORE_IMAGE_DIGEST" \
  --set multica.baseURL=https://multica.example.com
```

The 0.2 chart requires a contract-version-1 core artifact and separate tools/workspace
PVCs. Old combined images and old values are incompatible. See the chart README
for the selected environment image, bootstrap, RWO scheduling and credential inputs.

## Configuration

See the chart [README](charts/multica-runtime-controller/README.md),
[`values.yaml`](charts/multica-runtime-controller/values.yaml), and
[`values.schema.json`](charts/multica-runtime-controller/values.schema.json)
for prerequisites and configuration options.
