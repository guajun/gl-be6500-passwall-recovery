#!/bin/sh

set -eu

REPO_DIR="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
RECOVERY_SCRIPT="${RECOVERY_SCRIPT:-$REPO_DIR/files/etc/init.d/passwall-recovery}"
WORKDIR="$(mktemp -d /tmp/passwall-recovery-test.XXXXXX)"
trap 'rm -rf "$WORKDIR"' EXIT HUP INT TERM

mkdir -p "$WORKDIR/bin"

# Remap absolute router executables before sourcing the production functions.
sed \
    -e "s|/etc/init.d/|$WORKDIR/bin/|g" \
    -e "s|^    /usr/bin/xray version|    $WORKDIR/bin/xray version|" \
    -e "s|/usr/sbin/passwall-cloud-direct|$WORKDIR/bin/cloud-direct|g" \
    "$RECOVERY_SCRIPT" > "$WORKDIR/recovery.sh"

cat > "$WORKDIR/bin/service" <<'EOF'
#!/bin/sh
printf '%s %s\n' "${0##*/}" "$*" >> "$TEST_COMMANDS"
EOF
chmod 0755 "$WORKDIR/bin/service"
for command in passwall v2raya v2raya-recovery passwall-cloud-direct cloud-direct xray; do
    cp "$WORKDIR/bin/service" "$WORKDIR/bin/$command"
done

export TEST_COMMANDS="$WORKDIR/commands.log"

for saved_switch in 0 1 absent; do
    for mode in boot manual; do
        for changed in 0 1; do
            (
                . "$WORKDIR/recovery.sh"
                LOCK="$WORKDIR/recovery.lock"
                CHANGED="$changed"
                CLOUD_DIRECT_CHANGED=0
                : > "$TEST_COMMANDS"
                printf '%s\n' "$saved_switch" > "$WORKDIR/main-switch"

                # Model the persisted UCI main switch, including accidental writes.
                uci() {
                    [ "${1:-}" != '-q' ] || shift
                    case "${1:-}" in
                        set)
                            assignment="$2"
                            key="${assignment%%=*}"
                            value="${assignment#*=}"
                            if [ "$key" = 'passwall.@global[0].enabled' ]; then
                                printf '%s\n' "$value" > "$WORKDIR/main-switch"
                            fi
                            printf 'uci set %s\n' "$assignment" >> "$TEST_COMMANDS"
                            ;;
                        commit)
                            printf 'uci commit %s\n' "$2" >> "$TEST_COMMANDS"
                            ;;
                        *) return 1 ;;
                    esac
                }

                # Keep package installation, cache removal, and host services isolated.
                log() { :; }
                ensure_opkg_architecture() { :; }
                verify() { :; }
                ensure_netfilter() { :; }
                install_packages() { :; }
                restore_data() { :; }
                restore_cloud_direct() { :; }
                lua() { :; }
                rm() { :; }

                case "$mode" in
                    boot) start ;;
                    manual) recover ;;
                esac

                actual="$(cat "$WORKDIR/main-switch")"
                if [ "$actual" != "$saved_switch" ]; then
                    printf 'main switch changed from %s to %s during %s recovery (changed=%s)\n' \
                        "$saved_switch" "$actual" "$mode" "$changed" >&2
                    exit 1
                fi

                grep -qx 'uci set passwall.@global_app\[0\].xray_file=/usr/bin/xray' "$TEST_COMMANDS"
                grep -qx 'uci set passwall.@global_rules\[0\].v2ray_location_asset=/usr/share/v2ray/' "$TEST_COMMANDS"
                grep -qx 'uci commit passwall' "$TEST_COMMANDS"
                grep -qx 'cloud-direct sync' "$TEST_COMMANDS"

                if [ "$mode" = manual ]; then
                    grep -qx 'passwall restart' "$TEST_COMMANDS"
                elif [ "$changed" -eq 1 ]; then
                    grep -qx 'passwall start' "$TEST_COMMANDS"
                elif grep -Eq '^passwall (start|restart)$' "$TEST_COMMANDS"; then
                    echo 'unchanged boot recovery restarted PassWall' >&2
                    exit 1
                fi
            )
        done
    done
done

echo 'recovery main-switch tests passed (12 scenarios)'
