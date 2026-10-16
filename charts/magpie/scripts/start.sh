#!/bin/sh
set -eu
umask 077

mkdir -p /config/magpie
# Seed new installations only. Keep Web UI changes and restored credentials intact.
for name in settings.json providers.json; do
  target="/config/magpie/$name"
  if [ ! -e "$target" ]; then
    temporary=$(mktemp "$target.XXXXXX")
    cat "/bootstrap/$name" > "$temporary"
    chmod 600 "$temporary"
    mv "$temporary" "$target"
  fi
done

exec /magpie "$@"
