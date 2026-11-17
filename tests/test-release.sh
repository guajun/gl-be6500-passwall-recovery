#!/usr/bin/env bash

set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
release_dir="$(cd "${1:?usage: test-release.sh RELEASE_DIR}" && pwd)"
workdir="$(mktemp -d /tmp/passwall-release-test.XXXXXX)"
trap 'rm -rf "$workdir"' EXIT HUP INT TERM

for installer in installer.sh cloud-client/install.sh; do
  version="$(sed -n 's/^VERSION="\([^"]*\)"/\1/p' "$repo_dir/$installer")"
  asset="$(sed -n 's/^ASSET="\([^"]*\)"/\1/p' "$repo_dir/$installer")"
  expected="$(sed -n 's/^ARCHIVE_SHA256="\([^"]*\)"/\1/p' "$repo_dir/$installer")"
  [[ "$asset" == *"-$version.tar.gz" ]]
  actual="$(sha256sum "$release_dir/$asset" | awk '{print $1}')"
  [[ "$actual" == "$expected" ]] || {
    echo "archive digest does not match $installer: $asset" >&2
    exit 1
  }
  (cd "$release_dir" && sha256sum -c "$asset.sha256")
done

tar -xzf "$release_dir/gl-be6500-passwall-recovery-$version.tar.gz" -C "$workdir"
cmp "$repo_dir/files/etc/init.d/passwall-recovery" "$workdir/etc/init.d/passwall-recovery"
cmp "$repo_dir/files/etc/passwall-recovery/README.txt" "$workdir/etc/passwall-recovery/README.txt"
(cd "$workdir/etc/passwall-recovery" && sha256sum -c SHA256SUMS)

# Exercise the packaged script, so source-only fixes cannot pass release validation.
RECOVERY_SCRIPT="$workdir/etc/init.d/passwall-recovery" sh "$repo_dir/tests/test-recovery.sh"
tar -xzf "$release_dir/passwall-cloud-direct-client-$version.tar.gz" -C "$workdir"
cmp "$repo_dir/cloud-client/passwall-cloud-direct-register" "$workdir/passwall-cloud-direct-register"
echo 'release archive and installer tests passed'
