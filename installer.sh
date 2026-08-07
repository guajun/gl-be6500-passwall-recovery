#!/bin/sh

set -eu

VERSION="v1.0.0"
REPOSITORY="guajun/gl-be6500-passwall-recovery"
ASSET="gl-be6500-passwall-recovery-v1.0.0.tar.gz"
ARCHIVE_SHA256="de467560a9f561a45fd33c5e9403f8310d1db6bc66af0fa9564d341f8a17ab61"

VERIFY_ONLY=0
WORKDIR=""
NEW_REPOSITORY=""
OLD_REPOSITORY=""
NEW_INIT=""
SWAPPED=0
HAD_REPOSITORY=0
HAD_INIT=0
WAS_ENABLED=0
OPKG_ARCH_CONFIG="/etc/opkg/passwall-recovery.conf"
HAD_OPKG_ARCH_CONFIG=0

log() {
    printf '%s\n' "passwall-recovery-installer: $*"
}

die() {
    log "ERROR: $*" >&2
    exit 1
}

usage() {
    cat <<'EOF'
Usage: installer.sh [--verify-only]

  --verify-only  Download and verify the release without changing the router.
EOF
}

download() {
    local url="$1"
    local destination="$2"

    if command -v uclient-fetch >/dev/null 2>&1; then
        uclient-fetch -q -O "$destination" "$url"
    elif command -v wget >/dev/null 2>&1; then
        wget -q -O "$destination" "$url"
    elif command -v curl >/dev/null 2>&1; then
        curl -fL --retry 3 -o "$destination" "$url"
    else
        die "uclient-fetch, wget, or curl is required"
    fi
}

safe_remove_tree() {
    case "$1" in
        /tmp/passwall-recovery-installer.*|/etc/passwall-recovery|/etc/passwall-recovery.new.*|/etc/passwall-recovery.old.*)
            [ ! -e "$1" ] || rm -rf "$1"
            ;;
        *)
            die "refusing to remove unexpected path: $1"
            ;;
    esac
}

rollback() {
    log "installation failed; restoring the previous recovery layer"

    /etc/init.d/passwall-recovery disable >/dev/null 2>&1 || true

    if [ "$HAD_INIT" -eq 1 ]; then
        cp -p "$WORKDIR/passwall-recovery.init.backup" /etc/init.d/passwall-recovery
    else
        rm -f /etc/init.d/passwall-recovery
    fi

    safe_remove_tree /etc/passwall-recovery
    if [ "$HAD_REPOSITORY" -eq 1 ] && [ -e "$OLD_REPOSITORY" ]; then
        mv "$OLD_REPOSITORY" /etc/passwall-recovery
    fi

    if [ "$WAS_ENABLED" -eq 1 ] && [ -x /etc/init.d/passwall-recovery ]; then
        /etc/init.d/passwall-recovery enable >/dev/null 2>&1 || true
    fi

    if [ "$HAD_OPKG_ARCH_CONFIG" -eq 1 ]; then
        cp -p "$WORKDIR/passwall-recovery.opkg.backup" "$OPKG_ARCH_CONFIG"
    else
        rm -f "$OPKG_ARCH_CONFIG"
    fi
}

cleanup() {
    local status="$?"
    trap - EXIT HUP INT TERM

    if [ "$status" -ne 0 ] && [ "$SWAPPED" -eq 1 ]; then
        rollback
    fi

    if [ -n "$NEW_REPOSITORY" ]; then
        safe_remove_tree "$NEW_REPOSITORY"
    fi
    case "$NEW_INIT" in
        /etc/init.d/passwall-recovery.new.*)
            rm -f "$NEW_INIT"
            ;;
        '') ;;
        *)
            die "refusing to remove unexpected init path: $NEW_INIT"
            ;;
    esac
    if [ -n "$WORKDIR" ]; then
        safe_remove_tree "$WORKDIR"
    fi

    exit "$status"
}

validate_platform() {
    local model board

    model="$(uci -q get TRL.TRL.modelNum 2>/dev/null || true)"
    board="$(cat /tmp/sysinfo/board_name 2>/dev/null || true)"
    [ "$model" = "BE6500" ] || die "unsupported model: ${model:-unknown}"
    [ "$board" = "qcom,ipq5332-ap-mi01.2" ] ||
        die "unsupported board: ${board:-unknown}"

    command -v opkg >/dev/null 2>&1 || die "opkg is unavailable"
    opkg print-architecture | grep -q '^arch aarch64_cortex-a53_neon-vfpv4 ' ||
        die "aarch64_cortex-a53_neon-vfpv4 package architecture is required"
}

install_opkg_arch_config() {
    [ ! -L "$OPKG_ARCH_CONFIG" ] ||
        die "opkg architecture config must not be a symlink"

    if [ -e "$OPKG_ARCH_CONFIG" ]; then
        HAD_OPKG_ARCH_CONFIG=1
        cp -p "$OPKG_ARCH_CONFIG" "$WORKDIR/passwall-recovery.opkg.backup"
    fi

    printf '%s\n' 'arch aarch64_cortex-a53 5' > "$WORKDIR/passwall-recovery.opkg.conf"
    cp "$WORKDIR/passwall-recovery.opkg.conf" "$OPKG_ARCH_CONFIG"
    chmod 0644 "$OPKG_ARCH_CONFIG"
    opkg print-architecture | grep -q '^arch aarch64_cortex-a53 ' ||
        die "cannot register the compatible payload architecture"
}

validate_archive_paths() {
    local path
    local list="$WORKDIR/archive.list"

    tar -tzf "$WORKDIR/$ASSET" > "$list" || die "cannot list release archive"
    [ -s "$list" ] || die "release archive is empty"

    while IFS= read -r path; do
        case "$path" in
            /*|../*|*/../*|*/..)
                die "unsafe archive path: $path"
                ;;
        esac

        case "$path" in
            etc|etc/|etc/init.d|etc/init.d/|etc/init.d/passwall-recovery|etc/passwall-recovery|etc/passwall-recovery/|etc/passwall-recovery/*)
                ;;
            *)
                die "unexpected archive path: $path"
                ;;
        esac
    done < "$list"

    grep -qxF 'etc/init.d/passwall-recovery' "$list" ||
        die "recovery init script is missing from archive"
    grep -qxF 'etc/passwall-recovery/SHA256SUMS' "$list" ||
        die "offline repository checksum file is missing from archive"

    tar -tzvf "$WORKDIR/$ASSET" |
        awk '$1 !~ /^[-d]/ { bad=1 } END { exit bad }' ||
        die "archive contains a non-regular entry"
}

verify_payload() {
    local repository="$1"

    (
        cd "$repository"
        sha256sum -c SHA256SUMS
    ) || die "offline repository integrity check failed"
}

ensure_sysupgrade_line() {
    local line="$1"

    grep -qxF "$line" /etc/sysupgrade.conf 2>/dev/null ||
        printf '%s\n' "$line" >> /etc/sysupgrade.conf
}

case "${1:-}" in
    '') ;;
    --verify-only) VERIFY_ONLY=1 ;;
    -h|--help)
        usage
        exit 0
        ;;
    *)
        usage >&2
        exit 2
        ;;
esac
[ "$#" -le 1 ] || {
    usage >&2
    exit 2
}

validate_platform
command -v sha256sum >/dev/null 2>&1 || die "sha256sum is unavailable"
command -v tar >/dev/null 2>&1 || die "tar is unavailable"

WORKDIR="$(mktemp -d /tmp/passwall-recovery-installer.XXXXXX)" ||
    die "cannot create temporary directory"
trap cleanup EXIT
trap 'exit 130' HUP INT TERM

URL="https://github.com/$REPOSITORY/releases/download/$VERSION/$ASSET"
log "downloading $URL"
download "$URL" "$WORKDIR/$ASSET" || die "release download failed"

ACTUAL_SHA256="$(sha256sum "$WORKDIR/$ASSET" | awk '{print $1}')"
[ "$ACTUAL_SHA256" = "$ARCHIVE_SHA256" ] ||
    die "release archive SHA-256 mismatch"

validate_archive_paths
mkdir "$WORKDIR/extracted"
tar -xzf "$WORKDIR/$ASSET" -C "$WORKDIR/extracted" ||
    die "cannot extract release archive"

[ -f "$WORKDIR/extracted/etc/init.d/passwall-recovery" ] ||
    die "recovery init script is not a regular file"
[ ! -L "$WORKDIR/extracted/etc/init.d/passwall-recovery" ] ||
    die "recovery init script must not be a symlink"
[ -d "$WORKDIR/extracted/etc/passwall-recovery" ] ||
    die "offline repository is not a directory"
[ ! -L "$WORKDIR/extracted/etc/passwall-recovery" ] ||
    die "offline repository must not be a symlink"

verify_payload "$WORKDIR/extracted/etc/passwall-recovery"
log "release $VERSION verified"

if [ "$VERIFY_ONLY" -eq 1 ]; then
    log "verification-only mode completed; no router files were changed"
    exit 0
fi

[ "$(id -u)" = "0" ] || die "installation must run as root"

NEW_REPOSITORY="/etc/passwall-recovery.new.$$"
OLD_REPOSITORY="/etc/passwall-recovery.old.$$"
[ ! -e "$NEW_REPOSITORY" ] || die "temporary repository path already exists"
[ ! -e "$OLD_REPOSITORY" ] || die "backup repository path already exists"

mkdir "$NEW_REPOSITORY"
cp -a "$WORKDIR/extracted/etc/passwall-recovery/." "$NEW_REPOSITORY/"
verify_payload "$NEW_REPOSITORY"

if [ -e /etc/init.d/passwall-recovery ]; then
    HAD_INIT=1
    cp -p /etc/init.d/passwall-recovery "$WORKDIR/passwall-recovery.init.backup"
fi
if [ -L /etc/rc.d/S98passwall-recovery ]; then
    WAS_ENABLED=1
fi

NEW_INIT="/etc/init.d/passwall-recovery.new.$$"
cp "$WORKDIR/extracted/etc/init.d/passwall-recovery" "$NEW_INIT"
chmod 0755 "$NEW_INIT"

if [ -e /etc/passwall-recovery ]; then
    HAD_REPOSITORY=1
    mv /etc/passwall-recovery "$OLD_REPOSITORY"
fi
SWAPPED=1
mv "$NEW_REPOSITORY" /etc/passwall-recovery
NEW_REPOSITORY=""
mv "$NEW_INIT" /etc/init.d/passwall-recovery
NEW_INIT=""

install_opkg_arch_config

/etc/init.d/passwall-recovery enable || die "cannot enable recovery service"
/etc/init.d/passwall-recovery recover || die "PassWall recovery failed"

ensure_sysupgrade_line '/etc/passwall-recovery/'
ensure_sysupgrade_line '/etc/config/passwall'
ensure_sysupgrade_line '/etc/config/passwall_server'
ensure_sysupgrade_line '/etc/init.d/passwall-recovery'
ensure_sysupgrade_line '/etc/rc.d/S98passwall-recovery'
ensure_sysupgrade_line '/etc/init.d/passwall-cloud-direct'
ensure_sysupgrade_line '/etc/rc.d/S99passwall-cloud-direct'
ensure_sysupgrade_line '/usr/sbin/passwall-cloud-direct'
ensure_sysupgrade_line '/etc/dropbear/authorized_keys'
ensure_sysupgrade_line '/etc/opkg/passwall-recovery.conf'

SWAPPED=0
if [ "$HAD_REPOSITORY" -eq 1 ]; then
    safe_remove_tree "$OLD_REPOSITORY"
fi

log "installation completed successfully"
