PassWall offline recovery repository for GL-BE6500.

The init service runs before PassWall at boot. It verifies SHA256SUMS, restores
missing user-space packages, restores the compact geo data files, and enables
PassWall. Kernel packages are intentionally not stored because their versions
must match the firmware kernel after a sysupgrade.

Manual checks:
  /etc/init.d/passwall-recovery verify
  /etc/init.d/passwall-recovery recover

The recovery service also restores passwall-cloud-direct. That companion
service maintains independent, expiring public IPv4 leases for cloud hosts and
replays its direct-routing rules after PassWall restarts.
