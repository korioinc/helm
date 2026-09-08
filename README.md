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

Configure the connection and workspace storage in `values.yaml`. Chart 0.4.0
defaults to the complete `ghcr.io/korioinc/multica-runtime:latest` image with
`imagePullPolicy: Always`. Set `image` to your complete custom image tag or digest
when needed, then install the controller:

```shell
helm upgrade --install multica-runtime-controller \
  korioinc/multica-runtime-controller \
  --namespace multica \
  -f values.yaml \
  --set multica.baseURL=https://multica.example.com
```

Chart 0.4.0 uses controller ABI 2. The controller base alone does not contain the
Multica daemon or task tools; complete images are built in the
[runtime repository](https://github.com/korioinc/multica-runtime). The controller
binds workers to its verified running image digest and platform. Operator
ConfigMap files are copied into private writable homes and fixed in immutable
snapshots for that controller's workers. Only the workspace PVC is managed.

Legacy `runtime.image`, `environment` and `replicaCount` values are rejected.
Existing schema 1 workspaces require explicit migration; preserve workspace and
identity data when moving from an older chart. See the chart README for the
retention implications of removing the former Tools PVC manifest.

## Configuration

See the chart [README](charts/multica-runtime-controller/README.md),
[`values.yaml`](charts/multica-runtime-controller/values.yaml), and
[`values.schema.json`](charts/multica-runtime-controller/values.schema.json)
for prerequisites and configuration options.
