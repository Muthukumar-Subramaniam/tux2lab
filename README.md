# tux2lab — Build Your Own QEMU/KVM Virtual Home Lab

[![Latest Release](https://img.shields.io/github/v/release/Muthukumar-Subramaniam/tux2lab?label=Latest%20Release)](https://github.com/Muthukumar-Subramaniam/tux2lab/releases/latest)
[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE)

Transform your Linux workstation into a powerful, automated virtual datacenter.
Build and manage a virtual home lab, making it easy to deploy, break, and rebuild
Linux VMs effortlessly. tux2lab automates VM provisioning, manages the complete
lifecycle of your VMs, and provides a flexible environment for learning, testing,
and experimenting with Linux-based technologies.

Although many open-source alternatives exist, I built this project for the fun
of creating something of my own and sharing it with anyone with similar interests.

> [!WARNING]
> This project is intended for testing, development, and experimentation purposes only.

> [!NOTE]
> This project is in active development (pre-v1.0). APIs and structure may change.

---

## What You'll Get

- Automated VM provisioning via PXE boot & golden images
- Dynamic DNS management for your local domain
- Full infrastructure-as-code automation (Ansible)
- Complete VM lifecycle management — deploy, resize, snapshot, destroy
- Multi-distribution support across Red Hat, Debian, and SUSE families
- Dual-stack networking (IPv4 + IPv6) out of the box

---

## Architecture Overview

tux2lab runs on your Linux workstation (the **KVM host**) and creates a private
virtual network (`labbr0` bridge, `10.10.20.0/22` + IPv6 [ULA](https://en.wikipedia.org/wiki/Unique_local_address) `fd00::/64`) with a central
**infrastructure server** that provides all lab services:

| Service | Software | Purpose |
|---|---|---|
| DNS | BIND (named) | Local domain resolution |
| DHCP | Kea (v4 + v6) | Automatic IP assignment |
| PXE/TFTP | tftp-server + iPXE | Network boot for OS installs |
| NTP | chrony | Time synchronization |
| NFS | nfs-server | Shared storage |
| HTTP | nginx | ISO & kickstart file serving |
| IPv6 RA | radvd | Router advertisements |

### Deployment Modes

| | **VM Mode** (Recommended) | **Host Mode** (Advanced) |
|---|---|---|
| **Where** | Dedicated KVM VM | Directly on KVM host |
| **Isolation** | Complete — easy to delete/recreate | None — modifies host system |
| **Resources** | 2 GB RAM, 2 vCPUs, 30 GB disk | Minimal overhead |
| **Best for** | Most users, shared systems | Owned systems with limited RAM |
| **Cleanup** | Delete the VM | Manual service/package removal |

---

## Supported Distributions

### Infra Server OS (RHEL-based only)

AlmaLinux 10 (default), Rocky Linux, Oracle Linux, CentOS Stream, RHEL — versions 10 and 9.

### Guest VM Provisioning

| Family | Distribution | Method | Status |
|---|---|---|---|
| Red Hat-based | AlmaLinux | Kickstart | ✅ Included by default |
| | Rocky, Oracle Linux, RHEL, CentOS Stream | Kickstart | 🔧 Customizable |
| Debian-based | Ubuntu LTS (24.04, 22.04) | Cloud-init autoinstall | 🔧 Customizable |
| SUSE-based | openSUSE Leap (15.6, 15.5) | AutoYaST | 🔧 Customizable |

---

## Minimum System Requirements

> These are the minimum recommended values. Adjust based on your workload.

**Central Infra Server VM:** 2 GB RAM · 2 vCPUs · 30 GB disk

**Guest VMs (each):** 2 GB RAM · 2 vCPUs · 20 GB disk

**KVM Host:** Ubuntu or AlmaLinux/RHEL-based with hardware virtualization support.

---

## Quick Start

### Step 1 — Get tux2lab

**Download the latest [stable release](https://github.com/Muthukumar-Subramaniam/tux2lab/releases/latest):**

```bash
sudo mkdir -p /tux2lab
sudo chown "${USER}:$(id -g)" /tux2lab
curl -sSL https://github.com/Muthukumar-Subramaniam/tux2lab/releases/latest/download/tux2lab.tar.gz \
  | tar -xzv -C /tux2lab
cd /tux2lab/qemu-kvm-manage/
```

**For developers/contributors — clone from the repository:**

```bash
sudo mkdir -p /tux2lab
sudo chown "${USER}:$(id -g)" /tux2lab
git clone https://github.com/Muthukumar-Subramaniam/tux2lab.git /tux2lab
cd /tux2lab/qemu-kvm-manage/
```

### Step 2 — Install QEMU/KVM

```bash
./setup-qemu-kvm.sh
```

This script:
- Installs QEMU/KVM, libvirt, and all dependencies (supports both `apt` and `dnf`)
- Creates the `tux2lab` virtual network (`labbr0` bridge) with NAT
- Sets up the `/tux2lab-data/` data directory
- Installs the `tux2lab` CLI and bash completion
- Validates your system is not a VM (bare-metal host required)

### Step 3 — Download Infra Server ISO

```bash
./download-infra-server-iso.sh              # AlmaLinux (default)
./download-infra-server-iso.sh rocky        # Rocky Linux
./download-infra-server-iso.sh oraclelinux  # Oracle Linux
```

Downloads the ISO, fetches the checksum, and verifies integrity via SHA256.

### Step 4 — Deploy the Lab Infrastructure Server

```bash
./deploy-lab-infra-server.sh
```

The interactive wizard will guide you through:
- Choosing a hostname and domain (default: `lab.local`)
- Setting an admin user and password
- Selecting VM mode (recommended) or Host mode
- Configuring SSH keys for passwordless access

**What happens next (VM mode):**

1. A kickstart file is generated from your inputs
2. `virt-install` creates and boots the infra server VM
3. AlmaLinux installs unattended via kickstart
4. First reboot — SSH keys, network normalization
5. Ansible playbook configures all lab services (DNS, DHCP, PXE, NFS, nginx, etc.)
6. Second reboot — lab is ready
7. Press `Ctrl + ]` to exit the console when you see the login prompt

### Step 5 — Verify Your Lab

```bash
tux2lab health
```

```
KVM Lab Infra Health Check
Lab Infra Server Mode: VM
Lab Infra Server     : lab-infra-server.lab.local

[ ✓ ] DNS Server           [ 53/tcp  ]
[ ✓ ] DHCP Server          [ 67/udp  ]
[ ✓ ] NTP Server           [ 123/udp ]
[ ✓ ] TFTP Server          [ 69/udp  ]
[ ✓ ] NFS Server           [ 2049/tcp ]
[ ✓ ] Web Server           [ 80/tcp  ]

Status: STABLE
```

---

## Using tux2lab

### Prepare a Distribution for Provisioning

Before deploying VMs, set up at least one distro for PXE boot:

```bash
tux2lab distro setup                             # Interactive
tux2lab distro setup almalinux --version 10      # Non-interactive
tux2lab distro list                              # Show setup status
```

### Create a Golden Image (Optional, Recommended)

Golden images let you deploy VMs in seconds instead of running a full PXE install:

```bash
tux2lab golden-image create                      # Interactive
tux2lab golden-image create -d almalinux -v 10   # Non-interactive
tux2lab golden-image list                        # Show available images
```

### Deploy VMs

```bash
# From golden image (fast — disk clone)
tux2lab vm install-golden vm1
tux2lab vm install-golden vm1 -d almalinux -v 10

# Via PXE boot (full network install)
tux2lab vm install-pxe vm1
tux2lab vm install-pxe vm1 -d ubuntu-lts -v 24.04

# Multiple VMs at once
tux2lab vm install-golden -H vm1,vm2,vm3

# Attach to console during install
tux2lab vm install-pxe vm1 --console
```

---

## CLI Reference

### VM Operations

```
tux2lab vm list                   List all VMs and their status
tux2lab vm info <hostname>        Detailed VM information
tux2lab vm console <hostname>     Attach to serial console (Ctrl+] to exit)
tux2lab vm start <hostname>       Power on
tux2lab vm stop <hostname>        Force power off
tux2lab vm shutdown <hostname>    Graceful shutdown via ACPI
tux2lab vm reboot <hostname>      Graceful reboot
tux2lab vm restart <hostname>     Hard reset (power cycle)
tux2lab vm remove <hostname>      Delete VM and all its data
```

### VM Provisioning

```
tux2lab vm install-golden         Deploy from golden image
tux2lab vm install-pxe            Deploy via PXE network boot
tux2lab vm reimage-golden         Wipe and reinstall from golden image
tux2lab vm reimage-pxe            Wipe and reinstall via PXE
```

### VM Configuration

```
tux2lab vm resize <hostname>      Resize memory, CPU, or root disk
tux2lab vm disk-add <hostname>    Add a new storage disk
tux2lab vm disk-resize <hostname> Resize an additional disk
tux2lab vm disk-attach <hostname> Re-attach a previously detached disk
tux2lab vm disk-detach <hostname> Detach a disk (preserved in storage)
tux2lab vm disk-delete <hostname> Permanently delete a detached disk
tux2lab vm nic-add <hostname>     Add a network interface
tux2lab vm nic-remove <hostname>  Remove a network interface
```

### Golden Image Management

```
tux2lab golden-image create       Build a reusable base image via PXE
tux2lab golden-image list         List available golden images
tux2lab golden-image cleanup      Remove unused golden images
```

### Infrastructure & Network

```
tux2lab start                     Start lab infrastructure (host mode)
tux2lab health                    Check all lab service health
tux2lab dns [options]             Manage DNS records via dnsbinder
tux2lab distro list               List distributions and setup status
tux2lab distro setup              Prepare a distro for PXE provisioning
tux2lab distro cleanup            Remove a distro's PXE setup
tux2lab ipv6-route [action]       Manage IPv6 routes (enable/disable/auto/status)
```

Use `tux2lab --help` or `tux2lab <command> --help` for detailed usage.
Tab completion is available after installation.

---

## Backend Automation

These tools run on the infrastructure server and power the provisioning pipeline:

| Tool | Purpose |
|---|---|
| **dnsbinder** | Manages BIND DNS zone records — automatic A/AAAA/CNAME/PTR creation and deletion as VMs are created or destroyed |
| **ksmanager** | Orchestrates OS provisioning — generates kickstart/cloud-init/AutoYaST configs, manages iPXE boot entries, DHCP reservations, and golden image workflows |
| **prepare-distro-for-ksmanager** | Downloads ISOs, mounts them, and registers distributions with ksmanager for PXE provisioning |

---

## Project Structure

```
tux2lab/
├── qemu-kvm-manage/           KVM host scripts (deploy, setup, VM management)
│   ├── deploy-lab-infra-server.sh
│   ├── setup-qemu-kvm.sh
│   ├── download-infra-server-iso.sh
│   └── scripts-to-manage-vms/  CLI dispatcher and all tux2lab vm subcommands
├── configure-lab-infra-server/ Ansible playbook and roles for infra server setup
├── ks-manage/                  Kickstart/cloud-init templates and ksmanager
├── named-manage/               DNS zone management (dnsbinder)
├── common-utils/               Shared utilities (color output, disk tools)
└── vendor/                     Vendored virt-manager (no system package needed)
```

---

## Support & Contributing

- Found a bug? Have ideas? [Open an issue](https://github.com/Muthukumar-Subramaniam/tux2lab/issues) on GitHub.
- Pull requests are welcome — improve automation, add distros, or enhance docs.

## License

This project is open source and licensed under the [GNU General Public License v3.0](LICENSE).

---

Built with ❤️ for the home lab community
