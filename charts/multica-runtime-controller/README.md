# Multica Runtime Controller

Run Multica agent tasks in dedicated Kubernetes worker Pods. This chart deploys the controller, shared workspace storage, and the permissions and networking needed to manage task execution.

## Architecture

The controller connects to Multica, registers the runtime, polls for tasks, and manages a worker Pod for each task. Controller and workers use the same complete [runtime image](https://github.com/korioinc/multica-runtime), which includes the controller, daemon, providers, and task tools.

| Component | Responsibility |
| --- | --- |
| Controller | One Deployment using the `Recreate` strategy; sends heartbeats and coordinates workers. |
| Workers | One Pod per task, with a private HOME and temporary storage. |
| Shared workspace | A PVC holding task directories and prepared task HOME archives. |
| Daemon proxy | An internal Service connecting workers to the controller on TCP port `8080`. |
| Identity and configuration | Chart-managed Secrets for controller identity and worker settings; an existing Secret supplies the controller token. Identity is preserved across Helm upgrades. |
| Permissions | Namespace-scoped Pod and Secret access for the controller. Workers receive no chart-managed RBAC grants or mounted API tokens. |
| NetworkPolicies | Allow worker connections to the controller, deny worker ingress, and restrict worker egress as configured. |

At startup, an init container copies provider configuration from ConfigMaps into the controller's private HOME. The controller prepares task HOME archives on the workspace for workers to initialize their own HOME. HOME, temporary files, and runtime state use Pod-local storage; task workspace data persists on the PVC.

Controller containers run as UID/GID `65532` with a read-only root filesystem, dropped capabilities, and privilege escalation disabled. A PodDisruptionBudget is enabled with `maxUnavailable: 1`.

## Requirements

- A Multica instance and controller token.
- Linux nodes matching the configured `platform`: `linux/amd64` or `linux/arm64`.
- A workspace volume supporting `ReadWriteMany`, or `ReadWriteOnce` with all controller and worker Pods pinned to one node. The volume must be writable by UID/GID `65532`.
- Access to the runtime image registry.
- A CNI that enforces the configured NetworkPolicies. API protection requires TCP port ranges (`endPort`) and `ipBlock` matching for the relevant Pod and node addresses.
- For default API protection, the Helm installer must be able to get the `default/kubernetes` Service and list EndpointSlices in `default`.

Use one controller release per namespace: worker policies select the shared `app.kubernetes.io/managed-by: multica-runtime-controller` label.

## Installation

Add the Helm repository:

```sh
helm repo add korioinc https://korioinc.github.io/helm
helm repo update
```

Create the namespace and controller token Secret:

```sh
kubectl create namespace multica
kubectl -n multica create secret generic multica-runtime-controller-token \
  --from-literal=token=YOUR_CONTROLLER_TOKEN
```

Create a `values.yaml` file with your Multica URL and workspace storage class:

```yaml
multica:
  baseURL: https://multica.example.com
workspace:
  storage:
    storageClass: shared-workspace
    size: 100Gi
    accessMode: ReadWriteMany
```

Install the chart and wait for the controller to become ready:

```sh
helm install multica-runtime-controller korioinc/multica-runtime-controller \
  --namespace multica \
  --values values.yaml \
  --wait
```

Check the controller:

```sh
kubectl -n multica get pods
kubectl -n multica logs deployment/multica-runtime-controller -c controller
```

## Configuration

See [values.yaml](values.yaml) for all defaults and [values.schema.json](values.schema.json) for validation rules.

| Settings | Purpose |
| --- | --- |
| `image`, `imagePullPolicy`, `imagePullSecrets` | Shared runtime image and registry access. The default is `ghcr.io/korioinc/multica-runtime:latest` with pull policy `Always`. |
| `platform`, `scheduling` | Architecture and placement for controller and workers. The default platform is `linux/amd64`. |
| `multica` | Multica URL and existing controller token Secret. |
| `runtime` | Registered name, task concurrency, polling, heartbeats, and startup timeout. Default capacity is `20` tasks. |
| `workspace.storage` | Create a workspace PVC or reference an existing claim. |
| `operator` | Provider environment variables and configuration folders. |
| `controller.resources`, `worker.resources` | Resource requests and limits. Worker resources cover all processes in each task Pod. |
| `worker.taskDeadline`, `worker.terminationGraceSeconds` | Task lifetime and shutdown grace period, in seconds. |
| `controller.podAnnotations`, `podDisruptionBudget` | Rollout markers and voluntary disruption settings. |
| `networkPolicy` | Worker egress restrictions and controller ingress policy. |

## Workspace Storage

The controller and workers share one PVC. With `ReadWriteMany`, they can run across matching nodes. To use an existing claim, clear settings for creating a new claim:

```yaml
workspace:
  storage:
    existingClaim: multica-workspace
    size: ""
    storageClass: ""
    accessMode: ReadWriteMany
```

For `ReadWriteOnce`, set `workspace.storage.accessMode: ReadWriteOnce` and `scheduling.singleNodeName` to the node's Kubernetes name. Additional node selectors must match that node and the selected platform.

Use an externally managed claim when storage must outlive the Helm release: a chart-created PVC is deleted on uninstall. Back up workspace data according to your storage provider's guidance.

## Provider Configuration

Supply provider credentials through Secrets. Set environment variables with `operator.env` or import Secrets and ConfigMaps through `operator.envFrom`:

```yaml
operator:
  env:
    - name: GIT_TERMINAL_PROMPT
      value: "0"
  envFrom:
    - secretRef:
        name: provider-credentials
```

Keep provider configuration in folders matching the layout under HOME:

```text
provider-config/
├── codex/
│   ├── config.toml
│   ├── AGENTS.md
│   └── skills/
│       └── example/
│           └── SKILL.md
└── pi/
    └── agent/
        └── settings.json
```

Create a ConfigMap for each provider in the release namespace. ConfigMap keys are flat, so the Helm values below map each key back to its relative file path:

```sh
kubectl -n multica create configmap runtime-codex-config \
  --from-file=config.toml=provider-config/codex/config.toml \
  --from-file=AGENTS.md=provider-config/codex/AGENTS.md \
  --from-file=example-skill=provider-config/codex/skills/example/SKILL.md \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl -n multica create configmap runtime-pi-config \
  --from-file=settings.json=provider-config/pi/agent/settings.json \
  --dry-run=client -o yaml | kubectl apply -f -
```

Add these overrides to `values.yaml`. Each `configMounts` entry copies a whole provider folder; `items.path` preserves nested directories:

```yaml
operator:
  configVolumes:
    - name: codex-home
      configMap:
        name: runtime-codex-config
        items:
          - key: config.toml
            path: config.toml
          - key: AGENTS.md
            path: AGENTS.md
          - key: example-skill
            path: skills/example/SKILL.md
    - name: pi-home
      configMap:
        name: runtime-pi-config
        items:
          - key: settings.json
            path: agent/settings.json
  configMounts:
    - name: codex-home
      mountPath: /home/multica/agents/.codex
      readOnly: true
    - name: pi-home
      mountPath: /home/multica/agents/.pi
      readOnly: true
```

The init container copies `provider-config/codex/` into `~/.codex/` and `provider-config/pi/` into `~/.pi/`. Inputs are read-only; the copies in the controller's private HOME are writable and become part of task HOME archives.

On a new controller Pod, supplied files override image defaults at matching paths. Image defaults at other paths remain available.

Copy destinations must be beneath `/home/multica/agents` and must not overlap or replace runtime-managed state. Source mappings within one volume must not overlap. Omit `subPath` to copy the entire provider directory.

Install or upgrade the release with these values. When provider files change, reapply the ConfigMaps and restart the controller so new tasks receive the updated configuration:

```sh
kubectl -n multica rollout restart deployment/multica-runtime-controller
```

Restart the controller after changing external Secrets as well. Existing workers retain their prepared HOME directories. Finish active tasks before restarting the controller.

For Terraform-managed folders, enumerate files recursively with `fileset(config_root, "**")`, use a hash of each relative path as its ConfigMap key, and preserve the relative path in `items.path`. Set a hash of the configuration contents in `controller.podAnnotations` to trigger a rollout when files change.

## Networking

The controller accepts worker connections on TCP port `8080`; its egress is unrestricted by this chart. Worker ingress is denied. Worker egress is controlled by two independent settings:

```yaml
networkPolicy:
  enabled: true
  blockKubernetesAPI: true
  blockedEgressCIDRs: []
```

| API protection | Blocked CIDRs | Worker egress |
| --- | --- | --- |
| Enabled | Empty | Excludes discovered API IP/TCP port pairs. |
| Disabled | Empty | Unrestricted. |
| Disabled | Supplied | Excludes those networks on all ports. |
| Enabled | Supplied | Applies both restrictions. |

API protection discovers the `default/kubernetes` Service and its EndpointSlices during installation or upgrade. Rendering fails if the Service or backend TCP targets cannot be discovered. Run a Helm upgrade after API addresses change; alternate endpoints, proxies, and load balancers absent from those resources are outside discovery.

`blockedEgressCIDRs` excludes destinations on all ports, including DNS, databases, and the controller when their addresses fall inside a blocked network. Use network CIDRs such as `10.10.10.0/24`, single-address CIDRs such as `10.10.10.10/32`, or IPv6 equivalents. Use `0.0.0.0/0` or `::/0` for a whole address family; supplying both denies all worker egress.

Preview the generated policy against a cluster:

```sh
helm template multica-runtime-controller korioinc/multica-runtime-controller \
  --namespace multica --values values.yaml \
  --kube-context YOUR_CONTEXT --dry-run=server \
  --show-only templates/networkpolicy.yaml
```

Offline rendering requires disabling API discovery explicitly:

```sh
helm template multica-runtime-controller korioinc/multica-runtime-controller \
  --namespace multica --values values.yaml \
  --set networkPolicy.blockKubernetesAPI=false
```

That offline output provides no API egress protection. Setting `networkPolicy.enabled: false` disables both chart-managed policies.

Enforcement depends on the CNI's TCP port range support, `ipBlock` matching, and Service destination translation. Local-node traffic can remain reachable, and other policies selecting workers can add permissions. Verify API isolation on your cluster and use CNI or node firewall controls where standard NetworkPolicy cannot restrict a path.

After deployment, check that new connections to API Service and backend addresses and blocked CIDRs fail, while required DNS, database, controller, and external connections succeed.

## Operations

Changes to worker configuration or chart-managed RBAC trigger controller replacement. Use `controller.podAnnotations` for externally managed configuration changes. Finish active tasks before a planned replacement.

Apply configuration changes with your values file:

```sh
helm upgrade multica-runtime-controller korioinc/multica-runtime-controller \
  --namespace multica --values values.yaml --wait
```

For runtime behavior and custom image development, see the [controller source](https://github.com/korioinc/multica-runtime-controller) and [runtime image source](https://github.com/korioinc/multica-runtime).
