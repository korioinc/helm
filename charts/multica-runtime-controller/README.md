# multica-runtime-controller

The official Multica daemon runs in an operator-selected environment. Every
approved provider task runs in its own Kubernetes Pod, using the same core
artifact, environment image digest, platform and immutable tools generation.
Tools and workspace use separate PVCs. Workers receive only their validated
workspace storage binding, never the controller's full PVC root.

## Installation

Use Kubernetes 1.36+, Helm 3 or 4, Linux amd64 or arm64, and storage supporting
POSIX locks, atomic rename, fsync and executable files. Supply an existing
controller token Secret and two different PVCs or provisioners. Chart 0.2.0 ships
with runtime core 0.3.38 implementing contract version 1, pinned to OCI index digest
`sha256:779d5dc58d1602f5989feed279e7900f306a89ff25904c5e6ed43b49de7049f9`
for both supported architectures. Old combined runtime images are incompatible.
To select another compatible core release, optionally override
`runtime.image.reference` with its digest-pinned reference.

```sh
helm upgrade --install multica-runtime-controller ./charts/multica-runtime-controller \
  --namespace multica --create-namespace \
  --set-string multica.baseURL=https://multica.example.com \
  --set-string multica.controllerTokenSecret.name=multica-controller-token \
  --set-string environment.platform=linux/arm64 \
  --set-string environment.storage.storageClass=shared-filesystem \
  --set-string workspace.storage.storageClass=shared-filesystem
```

The controller has one replica and uses Recreate. Its chart-owned identity Secret
preserves the daemon/store owner ID. Reinstallation uses empty workspace and tools
PVCs. No legacy reader, data migration or fallback to the old runtime is included.
The new chart does not render or retain the old `multica-runtime-workspace` claim.
Prepare any credentials needed from an old installation before replacing it.

Each storage block has `existingClaim`, `size`, `storageClass` and `accessMode`.
Leave `existingClaim` empty for chart-owned `<fullname>-workspace` and
`<fullname>-tools` claims. For an existing empty claim, or a new-format store from
the same installation, set `existingClaim` and set `size` and `storageClass` to
empty strings. Generated claims follow normal Helm lifecycle; external claims
remain operator-owned. The two claims must differ.

## Default and custom environments

The bundled profile pins `buildpack-deps:bookworm-scm` to OCI index digest
`sha256:4274ea4975976f86239384ac206f98af5f0978fd8f054886eec1371fc7664025`.
It installs Node 26.7.0, Pi 0.85.0, Codex 0.153.4, Copilot 1.0.83 and Antigravity
1.1.27 under `/opt/multica/environment`. Node/Antigravity archives and directly
selected npm archives are checksum verified. npm checks transitive integrity,
but resolves transitive version ranges during first preparation. The first
successful generation is immutable; change the revision for a fresh install.

The SCM base lacks libatomic required by arm64 Node. Bootstrap extracts the
checksum-pinned Debian library into tools; only the Node wrapper selects that
library path. Bootstrap never installs OS packages into its read-only container
root filesystem. The core contains no provider or language installer.

`environment.providers` enables `pi`, `codex`, `copilot`, or `antigravity`
(executable alias `agy`). The bundled script installs all four packages and
exposes exactly the enabled set. Installing other executables does not create
runtime providers. Backend custom runtime profiles are unsupported.

All example scripts are complete and independent:

- [default.sh](files/environments/default.sh): Node and the provider packages.
- [go-rust.sh](files/environments/go-rust.sh): the complete default profile plus
  checksum-pinned Go 1.26.1 and Rust 1.97.1; writable caches use native HOME.
- [Dockerfile.php-python](files/environments/Dockerfile.php-python) and
  [php-python.sh](files/environments/php-python.sh): an operator-built image with
  PHP CLI/curl and Python venv support, plus the complete provider bootstrap.
  The script creates a venv at its final prefix and runs its pip shebang and a
  PHP curl-extension check. Image package versions resolve during image build;
  deployment pins the resulting digest. PHP-FPM ports/services are not provided.

```sh
# --set-file preserves script bytes, including the final newline.
helm template multica-runtime-controller charts/multica-runtime-controller \
  --set-string environment.bootstrap.source=inline \
  --set-string environment.bootstrap.revision=go-rust-1 \
  --set-file environment.bootstrap.script=charts/multica-runtime-controller/files/environments/go-rust.sh

# Build and publish this image through your image release process before use.
docker build -f charts/multica-runtime-controller/files/environments/Dockerfile.php-python \
  -t operator-php-python:local charts/multica-runtime-controller/files/environments
helm template multica-runtime-controller charts/multica-runtime-controller \
  --set-string environment.image.reference="$OPERATOR_IMAGE_DIGEST" \
  --set-string environment.bootstrap.source=inline \
  --set-string environment.bootstrap.revision=php-python-1 \
  --set-file environment.bootstrap.script=charts/multica-runtime-controller/files/environments/php-python.sh
```

For an existing ConfigMap, use `source: configMap`, `configMap.name`,
`configMap.key` and lowercase SHA-256 of the exact bytes in `configMap.sha256`;
leave `script` empty. Helm does not look up its contents. Init snapshots and
hashes the script before execution. `source: bundled` uses the bundled file;
`source: inline` uses `script`.

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
`valueFrom.configMapKeyRef` for aliases. ConfigMap, Secret and projected
`operator.configVolumes` can be mounted read-only under `/home/multica/agents`,
including individual `.codex/auth.json` or `.pi/agent/auth.json` files. Runtime,
workspace authority and selected session paths cannot be replaced. PVC config
mounts are unsupported. See [the RWX example](ci/values-rwx.yaml).

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
# Requires a real, released default core pin; validates both artifact platforms.
scripts/verify-chart.sh --release
```

CI uses a clearly marked synthetic core pin for six render/schema profiles.
It runs updater checks, shell syntax, Helm lint/template, Kubernetes 1.36 schema
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
cannot be published by this workflow. The initial contract change must reach
main before allowing the updater to consume a new core release.
