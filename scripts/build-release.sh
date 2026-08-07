#!/usr/bin/env bash

set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
base_archive="${1:-}"
output_dir="${2:-$repo_dir/dist}"
version="${3:-v1.0.1}"
workdir=""

die() {
  printf 'build-release: ERROR: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  local status="$?"
  trap - EXIT HUP INT TERM
  if [[ -n "$workdir" && -d "$workdir" ]]; then
    rm -rf -- "$workdir"
  fi
  exit "$status"
}

[[ -f "$base_archive" ]] || die "usage: $0 BASE_RECOVERY_ARCHIVE [OUTPUT_DIR] [VERSION]"
[[ "$version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "invalid version: $version"
for command in sha256sum tar; do
  command -v "$command" >/dev/null 2>&1 || die "$command is required"
done

workdir="$(mktemp -d /tmp/passwall-recovery-build.XXXXXX)"
trap cleanup EXIT HUP INT TERM
mkdir -p "$workdir/router" "$workdir/client" "$output_dir"
tar -xzf "$base_archive" -C "$workdir/router"

[[ -d "$workdir/router/etc/passwall-recovery/packages" ]] || die "base archive has no package payload"
[[ -d "$workdir/router/etc/passwall-recovery/data" ]] || die "base archive has no data payload"

cp "$repo_dir/files/etc/init.d/passwall-recovery" "$workdir/router/etc/init.d/passwall-recovery"
chmod 0755 "$workdir/router/etc/init.d/passwall-recovery"
cp "$repo_dir/files/etc/passwall-recovery/README.txt" "$workdir/router/etc/passwall-recovery/README.txt"
rm -rf -- "$workdir/router/etc/passwall-recovery/cloud-direct"
cp -a "$repo_dir/files/etc/passwall-recovery/cloud-direct" "$workdir/router/etc/passwall-recovery/cloud-direct"
cp "$repo_dir/offline-repository/SHA256SUMS" "$workdir/router/etc/passwall-recovery/SHA256SUMS"

(
  cd "$workdir/router/etc/passwall-recovery"
  sha256sum -c SHA256SUMS
)

router_name="gl-be6500-passwall-recovery-$version.tar.gz"
tar --sort=name --mtime='UTC 2020-01-01' --owner=0 --group=0 --numeric-owner \
  -czf "$output_dir/$router_name" -C "$workdir/router" etc
(
  cd "$output_dir"
  sha256sum "$router_name" > "$router_name.sha256"
)

for file in passwall-cloud-direct-register passwall-cloud-direct-client.service passwall-cloud-direct-client.timer; do
  cp "$repo_dir/cloud-client/$file" "$workdir/client/$file"
done
chmod 0755 "$workdir/client/passwall-cloud-direct-register"
client_name="passwall-cloud-direct-client-$version.tar.gz"
tar --sort=name --mtime='UTC 2020-01-01' --owner=0 --group=0 --numeric-owner \
  -czf "$output_dir/$client_name" -C "$workdir/client" \
  passwall-cloud-direct-register \
  passwall-cloud-direct-client.service \
  passwall-cloud-direct-client.timer
(
  cd "$output_dir"
  sha256sum "$client_name" > "$client_name.sha256"
)

printf 'build-release: created %s and %s\n' "$output_dir/$router_name" "$output_dir/$client_name"
