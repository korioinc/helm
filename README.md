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

Configure a digest-pinned execution image, a nonempty provider list and an inline
or ConfigMap bootstrap in `values.yaml`, then install or upgrade the controller:

```shell
helm upgrade --install multica-runtime-controller \
  korioinc/multica-runtime-controller \
  --namespace multica \
  -f values.yaml \
  --set multica.baseURL=https://multica.example.com
```

Chart 0.3.0 requires runtime core 0.3.39 or later and leaves the execution
environment unconfigured. No language or provider installation is selected by
default. Image, providers and bootstrap must be supplied explicitly; the opt-in
installer examples are described in the chart README. Separate tools/workspace
PVCs are required. Operator configuration is copied into writable private provider
homes during init. Upgrade the chart and its pinned core together; old combined
images and old values are incompatible.

## Configuration

See the chart [README](charts/multica-runtime-controller/README.md),
[`values.yaml`](charts/multica-runtime-controller/values.yaml), and
[`values.schema.json`](charts/multica-runtime-controller/values.schema.json)
for prerequisites and configuration options.
