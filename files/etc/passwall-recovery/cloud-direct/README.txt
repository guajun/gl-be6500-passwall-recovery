PassWall dynamic cloud direct-routing layer.

The pwr_cloud_direct ipset contains short-lived public IPv4 leases. Matching
destinations return before PassWall's TCP redirect and UDP TPROXY rules. The
daemon re-adds its rules after PassWall or firewall restarts.

Cloud keys must be restricted in /etc/dropbear/authorized_keys:

  no-port-forwarding,no-agent-forwarding,no-X11-forwarding,no-pty,command="/usr/sbin/passwall-cloud-direct authorized hk" ssh-ed25519 AAAA... cloud-direct-hk

The matching cloud client sends only "lease IPv4" or "clear". Each key is
fixed to one slot. Leases expire after two hours unless renewed.

Manual checks:

  /usr/sbin/passwall-cloud-direct status
  ipset list pwr_cloud_direct
  iptables-save | grep passwall-cloud-direct
