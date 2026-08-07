#!/usr/bin/env bash

set -euo pipefail

SLOT=""
ROUTER_HOST=""
ROUTER_PORT="22"
SOURCE_DIR=""
START_TIMER=1
VERSION="v1.0.2"
REPOSITORY="guajun/gl-be6500-passwall-recovery"
ASSET="passwall-cloud-direct-client-v1.0.2.tar.gz"
ARCHIVE_SHA256="273d47666b8b77b8c6dac4aba69f6d24bccf8dae56eeeff7a56633a7600f0936"
WORKDIR=""

log() {
  printf 'passwall-cloud-direct-client-installer: %s\n' "$*"
}

die() {
  log "ERROR: $*" >&2
  exit 1
}

cleanup() {
  local status="$?"
  trap - EXIT HUP INT TERM
  if [[ -n "$WORKDIR" && -d "$WORKDIR" ]]; then
    rm -rf -- "$WORKDIR"
  fi
  exit "$status"
}

usage() {
  cat <<'EOF'
Usage: install.sh --slot NAME [--router HOST] [--port PORT] [--source-dir DIR]
                  [--no-start]

The installer creates a dedicated SSH key. Add the printed restricted public
key line to /etc/dropbear/authorized_keys on the router, install the router's
host key as described in the output, then start the timer.
EOF
}

while (($#)); do
  case "$1" in
    --slot)
      [[ $# -ge 2 ]] || die "--slot requires a value"
      SLOT="$2"
      shift 2
      ;;
    --router)
      [[ $# -ge 2 ]] || die "--router requires a value"
      ROUTER_HOST="$2"
      shift 2
      ;;
    --port)
      [[ $# -ge 2 ]] || die "--port requires a value"
      ROUTER_PORT="$2"
      shift 2
      ;;
    --source-dir)
      [[ $# -ge 2 ]] || die "--source-dir requires a value"
      SOURCE_DIR="$2"
      shift 2
      ;;
    --no-start)
      START_TIMER=0
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      die "unknown argument: $1"
      ;;
  esac
done

[[ $EUID -eq 0 ]] || die "run as root"
[[ "$SLOT" =~ ^[a-z0-9][a-z0-9_-]*$ ]] || die "--slot is required and must contain only a-z, 0-9, _ or -"
[[ -n "$ROUTER_HOST" ]] || die "--router is required"
[[ "$ROUTER_PORT" =~ ^[0-9]+$ ]] || die "invalid SSH port"

for command in curl ssh ssh-keygen systemctl install; do
  command -v "$command" >/dev/null 2>&1 || die "$command is required"
done

if [[ -z "$SOURCE_DIR" ]]; then
  command -v sha256sum >/dev/null 2>&1 || die "sha256sum is required"
  command -v tar >/dev/null 2>&1 || die "tar is required"
  WORKDIR="$(mktemp -d /tmp/passwall-cloud-direct-client.XXXXXX)"
  trap cleanup EXIT HUP INT TERM
  url="https://github.com/$REPOSITORY/releases/download/$VERSION/$ASSET"
  log "downloading $url"
  curl --fail --silent --show-error --location --retry 3 "$url" -o "$WORKDIR/$ASSET"
  printf '%s  %s\n' "$ARCHIVE_SHA256" "$WORKDIR/$ASSET" | sha256sum -c -
  while IFS= read -r path; do
    case "$path" in
      passwall-cloud-direct-register|passwall-cloud-direct-client.service|passwall-cloud-direct-client.timer) ;;
      *) die "unexpected client archive path: $path" ;;
    esac
  done < <(tar -tzf "$WORKDIR/$ASSET")
  tar -xzf "$WORKDIR/$ASSET" -C "$WORKDIR"
  SOURCE_DIR="$WORKDIR"
fi
for file in passwall-cloud-direct-register passwall-cloud-direct-client.service passwall-cloud-direct-client.timer; do
  [[ -f "$SOURCE_DIR/$file" ]] || die "missing source file: $SOURCE_DIR/$file"
done

install -d -m 0700 /etc/passwall-cloud-direct-client
install -m 0755 "$SOURCE_DIR/passwall-cloud-direct-register" /usr/local/sbin/passwall-cloud-direct-register
install -m 0644 "$SOURCE_DIR/passwall-cloud-direct-client.service" /etc/systemd/system/passwall-cloud-direct-client.service
install -m 0644 "$SOURCE_DIR/passwall-cloud-direct-client.timer" /etc/systemd/system/passwall-cloud-direct-client.timer

if [[ ! -f /etc/passwall-cloud-direct-client/id_ed25519 ]]; then
  ssh-keygen -q -t ed25519 -N '' -C "passwall-cloud-direct-$SLOT" \
    -f /etc/passwall-cloud-direct-client/id_ed25519
fi
chmod 0600 /etc/passwall-cloud-direct-client/id_ed25519
chmod 0644 /etc/passwall-cloud-direct-client/id_ed25519.pub

cat >/etc/default/passwall-cloud-direct-client <<EOF
SLOT="$SLOT"
ROUTER_HOST="$ROUTER_HOST"
ROUTER_PORT="$ROUTER_PORT"
IDENTITY_FILE="/etc/passwall-cloud-direct-client/id_ed25519"
KNOWN_HOSTS_FILE="/etc/passwall-cloud-direct-client/known_hosts"
RETRIES="6"
RETRY_DELAY="20"
EOF
chmod 0644 /etc/default/passwall-cloud-direct-client

systemctl daemon-reload
systemctl enable passwall-cloud-direct-client.timer

public_key="$(cat /etc/passwall-cloud-direct-client/id_ed25519.pub)"
log "add this single restricted key line to /etc/dropbear/authorized_keys on the router:"
printf '%s\n' "no-port-forwarding,no-agent-forwarding,no-X11-forwarding,no-pty,command=\"/usr/sbin/passwall-cloud-direct authorized $SLOT\" $public_key"
log "pin the router host key in /etc/passwall-cloud-direct-client/known_hosts before starting the timer"

if [[ "$START_TIMER" -eq 1 && -s /etc/passwall-cloud-direct-client/known_hosts ]]; then
  systemctl start passwall-cloud-direct-client.timer
  systemctl start passwall-cloud-direct-client.service
else
  log "timer enabled but not started; enroll the key and pin the router host key first"
fi
