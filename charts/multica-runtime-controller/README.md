# multica-runtime-controller

This chart installs the official Multica daemon and runs each provider process
inside an isolated Kubernetes task Pod. The controller and task Pods share one
workspace PersistentVolumeClaim.

## Prerequisites

- A Kubernetes cluster
- Helm 3
- A storage class that supports the configured access mode
- An official Multica user or Cloud Node token

## Install

Create the controller token Secret first:

```shell
kubectl create namespace multica
kubectl --namespace multica create secret generic multica-runtime-controller-token \
  --from-literal=token='mul_...'
```

Install the chart from this repository:

```shell
helm repo add korioinc https://korioinc.github.io/helm
helm repo update
helm upgrade --install multica-runtime-controller \
  korioinc/multica-runtime-controller \
  --namespace multica \
  --create-namespace \
  --set multica.baseURL=https://multica.example.com
```

For a production installation, keep both `controller.image.reference` and
`runtime.image.reference` on the version-tagged digest supplied by the chart.
Override both together when deliberately selecting another published runtime
image.

## Important values

| Value | Default | Description |
| --- | --- | --- |
| `multica.baseURL` | `https://multica.example.com` | Multica API base URL |
| `multica.controllerTokenSecret.name` | `multica-runtime-controller-token` | Existing controller token Secret |
| `runtime.capacity` | `20` | Maximum task capacity |
| `runtime.taskDeadline` | `6h` | Task Pod lifetime bound |
| `runtime.extraEnvFrom` | `[]` | Provider credential Secrets or ConfigMaps |
| `runtime.extraVolumes` | `[]` | Extra task and controller volumes |
| `runtime.extraVolumeMounts` | `[]` | Read-only mounts for extra volumes |
| `workspace.accessModes` | `[ReadWriteMany]` | Workspace PVC access modes |
| `workspace.size` | `100Gi` | Workspace PVC requested size |
| `networkPolicy.enabled` | `true` | Restrict inbound controller and task traffic |

See [`values.yaml`](values.yaml) and
[`values.schema.json`](values.schema.json) for the complete configuration
contract. Runtime architecture and credential-mounting examples are documented
in the [controller repository](https://github.com/korioinc/multica-runtime-controller#readme).

## Release automation

The chart update workflow polls the public GHCR package hourly and supports the
same check through manual `workflow_dispatch` execution from GitHub Actions.
When a run discovers a newer stable runtime, the Helm-owned flow updates
`appVersion`, both version-tagged and digest-pinned image references, and the
Artifact Hub annotations, then increments the chart patch version and publishes
the new package.
