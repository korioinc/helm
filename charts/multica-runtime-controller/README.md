# multica-runtime-controller

The official Multica daemon runs in an operator-selected environment. Every
approved provider task runs in its own Kubernetes Pod, using the same core
artifact, environment image digest, platform and immutable tools generation.
Tools and workspace use separate PVCs. Workers receive only their validated
workspace storage binding, never the controller's full PVC root.

## Configure an execution environment

Chart 0.3.0 leaves the environment image, provider list and bootstrap script
unconfigured. Rendering without those inputs fails before any Pod is created.
No language or provider installation is selected automatically. The chart requires
runtime core 0.3.39 or later for configuration copying and contract version 1.
Upgrade the chart and its pinned core together; older cores cannot run the new
layout arguments.

Select your digest-pinned image, at least one installed provider and a bootstrap
in your values file. For example, an image with its own bootstrap entrypoint can
use this configuration after replacing the image reference:

```yaml
environment:
  image:
    reference: registry.example.com/team/agent-environment@sha256:<image-digest>
  providers: [codex]
  bootstrap:
    source: inline
    revision: operator-1
    script: |
      #!/bin/sh
      exec /usr/local/share/multica/bootstrap.sh
```

The entrypoint path above is an operator-image example, not a file supplied by
the core. Bootstrap must prepare `environment.json` and the selected provider
entrypoints under `ENV_ROOT`, even when all tools are already installed in the
image. It may prepare existing tools without downloading or installing anything.
Core then checks the manifest, provider versions and executable fingerprints.

For an existing ConfigMap, select `source: configMap`, set `configMap.name`,
`configMap.key` and the lowercase SHA-256 of its exact script bytes in
`configMap.sha256`, and leave `script` empty. Init snapshots and verifies the
script before execution. `source: inline` uses only the supplied `script`.

Install after supplying that environment configuration, the controller token
Secret and storage settings for your cluster:

```sh
helm upgrade --install multica-runtime-controller ./charts/multica-runtime-controller \
  --namespace multica --create-namespace \
  -f values.yaml \
  --set-string multica.baseURL=https://multica.example.com \
  --set-string multica.controllerTokenSecret.name=multica-controller-token
```

Use Kubernetes 1.36+, Helm 3 or 4, Linux amd64 or arm64, and storage supporting
POSIX locks, atomic rename, fsync and executable files. Set `environment.platform`
to the image platform used by your cluster. Old combined runtime images are
incompatible. A different compatible core release can be selected through
`runtime.image.reference`.

The controller has one replica and uses Recreate. Its chart-owned identity Secret
preserves the daemon/store owner ID. Reinstallation uses empty workspace and tools
PVCs. No legacy reader, data migration or fallback to the old runtime is included.
The chart does not render or retain the old `multica-runtime-workspace` claim.
Prepare any credentials needed from an old installation before replacing it.

Each storage block has `existingClaim`, `size`, `storageClass` and `accessMode`.
Leave `existingClaim` empty for chart-owned `<fullname>-workspace` and
`<fullname>-tools` claims. For an existing empty claim, or a new-format store from
the same installation, set `existingClaim` and set `size` and `storageClass` to
empty strings. Generated claims follow normal Helm lifecycle; external claims
remain operator-owned. The two claims must differ.

## Explicit installer examples

`source: bundled` is an opt-in compatibility example. It selects
[node-providers.sh](files/environments/node-providers.sh), which installs Node
26.7.0, Pi 0.85.0, Codex 0.153.4, Copilot 1.0.83 and Antigravity 1.1.27 into
`/opt/multica/environment`. It installs all four provider packages; the explicit
`environment.providers` list controls which providers the runtime exposes.
This example is never selected by the chart's default values.

To choose that installer, explicitly supply its base image and provider list:

```yaml
environment:
  image:
    reference: docker.io/library/buildpack-deps:bookworm-scm@sha256:4274ea4975976f86239384ac206f98af5f0978fd8f054886eec1371fc7664025
  providers: [pi, codex, copilot, antigravity]
  bootstrap:
    source: bundled
    script: ""
```

The example checksum-verifies Node/Antigravity archives and directly selected npm
archives. npm verifies transitive integrity but resolves dependency ranges during
first preparation. The example extracts the pinned libatomic library into tools
for arm64 Node; it does not install OS packages into the container root filesystem.
The first successful generation is immutable; change the revision for a new one.

Other complete, optional examples remain available:

- [go-rust.sh](files/environments/go-rust.sh) installs the same Node/provider set
  plus checksum-pinned Go 1.26.1 and Rust 1.97.1.
- [Dockerfile.php-python](files/environments/Dockerfile.php-python) and
  [php-python.sh](files/environments/php-python.sh) provide an operator-built image
  with PHP CLI/curl and Python venv support plus the complete provider installer.

Both require an explicit image, provider list and inline script. For example:

```sh
helm template example charts/multica-runtime-controller \
  --set-string environment.image.reference=docker.io/library/buildpack-deps:bookworm-scm@sha256:4274ea4975976f86239384ac206f98af5f0978fd8f054886eec1371fc7664025 \
  --set-json 'environment.providers=["pi","codex","copilot","antigravity"]' \
  --set-string environment.bootstrap.source=inline \
  --set-string environment.bootstrap.revision=go-rust-1 \
  --set-file environment.bootstrap.script=charts/multica-runtime-controller/files/environments/go-rust.sh

docker build -f charts/multica-runtime-controller/files/environments/Dockerfile.php-python \
  -t operator-php-python:local charts/multica-runtime-controller/files/environments
# Publish your image and use its digest as OPERATOR_IMAGE_DIGEST.
helm template example charts/multica-runtime-controller \
  --set-string environment.image.reference="$OPERATOR_IMAGE_DIGEST" \
  --set-json 'environment.providers=["pi","codex","copilot","antigravity"]' \
  --set-string environment.bootstrap.source=inline \
  --set-string environment.bootstrap.revision=php-python-1 \
  --set-file environment.bootstrap.script=charts/multica-runtime-controller/files/environments/php-python.sh
```

## Bootstrap contract

Bootstrap receives `ENV_ROOT`, `ENV_PLATFORM`, `ENV_REVISION`, `ENV_INPUTS_FILE`
(the non-secret string map), `ENV_MANIFEST_FILE` and `ENV_PROVIDERS` (JSON).
`environment.bootstrap.env` participates in identity. Installation-only Secrets
belong in `environment.bootstrap.secretEnvFrom`; they are not supplied to main
or task containers. `timeout` is seconds, including child-process completion and
validation. Bootstrap can write only its generation and private tmp. Surviving
children or a timeout fail preparation.

The script writes `environment.json` with provider entrypoints/versions, confined
`binDirs`, environment variables, optional non-secret `homeSeed` and argv-array
checks. All provider probes and checks must pass. Writable caches/sessions belong
in HOME or workspace. Never put auth tokens, rollout or session files in the seed.
Installer and consumers mount the identical `/opt/multica/environment` prefix;
directories are never moved after installation, preserving absolute shebangs.

Bootstrap owns the installed provider and language contents: it can replace
entrypoints, patch packages and write non-secret defaults into `homeSeed` before
validation. It runs as UID/GID 65532 with a read-only container root filesystem,
so install into `ENV_ROOT` rather than `/usr` or `/usr/local`. Languages absent
from the execution image can be downloaded and unpacked there; required shared
libraries must also be supplied by bootstrap or the chosen image. All downloads,
versions, checksums and upgrade policy belong to the operator's script. Changing
the script, its non-secret inputs or revision creates a new tools generation.
Runtime package self-updates cannot change an already prepared generation.

For writable provider defaults, create files such as
`$ENV_ROOT/home/.codex/config.toml` and
`$ENV_ROOT/home/.pi/agent/settings.json`, then set `homeSeed: "home"` in the
manifest. Core copies missing seed files into each Pod's private writable HOME.
Operator configuration copies described below take precedence over seed defaults.
Authentication belongs in operator configuration inputs, never the tools generation.

## Storage and credential boundaries

The environment ID hashes canonical JSON of `schemaVersion`, `coreImage`,
`environmentImage`, `platform`, `scriptSHA256`, `revision`, sorted unique
`providers`, and `inputs`. Changing the core digest also creates a new generation.
Helm and Go sort object keys and use HTML escaping with no trailing newline.
Secret values are excluded. Atomic READY metadata publishes `generations/<id>`;
content digests and provider fingerprints identify actual installed bytes.
Ready generations are read-only to main and workers and are not automatically
garbage collected. Failed preparation does not fall back to another generation.

RWX permits multiple nodes. If either PVC is RWO, `scheduling.singleNodeName` is
required. Controller and workers retain required affinity to Node `metadata.name`,
including after controller recreation. Hostname labels are not Node identities.
An absent fixed Node leaves Pods Pending; automatic cross-node RWO failover is
unsupported. ReadWriteOncePod is rejected. Declare existing claim modes accurately.
`nodeSelector` and `tolerations` apply to workers too; platform conflicts fail
rendering.

Only materialization mounts the Pod core emptyDir read-write. Consumers run as
UID/GID 65532 with core/tools and root filesystem read-only. A credential-free
init captures image defaults before prepare receives installation credentials.
Bootstrap receives no workspace, controller token, operator settings or task
auth. The Kubernetes API token and worker-config Secret are mounted only into
main; automatic ServiceAccount token mounting is disabled. `imagePullSecrets`
apply to all core and environment image pulls.

The controller mounts workspace root for checkout preparation and durable
recovery. Workers receive one validated subPath and private HOME/tmp. Pi sessions
are separate from home seed; continuation needs the same scope and EnvironmentRef.
Changing environments preserves workspace files and starts a fresh Pi session.
Global Codex HOME or rollout sharing is not added.

`operator.envFrom` and `operator.env` configure controller/provider/task execution.
Worker settings are stored in a chart-owned Secret, mounted only into main, so
inline operator values do not enter the environment ConfigMap. Values are literal;
Kubernetes `$(VAR)` expansion is rejected. Use `valueFrom.secretKeyRef` or
`valueFrom.configMapKeyRef` for aliases.

ConfigMap, Secret and projected `operator.configVolumes` supply initial provider
configuration. Each `operator.configMounts` entry selects a source volume and
optional `subPath`; its `mountPath` is the destination under
`/home/multica/agents`. The controller's `workspace-layout` and each worker's HOME
layout init mount those inputs read-only under `/opt/multica/config-input/`, then
copy their files into private HOME. The main containers receive the writable
copies, without the configuration input mounts. `readOnly: true` describes the
input mount, not the copied file.

Both individual files and directories such as `.codex`, `.pi`, `.pi/agent` and
`.multica` are supported. This lets providers change settings, refresh an
`auth.json`, create plugins and customize their native directories. Files are
private to UID 65532 (mode 0600, with the source owner executable bit preserved);
directories use mode 0700. Copies create missing files only, so existing files
survive an init retry. Input configuration is copied before `homeSeed`, so it
wins over bootstrap defaults. Copying is per file, not an atomic directory swap.

The runtime rejects configuration targeting or containing protected
`.multica/config.json`, `.multica/pi-sessions`, `.codex/skills` and
`.pi/agent/sessions` paths, including empty directories, and rejects files that
would replace their parent directories. These paths belong to daemon authority,
assigned skills or persisted task sessions. Directory sources must omit them.
PVC configuration inputs are unsupported. See
[the RWX example](ci/values-rwx.yaml).

Use `controller.podAnnotations` for controller rollout annotations, such as a
checksum computed from native provider configuration. Configuration files stay
in each Pod's writable HOME for that Pod's lifetime. ConfigMap and Secret updates
are picked up by a new Pod; they do not overwrite running provider changes.
Pod replacement resets HOME to current inputs and defaults; local settings and
credential refreshes are not written back to Kubernetes Secrets. The chart always
controls `multica.io/environment-id`, `checksum/worker-config` and `checksum/config`;
custom annotations cannot override them.

Provider credentials retain their remote authorization scope. Per-task local
storage isolation does not narrow a token's GitHub permissions. Provider code can
use its own credentials. Installation and execution credentials have separate
inputs and mount boundaries.

## Verification and release

Inspect `core-materialize`, `workspace-layout`, `environment-defaults` and
`environment-prepare` logs when a Pod remains in init. Main readiness combines
verified environment startup with `/healthz`. Offline CLI probes establish
installation/entrypoint execution; authentication and external model services
need operational verification. Arbitrary operator scripts may print their own
secrets. Runtime diagnostics omit full argv, prompts and task env values.

Run repository-owned verification from the Helm repository:

```sh
scripts/verify-chart.sh --ci
# Verifies the released core on both platforms, then renders explicit fixtures.
scripts/verify-chart.sh --release
```

CI supplies a clearly marked synthetic core pin and explicit image, providers and
bootstrap choices for six render/schema profiles. Release verification checks the
actual default core artifact and uses that pin with the same explicit environment
fixtures. Bare defaults are intentionally not a runnable environment. The checks
cover updater behavior, shell syntax, Helm lint/template, Kubernetes 1.36 schema
validation and packaging. Rendering alone does not prove actual provider,
filesystem or Kubernetes stream behavior. The runtime repository offers an
explicit integration command accepting this chart path for Docker/K3s proof.

The hourly/manual updater resolves stable GHCR tags. Before updating, it inspects
both native core artifacts without running their contents: contract version,
platform, release label and executable file hashes must agree. It changes only
`runtime.image.reference`, chart/app versions and core annotations. Environment
image, bootstrap and operator input remain untouched. The first core pin populated
chart 0.2.0; subsequent updates bump the chart patch version.

The updater commits directly to main and dispatches `release.yml`; it does not
create a PR. Release revalidates the actual core pin before publishing a GitHub
Release archive and the gh-pages Helm index. An empty or old incompatible core
cannot be published by this workflow; execution-environment inputs remain the
operator's responsibility. The initial contract change must reach
main before allowing the updater to consume a new core release.
