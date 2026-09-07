#!/bin/bash
set -euo pipefail
umask 022
: "${ENV_ROOT:?}" "${ENV_PLATFORM:?}" "${ENV_MANIFEST_FILE:?}" "${ENV_PROVIDERS:?}"
# This complete environment policy has no imports from the runtime core.
NODE_VERSION=26.7.0
case "$ENV_PLATFORM" in
  linux/amd64)
    arch=x64; deb_arch=amd64; triplet=x86_64-linux-gnu
    node_sha=bd6b6c31e377bad9ad579bed72e5bc11f4c879ac9452ad51d30e646ea3d828df
    atomic_sha=fbd4e154a6b444229ea002cc209df099209c0adc09102e5fd21239a3d2b55e2d
    agy_sha=f874d4f6b8a73c2df660f580f25fb656fcb6e64adbfd746e6692e837fd9a20be ;;
  linux/arm64)
    arch=arm64; deb_arch=arm64; triplet=aarch64-linux-gnu
    node_sha=925aa6157dd37542d0d7f2e28b7bf61e7b39284411210b0498bc3788db4aef68
    atomic_sha=1693aa13ce2b30d061a519fc28b77b9bab8c8e45804ced5969d99821e1bc2159
    agy_sha=97fc9fe5a6067406cd02cbe4ae6e362c9623a24d33bec486911246c17ceb6a94 ;;
  *) echo 'unsupported environment platform' >&2; exit 1 ;;
esac
mkdir -p "$HOME" "$ENV_ROOT/node" "$ENV_ROOT/bin" "$ENV_ROOT/providers" "$ENV_ROOT/home"
task_tmp=$(mktemp -d "${TMPDIR:-/tmp}/bootstrap.XXXXXXXX")
trap 'rm -rf "$task_tmp"' EXIT
curl -fsSL "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-${arch}.tar.gz" -o "$task_tmp/node.tar.gz"
printf '%s  %s\n' "$node_sha" "$task_tmp/node.tar.gz" | sha256sum -c -
tar -xzf "$task_tmp/node.tar.gz" --strip-components=1 -C "$ENV_ROOT/node"
# The SCM image lacks libatomic required by arm64 Node. Keep this pinned
# userland library within tools; no root filesystem package installation occurs.
curl -fsSL "https://deb.debian.org/debian/pool/main/g/gcc-12/libatomic1_12.2.0-14+deb12u1_${deb_arch}.deb" -o "$task_tmp/libatomic.deb"
printf '%s  %s\n' "$atomic_sha" "$task_tmp/libatomic.deb" | sha256sum -c -
dpkg-deb -x "$task_tmp/libatomic.deb" "$task_tmp/libatomic"
mkdir -p "$ENV_ROOT/lib" "$ENV_ROOT/node/libexec"
cp -a "$task_tmp/libatomic/usr/lib/$triplet/"libatomic.so* "$ENV_ROOT/lib/"
mv "$ENV_ROOT/node/bin/node" "$ENV_ROOT/node/libexec/node"
cat > "$ENV_ROOT/node/bin/node" <<'NODEWRAP'
#!/bin/bash
export LD_LIBRARY_PATH=/opt/multica/environment/lib
exec /opt/multica/environment/node/libexec/node "$@"
NODEWRAP
chmod 0555 "$ENV_ROOT/node/bin/node"
export PATH="$ENV_ROOT/node/bin:$PATH"
export npm_config_cache="$task_tmp/npm-cache"
export npm_config_update_notifier=false
# Pin the directly selected package bytes. npm verifies integrity of transitive
# and optional dependencies while resolving their ranges on first preparation.
install_npm() {
  local id="$1" package="$2" version="$3" integrity="$4" alias="$5" file="$task_tmp/$1.tgz"
  curl -fsSL "https://registry.npmjs.org/${package}/-/${package##*/}-${version}.tgz" -o "$file"
  node - "$file" "$integrity" <<'NODE'
const fs = require('node:fs'), crypto = require('node:crypto');
const actual = 'sha512-' + crypto.createHash('sha512').update(fs.readFileSync(process.argv[2])).digest('base64');
if (actual !== process.argv[3]) throw new Error('npm package integrity mismatch');
NODE
  mkdir -p "$ENV_ROOT/providers/$id"
  npm install --prefix "$ENV_ROOT/providers/$id" --ignore-scripts --no-audit --no-fund --save-exact "$file"
  # The local install tarball is not a runtime input.
  rm -f "$ENV_ROOT/providers/$id/package-lock.json"
  printf '#!/bin/bash\nexec /opt/multica/environment/providers/%s/node_modules/.bin/%s "$@"\n' "$id" "$alias" > "$ENV_ROOT/providers/$id/run"
  chmod 0555 "$ENV_ROOT/providers/$id/run"
  "$ENV_ROOT/providers/$id/run" --version | grep -F -- "$version"
}
install_npm codex @openai/codex 0.153.4 'sha512-wbHDmit7S/YvBGVX1DQmk13xtWblZ2cApeJ/pB7xDZ10Cna+DZc5ij7f0F4OxdsXN4FW1oLT48OpogUI1+8Y2w==' codex
install_npm copilot @github/copilot 1.0.83 'sha512-M8uZI0V0dahYV1KZij3nGDxaXEGG7I7YUZzQPI7NEZkL/83Nl/tNTbPdxKtdWZbOmWoXsPKXty/eEYoj6RHDhA==' copilot
install_npm pi @earendil-works/pi-coding-agent 0.85.0 'sha512-INxVkLAVfAMju5MojJpmyu/0bMP+r+ffZuS7UqVv32E2JwHBRbcHfELDfmFNvapEbgYfKN2r9OYO1p3TqDBR+g==' pi
curl -fsSL "https://github.com/google-antigravity/antigravity-cli/releases/download/1.1.27/agy_cli_linux_${arch}.tar.gz" -o "$task_tmp/agy.tar.gz"
printf '%s  %s\n' "$agy_sha" "$task_tmp/agy.tar.gz" | sha256sum -c -
mkdir -p "$ENV_ROOT/providers/antigravity"
tar -xzf "$task_tmp/agy.tar.gz" -C "$ENV_ROOT/providers/antigravity"
cat > "$ENV_ROOT/providers/antigravity/run" <<'AGY'
#!/bin/bash
exec /opt/multica/environment/providers/antigravity/antigravity "$@"
AGY
chmod 0555 "$ENV_ROOT/providers/antigravity/run" "$ENV_ROOT/providers/antigravity/antigravity"
"$ENV_ROOT/providers/antigravity/run" --version | grep -F '1.1.27'
node - <<'NODE'
const fs = require('node:fs');
const versions = {pi:'0.85.0',codex:'0.153.4',copilot:'1.0.83',antigravity:'1.1.27'};
const enabled = JSON.parse(process.env.ENV_PROVIDERS);
if (!Array.isArray(enabled) || !enabled.length || enabled.some(id => !Object.hasOwn(versions, id))) throw new Error('invalid enabled providers');
fs.writeFileSync(process.env.ENV_MANIFEST_FILE, JSON.stringify({
  schemaVersion:1,
  providers:Object.fromEntries(enabled.map(id => [id,{entrypoint:`providers/${id}/run`,version:versions[id]}])),
  binDirs:['node/bin','bin'],
  env:{npm_config_cache:'${HOME}/.cache/npm'}, homeSeed:'home',
  checks:[{argv:['node/bin/node','--version'],timeoutSeconds:10}]
}) + '\n');
NODE
