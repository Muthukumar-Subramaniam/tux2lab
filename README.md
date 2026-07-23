# tux2lab — Build Your Own KVM Virtual Home Lab

[![Latest Release](https://img.shields.io/github/v/release/Muthukumar-Subramaniam/tux2lab?label=Latest%20Release&color=green)](https://github.com/Muthukumar-Subramaniam/tux2lab/releases/latest)
[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE)

Transform your Linux workstation into a powerful, automated virtual datacenter —
deploy, break, and rebuild VMs effortlessly. tux2lab automates provisioning,
manages the complete VM lifecycle, and provides a flexible environment for
learning, testing, and experimenting with Linux-based technologies.

Plenty of open-source alternatives may exist; this project was built out of the
sheer fun of creating something from scratch and sharing it with anyone who has
similar interests.

Architecturally, tux2lab is orchestrated by **JBOBS** — *Just a Bunch Of Bash Scripts*.
No frameworks, no extra languages. Just Bash doing what Bash does best.

> [!WARNING]
> This project is intended for testing, development, and experimentation purposes only.

---

## What You'll Get

- Automated VM provisioning via PXE boot & golden images
- Dynamic DNS management for your local domain
- Complete VM lifecycle management — deploy, resize, snapshot, destroy
- Multi-distribution support across Red Hat, Debian, and SUSE families
- Dual-stack networking (IPv4 + IPv6) out of the box
- Containerized infrastructure — all lab services in a single rootful Podman container

---

## Architecture Overview

tux2lab runs on your Linux workstation (the **KVM host**) and creates a private
virtual network (`labbr0` bridge, `10.28.28.0/22` + IPv6 ULA `fd28:2808:2020:3000::/64`) with a
**tux2lab-engine** container that provides all lab services on the gateway IP (`10.28.28.1`):

| Service | Software | Purpose |
|---|---|---|
| DNS | BIND (named) | Local domain resolution |
| DHCP | Kea (v4 + v6) | Automatic IP assignment |
| PXE/TFTP | tftp-server + iPXE | Network boot for OS installs |
| NTP | chrony | Time synchronization |
| NFS | nfs-server | Shared storage |
| HTTP/HTTPS | nginx | Boot ISO & kickstart serving |
| IPv6 RA | radvd | Router advertisements |
| SSH | sshd | Debug access to container |

### Infrastructure Container

All lab services run inside a single **rootful Podman container** (`tux2lab-engine`)
based on AlmaLinux 10. The container uses `--network=host` to bind directly to the
lab bridge interface, providing seamless network access for all guest VMs.

| Feature | Detail |
|---|---|
| **Image** | `ghcr.io/muthukumar-subramaniam/tux2lab-engine:2.0.0` |
| **Runtime** | Podman (rootful, `--network=host --privileged`) |
| **Persistence** | All state in `/tux2lab-data/` (bind-mounted into container) |
| **Lifecycle** | Start/stop/rebuild without touching the host |
| **Resources** | Minimal — shares host kernel, no VM overhead |

---

## Supported Distributions

### Guest VM Provisioning

| Family | Distribution | Versions | Method |
|---|---|---|---|
| Red Hat-based | AlmaLinux, Rocky, Oracle Linux, CentOS Stream | 10, 9, 8 | Kickstart |
| Red Hat-based | RHEL | 10, 9, 8 | Kickstart (via subscription-manager) |
| Debian-based | Ubuntu LTS | 26.04, 24.04, 22.04 | Cloud-init autoinstall |
| Debian-based | Debian | 13, 12, 11 | Preseed (netboot) |
| SUSE-based | openSUSE Leap | 16.0, 15.6 | Agama (16.0), AutoYaST (15.x) |

> Distros are set up automatically when needed — manual `tux2lab distro setup`
> is optional (useful for pre-staging ISOs or managing disk space).

---

## Minimum System Requirements

> These are the minimum recommended values. Adjust based on your workload.

**Guest VMs (each):** 2 GB RAM · 2 vCPUs · 30 GB disk

**KVM Host:** RHEL-based, Ubuntu, or openSUSE (hardware virtualization required).
Podman must be available (installed automatically by setup).

---

## Quick Start

### Step 1 — Get tux2lab

**Download the latest release tarball:**

```bash
sudo mkdir -p /tux2lab
sudo chown "${USER}:$(id -g)" /tux2lab
curl -sSL https://github.com/Muthukumar-Subramaniam/tux2lab/releases/latest/download/tux2lab.tar.gz \
  | tar -xzv -C /tux2lab
```

**For developers/contributors — clone from the repository:**

```bash
sudo mkdir -p /tux2lab
sudo chown "${USER}:$(id -g)" /tux2lab
git clone https://github.com/Muthukumar-Subramaniam/tux2lab.git /tux2lab
```

### Step 2 — Prepare the Host

```bash
/tux2lab/setup/setup-host.sh
```

This script:
- Installs QEMU/KVM, libvirt, Podman, jq, and all dependencies (supports `apt`, `dnf`, `zypper`)
- Grants passwordless sudo to the current user
- Creates the `labbr0` bridge network with dual-stack (IPv4/IPv6) NAT
- Sets up the `/tux2lab-data/` data directory
- Installs the `tux2lab` CLI and bash completion

### Step 3 — Deploy the Lab

```bash
tux2lab deploy
```

The interactive wizard handles:
- Admin password setup
- SSH key and SSL certificate generation (cert trusted by host)
- Service configuration generation (DNS, DHCP, NTP, HTTP, TFTP, NFS)
- Container image pull and startup
- Host DNS, SSH, and SSL trust configuration

The hostname is fixed to `tux2lab-engine` and the domain is automatically set to `<your-username>.internal`.

### Step 4 — Verify Your Lab

```bash
tux2lab health
```

---

## Using tux2lab

### Prepare a Distribution for Provisioning (Optional)

Distros are prepared automatically when you build a golden image or install a VM.
Use these commands to pre-stage ISOs or check status:

```bash
tux2lab distro list                              # Show setup status
tux2lab distro setup almalinux -v 10             # Pre-stage a distro
tux2lab distro cleanup almalinux -v 10           # Remove to free disk space
tux2lab distro cleanup almalinux -v 10 --force   # Skip confirmation
```

### Create a Golden Image (Optional, Recommended)

Golden images let you deploy VMs in seconds instead of running a full PXE install:

```bash
tux2lab golden-image build                       # Interactive
tux2lab golden-image build almalinux -v 10       # Non-interactive
tux2lab golden-image rebuild almalinux -v 10     # Rebuild (or build if none exists)
tux2lab golden-image list                        # Show available images
```

### Deploy VMs

```bash
# From golden image (default — fast disk clone)
tux2lab vm install -H vm1
tux2lab vm install -H vm1 -d almalinux -v 10

# Via PXE boot (full network install)
tux2lab vm install -H vm1 --via-pxe
tux2lab vm install -H vm1 --via-pxe -d ubuntu-lts -v 24.04

# Multiple VMs at once
tux2lab vm install -H vm1,vm2,vm3

# Attach to console during install
tux2lab vm install -H vm1 --via-pxe --console
```

---

## CLI Reference

> Most commands accept `-H vm1,vm2,vm3` for multi-VM operations.

### Distro Management

```
tux2lab distro list               List distributions and setup status
tux2lab distro setup              Prepare a distro for PXE provisioning
tux2lab distro cleanup            Remove a distro's PXE setup
```

### Golden Image Management

```
tux2lab golden-image build        Build a reusable base image via PXE
tux2lab golden-image rebuild      Rebuild (or build if none exists)
tux2lab golden-image list         List available golden images
tux2lab golden-image cleanup      Remove golden image(s)
```

### VM Provisioning

```
tux2lab vm install                Deploy VM(s) [--via-golden (default) | --via-pxe]
tux2lab vm reimage                Reinstall VM(s) [--via-golden (default) | --via-pxe]
```

### VM Operations

```
tux2lab vm list                   List all VMs and their status
tux2lab vm info                   Detailed VM information (all VMs)
tux2lab vm info -H <hostname>     Detailed VM information (specific VM)
tux2lab vm validate               Validate post-install config (all running VMs)
tux2lab vm validate -H <hostname> Validate specific VM(s)
tux2lab vm console -H <hostname>  Attach to serial console (Ctrl+] to exit)
tux2lab vm start -H <hostname>    Power on
tux2lab vm stop -H <hostname>     Force power off
tux2lab vm shutdown -H <hostname> Graceful shutdown via ACPI
tux2lab vm reboot -H <hostname>   Graceful reboot
tux2lab vm restart -H <hostname>  Hard reset (power cycle)
tux2lab vm remove -H <hostname>   Delete VM and all its data
```

### VM Configuration

```
tux2lab vm resize -H <hostname>   Resize memory, CPU, or root disk
tux2lab vm disk-add -H <hostname>    Add a new storage disk
tux2lab vm disk-resize -H <hostname> Resize an additional disk
tux2lab vm disk-attach -H <hostname> Re-attach a previously detached disk
tux2lab vm disk-detach -H <hostname> Detach a disk (preserved in storage)
tux2lab vm disk-delete               Permanently delete detached disk(s)
tux2lab vm nic-add -H <hostname>     Add a network interface
tux2lab vm nic-remove -H <hostname>  Remove a network interface
```

### VM Snapshots

```
tux2lab vm snapshot-create -H <hostname>  Create a snapshot
tux2lab vm snapshot-list -H <hostname>    List snapshots
tux2lab vm snapshot-info -H <hostname>    Show snapshot details
tux2lab vm snapshot-revert -H <hostname>  Revert to a snapshot
tux2lab vm snapshot-delete -H <hostname>  Delete a snapshot
```

### Infrastructure & Network

```
tux2lab start                     Start lab infrastructure (container)
tux2lab stop                      Stop lab infrastructure and shut down all VMs
tux2lab enable                    Enable lab infrastructure auto-start on boot
tux2lab disable                   Disable lab infrastructure auto-start on boot
tux2lab health                    Check all lab service health
tux2lab deploy                    Deploy a new lab infrastructure server
tux2lab destroy                   Permanently destroy the entire lab environment
tux2lab rebuild                   Tear down and redeploy lab using existing config
tux2lab sync                      Sync project updates into the running lab
tux2lab info                      Show lab deployment details
tux2lab dns [options]             Manage DNS records via dnsbinder
tux2lab ipv6-route enable         Add IPv6 route to lab network
tux2lab ipv6-route disable        Remove IPv6 route
tux2lab ipv6-route check          Check IPv6 connectivity and route status
tux2lab ipv6-route auto           Auto-configure based on host IPv6 connectivity
tux2lab ipv6-route status         Show current IPv6 route status
tux2lab version                   Show version information
```

Use `tux2lab --help` or `tux2lab <command> --help` for detailed usage.
Tab completion is available after installation.

---

## Backend Automation

These tools run on the KVM host and power the provisioning pipeline:

| Tool | Purpose |
|---|---|
| **dnsbinder** | Manages BIND DNS zone records — automatic A/AAAA/CNAME/PTR creation and deletion as VMs are created or destroyed |
| **ksmanager** | Orchestrates OS provisioning — generates kickstart/cloud-init/AutoYaST/Agama configs, manages iPXE boot entries, DHCP reservations, and golden image workflows |
| **prepare-distro-for-ksmanager** | Downloads boot ISOs, registers distributions with ksmanager for PXE provisioning |

---

## Project Structure

```
tux2lab/
├── container/                   Container image (Containerfile + entrypoint.sh)
├── setup/                       Host setup and lab deployment scripts
│   ├── setup-host.sh             Prepare KVM host (packages, bridge, podman)
│   ├── deploy-lab.sh             Deploy lab (configs, container, DNS, health)
│   └── generate-service-configs.sh  Generate all service configs from JSON
├── qemu-kvm-manage/             KVM host scripts (VM management)
│   └── scripts-to-manage-vms/    CLI dispatcher and all tux2lab subcommands
├── ks-manage/                   Kickstart/cloud-init templates and ksmanager
├── named-manage/                DNS zone management (dnsbinder)
├── common-utils/                Shared utilities (color output, disk tools)
└── vendor/                      Vendored virt-manager (no system package needed)
```

### Key Data Paths

| Path | Purpose |
|---|---|
| `/tux2lab/` | Project source (scripts, templates) |
| `/tux2lab-data/` | Persistent data volume (mounted into container) |
| `/tux2lab-data/lab-config/` | `lab_environment.json`, SSH keys, SSL certs |
| `/tux2lab-data/named/` | DNS zone files and named.conf |
| `/tux2lab-data/kea/` | DHCP config and lease database |
| `/tux2lab-data/nginx/` | Nginx config |
| `/tux2lab-data/tftpboot/` | iPXE boot files |
| `/tux2lab-data/vms/` | VM disk images |

---

## Support & Contributing

- Found a bug? Have ideas? [Open an issue](https://github.com/Muthukumar-Subramaniam/tux2lab/issues) on GitHub.
- Pull requests are welcome — improve automation, add distros, or enhance docs.

## License

This project is open source and licensed under the [GNU General Public License v3.0](LICENSE).

---

Built for the home lab community.
