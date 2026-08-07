# GL-BE6500 PassWall recovery

This repository backs up the small custom recovery layer used to keep PassWall
available after a GL.iNet firmware sysupgrade on the GL-BE6500. It is an
independent, device-specific adaptation of
[`gl-mt3600be-passwall-recovery`](https://github.com/guajun/gl-mt3600be-passwall-recovery).
It is not a PassWall fork and it does not modify PassWall or Xray source code.

## What the service does

At boot, `passwall-recovery`:

1. verifies the offline payload against `SHA256SUMS`;
2. installs missing PassWall user-space packages from that payload;
3. installs firmware-matched netfilter modules from the GL.iNet package feed;
4. restores the Xray geo data and symlinks;
5. enables PassWall and starts it only when recovery changed the installation.

It also restores the `passwall-cloud-direct` service. That service keeps
short-lived public IPv4 leases in a dedicated `pwr_cloud_direct` ipset and
places matching `RETURN` rules before PassWall's TCP redirect and UDP TPROXY
rules. It does not edit subscriptions, proxy nodes, or PassWall's rule files.

Kernel packages are intentionally not stored offline. Their versions must match
the kernel in the newly installed firmware.

## One-line installation

Run this as `root` on a GL-BE6500. Git and SSH agent forwarding are not
required:

```sh
uclient-fetch -qO- https://raw.githubusercontent.com/guajun/gl-be6500-passwall-recovery/v1.0.2/installer.sh | sh
```

The versioned installer verifies the GL-BE6500 model, IPQ5332 board, and native
`aarch64_cortex-a53_neon-vfpv4` package architecture, checks the release archive
against a pinned SHA-256 digest, rejects unsafe
archive entries, and verifies every offline payload file before installation.
It preserves the old recovery directory until PassWall recovery succeeds and
rolls back that directory if installation fails.

The payload uses the ABI-compatible OpenWrt `aarch64_cortex-a53` user-space
architecture. The installer registers that architecture through a dedicated
opkg configuration file. It does not use `--force-architecture`, unpack IPKs by
hand, or overwrite package-owned binaries. Kernel packages always come from the
active GL.iNet firmware feed so their versions match the running kernel.

To test only the download and verification path:

```sh
uclient-fetch -qO- https://raw.githubusercontent.com/guajun/gl-be6500-passwall-recovery/v1.0.2/installer.sh | sh -s -- --verify-only
```

## Files on the router

```text
/etc/init.d/passwall-recovery
/etc/passwall-recovery/
/etc/rc.d/S98passwall-recovery -> ../init.d/passwall-recovery
/etc/init.d/passwall-cloud-direct
/usr/sbin/passwall-cloud-direct
/etc/opkg/passwall-recovery.conf
```

## Dynamic Aliyun direct routing

Each cloud host has an independent slot and a dedicated SSH key. The key is
restricted by Dropbear to one forced command, so it cannot open a router shell,
forward ports, or change another host's lease. Clients renew every five minutes;
the router expires a missing client after two hours. A changed public IP
replaces the old address on the next successful renewal.

Install a client on each cloud host:

```sh
curl -fsSL \
  https://github.com/guajun/gl-be6500-passwall-recovery/releases/latest/download/install-cloud-direct-client.sh \
  | sudo bash -s -- --slot hk --router ROUTER_ZEROTIER_IP --no-start
```

Use a different slot such as `sz` for the other instance. The installer prints
one restricted public-key line. Add that line to
`/etc/dropbear/authorized_keys` on the router. Obtain the router's public host
key and fingerprint locally:

```sh
dropbearkey -y -f /etc/dropbear/dropbear_ed25519_host_key
```

Pin that public key as `ROUTER_ZEROTIER_IP ssh-ed25519 ...` in
`/etc/passwall-cloud-direct-client/known_hosts` on the cloud host, then run:

```sh
systemctl start passwall-cloud-direct-client.timer
systemctl start passwall-cloud-direct-client.service
```

Check the live leases and rule counters on the router:

```sh
/usr/sbin/passwall-cloud-direct status
ipset list pwr_cloud_direct
iptables-save | grep passwall-cloud-direct
```

The renewal path uses ZeroTier only as a control channel. If official Planet
connectivity and every Moon path are all unavailable immediately after a public
IP change, renewal cannot bootstrap itself; use the separate ZeroTier path
diagnostic and manually register the current address as a recovery action.

The entries in [`sysupgrade.conf.snippet`](sysupgrade.conf.snippet) preserve the
recovery layer and the local PassWall configuration during sysupgrade.

## Offline payload

The IPK and Geo files are third-party binary artifacts. They are published in
the versioned GitHub Release archive rather than committed to Git history.
[`offline-repository/SHA256SUMS`](offline-repository/SHA256SUMS) records the
exact payload currently installed on the router so it can be audited. Package
provenance is documented in
[`offline-repository/SOURCES.md`](offline-repository/SOURCES.md).

The expected layout is:

```text
/etc/passwall-recovery/
|-- README.txt
|-- SHA256SUMS
|-- data/
|   |-- geoip-only-cn-private.dat
|   `-- geosite.dat
`-- packages/
    `-- *.ipk
```

Manual verification and recovery:

```sh
/etc/init.d/passwall-recovery verify
/etc/init.d/passwall-recovery recover
```

## Manual restoration

1. Restore the offline payload to `/etc/passwall-recovery` and verify it with
   `sha256sum -c SHA256SUMS` from that directory.
2. Copy [`files/etc/init.d/passwall-recovery`](files/etc/init.d/passwall-recovery)
   to `/etc/init.d/passwall-recovery` and set mode `0755`.
3. Append only the missing lines from `sysupgrade.conf.snippet` to
   `/etc/sysupgrade.conf`.
4. Run `/etc/init.d/passwall-recovery enable`, then
   `/etc/init.d/passwall-recovery recover`.

This repository intentionally excludes `/etc/config/passwall`, subscription
data, node credentials, SSH keys, databases, logs, and router backups. The
`.gitignore` also blocks the common paths and file types for those values.
