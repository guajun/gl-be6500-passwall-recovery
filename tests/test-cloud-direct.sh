#!/bin/sh

set -eu

REPO_DIR="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
ROUTER_SCRIPT="$REPO_DIR/files/etc/passwall-recovery/cloud-direct/passwall-cloud-direct"
WORKDIR="$(mktemp -d /tmp/passwall-cloud-direct-test.XXXXXX)"
trap 'rm -rf "$WORKDIR"' EXIT HUP INT TERM

mkdir -p "$WORKDIR/bin" "$WORKDIR/leases"

cat > "$WORKDIR/bin/ipset" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$TEST_LOG"
exit 0
EOF

cat > "$WORKDIR/bin/iptables" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$TEST_LOG"
case " $* " in
    *" -nL "*) exit 0 ;;
    *" -C "*) exit 1 ;;
    *) exit 0 ;;
esac
EOF
chmod 0755 "$WORKDIR/bin/ipset" "$WORKDIR/bin/iptables"

export STATE_DIR="$WORKDIR/leases"
export LOCK_DIR="$WORKDIR/lock"
export IPSET_BIN="$WORKDIR/bin/ipset"
export IPTABLES_BIN="$WORKDIR/bin/iptables"
export TEST_LOG="$WORKDIR/commands.log"

SSH_ORIGINAL_COMMAND='lease 47.57.180.218' sh "$ROUTER_SCRIPT" authorized hk |
    grep -qx 'registered hk 47.57.180.218'
grep -qx '47.57.180.218' "$WORKDIR/leases/hk"
grep -qx 'add pwr_cloud_direct 47.57.180.218 -exist' "$TEST_LOG"
[ "$(grep -c -- '-I PSW 1 .*passwall-cloud-direct.*RETURN' "$TEST_LOG")" -eq 2 ]
[ "$(grep -c -- '-I PSW_OUTPUT 1 .*passwall-cloud-direct.*RETURN' "$TEST_LOG")" -eq 2 ]

if SSH_ORIGINAL_COMMAND='lease 47.57.180.218;touch /tmp/bad' \
    sh "$ROUTER_SCRIPT" authorized hk >/dev/null 2>&1; then
    echo 'unsafe authorized command was accepted' >&2
    exit 1
fi
if SSH_ORIGINAL_COMMAND='lease 192.168.8.1' \
    sh "$ROUTER_SCRIPT" authorized hk >/dev/null 2>&1; then
    echo 'private address was accepted' >&2
    exit 1
fi

: > "$TEST_LOG"
NOW=4102444800 LEASE_SECONDS=1 sh "$ROUTER_SCRIPT" sync
[ ! -e "$WORKDIR/leases/hk" ]
if grep -q '^add pwr_cloud_direct ' "$TEST_LOG"; then
    echo 'expired address remained in the direct set' >&2
    exit 1
fi

sh "$ROUTER_SCRIPT" register sz 120.24.52.245 >/dev/null
sh "$ROUTER_SCRIPT" clear sz | grep -qx 'cleared sz'
[ ! -e "$WORKDIR/leases/sz" ]

echo 'cloud direct router tests passed'
