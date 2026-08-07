#!/usr/bin/env bash

set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
workdir="$(mktemp -d /tmp/passwall-cloud-client-test.XXXXXX)"
trap 'rm -rf "$workdir"' EXIT HUP INT TERM
mkdir -p "$workdir/bin"
touch "$workdir/id_ed25519" "$workdir/known_hosts"

cat >"$workdir/bin/curl" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == *'/latest/api/token'* ]]; then
  printf 'test-token'
elif [[ "$*" == *'/latest/meta-data/eipv4'* ]]; then
  printf '47.57.180.218'
else
  exit 1
fi
EOF

cat >"$workdir/bin/ssh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >"$SSH_TEST_LOG"
printf 'registered hk 47.57.180.218\n'
EOF
chmod 0755 "$workdir/bin/curl" "$workdir/bin/ssh"

output="$(
  PATH="$workdir/bin:$PATH" \
  CONFIG_FILE=/dev/null \
  SLOT=hk \
  ROUTER_HOST=10.244.71.148 \
  IDENTITY_FILE="$workdir/id_ed25519" \
  KNOWN_HOSTS_FILE="$workdir/known_hosts" \
  SSH_TEST_LOG="$workdir/ssh.log" \
  "$repo_dir/cloud-client/passwall-cloud-direct-register"
)"

grep -q 'registered hk 47.57.180.218' <<<"$output"
grep -q -- 'root@10.244.71.148 lease 47.57.180.218' "$workdir/ssh.log"

echo 'cloud direct client tests passed'
