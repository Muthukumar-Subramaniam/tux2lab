# Security Policy

## Intended Use

tux2lab builds a disposable virtual lab on a Linux workstation, for testing,
development and experimentation. It is not designed for production use, and it
is not designed to host workloads you do not trust.

Several deliberate trade-offs favour unattended automation over isolation. They
are listed below so you can decide whether they suit your environment.

## Trust Boundary

**The lab network is a single trust domain.** Every guest VM, and the KVM host,
are effectively equivalent within it.

Lab services bind only to the bridge addresses (`10.28.28.1` and the IPv6 ULA).
They are not exposed on your LAN, your VPN, or any other host interface. The lab
subnet is private and NAT'd outbound only, and the IPv6 range is a unique local
address block, so neither is routable from outside the machine.

In practice, only two things can reach the lab services: the KVM host itself,
and the guest VMs you create.

## Deliberate Design Decisions

**Passwordless sudo on the host.** `setup-host.sh` grants the invoking user
unrestricted `NOPASSWD` sudo. The CLI drives libvirt, podman, systemd, NFS
exports and network configuration, each of which is root-equivalent on its own,
so a narrower rule would offer the appearance of restriction rather than the
substance.

**A shared SSH keypair across guests.** Every guest receives the same lab
keypair, which is what makes host-to-guest and guest-to-guest access work
without manual setup. A guest that is compromised can therefore reach the other
guests. The key is not authorized on the KVM host, so it does not lead back to
your workstation.

**Lab credentials are served over HTTP on the bridge.** Network installers run
before the operating system exists and hold no credentials, so anything they
need must be fetchable anonymously. The SSH keypair, the admin password hash and
the CA certificate are served this way. This is inherent to unattended network
provisioning rather than specific to tux2lab.

**Host key checking is disabled for lab hosts.** Guests are reimaged frequently
and their host keys change, so the generated SSH config sets
`StrictHostKeyChecking no` for lab addresses. Interception on the lab network
would not be detected.

**The infrastructure container is privileged.** It runs rootful with
`--network=host` and `--privileged` so it can bind low ports on the bridge and
serve DHCP, DNS and PXE.

**Lab configuration is world readable on the workstation.** Files under
`/tux2lab-data` are mode 644 because the container's web server reads them as an
unprivileged user. Any local account on the workstation can read them, without
needing access to the lab network.

## Recommendations

- Do not bridge the lab network to an untrusted network.
- Do not run workloads inside lab VMs that you would not run on the host.
- Use your own SSH key for access to the KVM host. The lab key is for guests.
- Treat the lab keypair as disposable and do not reuse it elsewhere.
- On a shared workstation, remember that any local user can read the lab
  credentials directly from disk.
- Rotate credentials with `tux2lab credentials` if a lab VM is ever exposed to
  something untrusted.

## Reporting a Vulnerability

Please report security issues privately to **msmkumar.eee@gmail.com** rather
than opening a public issue.

Include what you found, how to reproduce it, and what an attacker would gain.
Reports that fall outside the trust boundary described above are still welcome,
since that boundary may itself be wrong.
