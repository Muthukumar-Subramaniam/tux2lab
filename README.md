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

---

## Architecture Overview

tux2lab runs on your Linux workstation (the **KVM host**) and creates a private
virtual network (`labbr0` bridge, `10.28.28.0/22` + IPv6 ULA `fd28:2808:2020:3000::/64`) with a central
**lab infrastructure server** that provides all lab services:

| Service | Software | Purpose |
|---|---|---|
| DNS | BIND (named) | Local domain resolution |
| DHCP | Kea (v4 + v6) | Automatic IP assignment |
| PXE/TFTP | tftp-server + iPXE | Network boot for OS installs |
| NTP | chrony | Time synchronization |
| NFS | nfs-server | Shared storage |
| HTTP | nginx | ISO & kickstart file serving |
| IPv6 RA | radvd | Router advertisements |

### Lab Infrastructure Server — Deployment Modes

| | **VM Mode** (Recommended) | **Host Mode** (Advanced) |
|---|---|---|
| **Where** | Dedicated KVM VM | Directly on KVM host |
| **Isolation** | Complete — easy to delete/recreate | None — modifies host system |
| **Resources** | 2 GB RAM, 2 vCPUs, 30 GB disk | Minimal overhead |
| **Best for** | Most users, shared systems | Owned systems with limited RAM |
| **Cleanup** | Delete the VM | Manual service/package removal |

---

## Supported Distributions

### Infra Server OS — VM Mode (RHEL-based only)

AlmaLinux 10 (default), Rocky Linux 10, Oracle Linux 10, CentOS Stream 10, RHEL 10.

### Guest VM Provisioning

| Family | Distribution | Versions | Method |
|---|---|---|---|
| Red Hat-based | AlmaLinux, Rocky, Oracle Linux, RHEL, CentOS Stream | 10, 9, 8 | Kickstart |
| Debian-based | Ubuntu LTS | 26.04, 24.04, 22.04 | Cloud-init autoinstall |
| SUSE-based | openSUSE Leap | 16.0, 15.6, 15.5 | Agama (16.0), AutoYaST (15.x) |
| Azure Linux | Microsoft Azure Linux | 4 | Kickstart (patched LiveOS) |

> **VM mode:** The distro used to build the infra server is available for guest provisioning immediately.
> **Host mode:** No distros are pre-configured — set up your first distro after deployment.
>
> Additional distros can be set up anytime via `tux2lab distro setup`.

---

## Minimum System Requirements

> These are the minimum recommended values. Adjust based on your workload.

**Central Infra Server VM:** 2 GB RAM · 2 vCPUs · 30 GB disk

**Guest VMs (each):** 2 GB RAM · 2 vCPUs · 20 GB disk

**KVM Host:** RHEL-based, Ubuntu, or openSUSE (hardware virtualization required; host mode is RHEL-based only).

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

### Step 2 — Install QEMU/KVM

```bash
/tux2lab/qemu-kvm-manage/setup-qemu-kvm.sh
```

This script:
- Installs QEMU/KVM, libvirt, and all dependencies (supports both `apt` and `dnf`)
- Grants passwordless sudo to the current user
- Creates the `labbr0` bridge network with dual-stack (IPv4/IPv6) NAT
- Sets up the `/tux2lab-data/` data directory
- Installs the `tux2lab` CLI and bash completion

### Step 3 — Download Infra Server ISO (VM mode only)

> Skip this step if you plan to deploy in **Host mode**.

```bash
tux2lab distro download-infra-iso
```

Downloads the ISO, fetches the checksum, and verifies integrity via SHA256.
The ISO is used as the install medium for the infra server VM.

### Step 4 — Deploy the Lab Infrastructure Server

```bash
tux2lab deploy
```

The interactive wizard handles:
- Deploy mode selection — VM (recommended) or Host
- Admin password setup

The hostname is fixed to `tux2lab-engine` and the domain is automatically set to `<your-username>.internal`.

The deploy process (VM mode):
- Validates the infra server ISO is available
- Generates SSH keys for passwordless access
- Prepares a kickstart file from your inputs
- Mounts the ISO and extracts kernel/initrd for PXE-style boot
- Launches the infra server VM via `virt-install` (console output shown live)
- Waits for OS installation to complete and starts the VM
- Waits for SSH to become reachable on the new VM
- Syncs tux2lab to the VM and configures all lab infra services remotely
- Configures DNS resolution on the KVM host (`resolvectl`)
- Runs a health check to verify all lab services are up

### Step 5 — Verify Your Lab

```bash
tux2lab health
```

---

## Using tux2lab

### Prepare a Distribution for Provisioning

In VM mode, the distro used to build the infra server is available for guest provisioning immediately.
In Host mode, or to provision VMs with a different distro, set it up first:

```bash
tux2lab distro setup                             # Interactive
tux2lab distro setup almalinux --version 10      # Non-interactive
tux2lab distro list                              # Show setup status
```

### Create a Golden Image (Optional, Recommended)

Golden images let you deploy VMs in seconds instead of running a full PXE install:

```bash
tux2lab golden-image build                       # Interactive
tux2lab golden-image build almalinux -v 10       # Non-interactive
tux2lab golden-image list                        # Show available images
```

### Deploy VMs

```bash
# From golden image (fast — disk clone)
tux2lab vm install-golden -H vm1
tux2lab vm install-golden -H vm1 -d almalinux -v 10

# Via PXE boot (full network install)
tux2lab vm install-pxe -H vm1
tux2lab vm install-pxe -H vm1 -d ubuntu-lts -v 24.04

# Multiple VMs at once
tux2lab vm install-golden -H vm1,vm2,vm3

# Attach to console during install
tux2lab vm install-pxe -H vm1 --console
```

---

## CLI Reference

> Most commands accept `-H vm1,vm2,vm3` for multi-VM operations.

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

### VM Provisioning

```
tux2lab vm install-golden         Deploy from golden image
tux2lab vm install-pxe            Deploy via PXE network boot
tux2lab vm reimage-golden         Wipe and reinstall from golden image
tux2lab vm reimage-pxe            Wipe and reinstall via PXE
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

### Golden Image Management

```
tux2lab golden-image build        Build a reusable base image via PXE
tux2lab golden-image list         List available golden images
tux2lab golden-image cleanup      Remove golden image(s)
```

### Infrastructure & Network

```
tux2lab start                     Start lab infrastructure
tux2lab stop                      Stop lab infrastructure and shut down all VMs
tux2lab enable                    Enable lab infrastructure auto-start on boot
tux2lab disable                   Disable lab infrastructure auto-start on boot
tux2lab health                    Check all lab service health
tux2lab deploy                    Deploy a new lab infrastructure server
tux2lab destroy                   Permanently destroy the entire lab environment
tux2lab rebuild                   Tear down and redeploy lab using existing config
tux2lab sync                      Push config updates to infra server (VM mode)
tux2lab info                      Show lab deployment details
tux2lab dns [options]             Manage DNS records via dnsbinder
tux2lab distro list               List distributions and setup status
tux2lab distro setup              Prepare a distro for PXE provisioning
tux2lab distro cleanup            Remove a distro's PXE setup
tux2lab distro download-infra-iso Download infra server ISO (VM mode)
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

These tools run on the infrastructure server and power the provisioning pipeline:

| Tool | Purpose |
|---|---|
| **dnsbinder** | Manages BIND DNS zone records — automatic A/AAAA/CNAME/PTR creation and deletion as VMs are created or destroyed |
| **ksmanager** | Orchestrates OS provisioning — generates kickstart/cloud-init/AutoYaST/Agama configs, manages iPXE boot entries, DHCP reservations, and golden image workflows |
| **prepare-distro-for-ksmanager** | Downloads ISOs, mounts them, and registers distributions with ksmanager for PXE provisioning |

---

## Project Structure

```
tux2lab/
├── qemu-kvm-manage/           KVM host scripts (deploy, setup, VM management)
│   ├── deploy-lab-infra-server.sh
│   ├── setup-qemu-kvm.sh
│   └── scripts-to-manage-vms/  CLI dispatcher and all tux2lab vm subcommands
├── configure-lab-infra-server/ Bash scripts and config files for infra server setup
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

Built for the home lab community.
