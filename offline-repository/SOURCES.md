# Offline payload sources

The release payload is not stored in Git. `SHA256SUMS` is the authoritative
inventory of the files placed in `/etc/passwall-recovery`.

- PassWall 26.8.1 LuCI packages are the OpenWrt 23.05/24.10 assets from the
  [upstream PassWall release](https://github.com/Openwrt-Passwall/openwrt-passwall/releases/tag/26.8.1-1).
- `luci-compat` and `luci-lib-jsonc` come from the official
  [OpenWrt 23.05 package archive](https://downloads.openwrt.org/releases/packages-23.05/aarch64_cortex-a53/luci/)
  and were checked against its published `sha256sums` file.
- The remaining user-space IPKs and Geo data are inherited from the audited
  [GL-MT3600BE v1.1.1 recovery bundle](https://github.com/guajun/gl-mt3600be-passwall-recovery/releases/tag/v1.1.1)
  without binary modification. Their hashes remain pinned in `SHA256SUMS`.

Kernel packages are deliberately excluded. The recovery service installs them
with opkg from the active GL.iNet firmware feed so they match the running
kernel.
