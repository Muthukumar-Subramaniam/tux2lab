# 🚀 tux2lab: Build Your Own QEMU/KVM Virtual Home Lab

Transform your Linux workstation into a powerful, automated virtual datacenter!
This project allows you to build and manage a virtual home lab, making it easy
to deploy, break, and rebuild Linux VMs effortlessly. It automates VM
provisioning, manages the complete lifecycle of your VMs, and provides a flexible
environment for learning, testing, and experimenting with Linux-based technologies.

Although many open-source alternatives exist, I built this project for the fun
of creating something of my own and sharing it with anyone with similar
interests.

> [!WARNING]
> This project is intended for testing, development, and experimentation purposes only.

> [!NOTE]
> This project is in active development (pre-v1.0). APIs and structure may change.

---

## 🎯 What You'll Get

- 🚀 Automated VM provisioning via PXE boot & golden images
- 🌐 Dynamic DNS management for your local domain
- 🔧 Full infrastructure-as-code automation
- 💻 Professional datacenter experience on your workstation
- 🎮 Complete VM lifecycle management with enterprise-grade tools
- 🧪 Experiment freely — Spin up and destroy VMs in seconds

---

## 🖥️ Automated Lab Environment for Provisioning and Managing Linux VMs

### 🧠 Central Infra Server VM's OS

The central lab infrastructure server is designed to run on **AlmaLinux 10** by default,
providing all the essential services for managing the lab environment.

### 📦 VM Guest OS Provisioning

The lab infrastructure server centrally manages all guest VM provisioning using
automation scripts and configuration templates.

The toolkit provides automated VM provisioning for all three major Linux
families, including ready-to-use configurations for:

| Family | Distribution | Method | Availability |
|---|---|---|---|
| Red Hat-based | AlmaLinux | Kickstart | ✅ Included by default |
|  | Rocky, Oracle Linux, RHEL, CentOS Stream | Kickstart | 🔧 Customizable |
| Debian-based | Ubuntu LTS | Cloud-init (cloud-config) | 🔧 Customizable |
| SUSE-based | openSUSE Leap | AutoYaST | 🔧 Customizable |

---

## 🧾 Minimum System Requirements

> These are the minimum recommended values. You can adjust them later based on
> your specific use case and workload.

### 🔹 Central Infra Server VM

- 🧠 Memory: 2 GB RAM
- ⚙️ CPU: 2 vCPUs
- 💾 Storage: 30 GB

### 🔸 Provisioned VMs

- 🧠 Memory: 2 GB RAM
- ⚙️ CPU: 2 vCPUs
- 💾 Storage: 20 GB

---

## 📥 Quick Start: Get Up and Running in 5 Steps

### Step 1 — Download the Latest Release

📦 **Using Latest Release** (recommended):

```bash
sudo mkdir -p /tux2lab
sudo chown ${USER}:$(id -g) /tux2lab
curl -sSL https://github.com/Muthukumar-Subramaniam/tux2lab/releases/latest/download/tux2lab.tar.gz \
  | tar -xzv -C /tux2lab
cd /tux2lab/qemu-kvm-manage/
```

**Alternative — Clone from the Repository:**

```bash
sudo mkdir -p /tux2lab
sudo chown ${USER}:$(id -g) /tux2lab
git clone https://github.com/Muthukumar-Subramaniam/tux2lab.git /tux2lab
cd /tux2lab/qemu-kvm-manage/
```

### Step 2 — Install QEMU/KVM

Run the automated setup script to configure your virtualization environment:

```bash
./setup-qemu-kvm.sh
```

This will install and configure all necessary packages and dependencies.

### Step 3 — Download AlmaLinux ISO

Grab the latest AlmaLinux ISO for your lab infrastructure:

```bash
./download-almalinux-latest.sh
```

> ☕ Pro tip: This might take a few minutes depending on your network speed. Perfect time for a coffee break!

### Step 4 — Deploy Your Lab Infrastructure Server

Now comes the magic! This fully automated script will:

- ✨ Guide you through the setup with interactive prompts
- 🔄 Install and configure the centralized lab infrastructure server
- 🎛️ Set up DNS, DHCP, PXE boot, and web services
- 🤖 Run Ansible automation for consistent configuration

```bash
./deploy-lab-infra-server.sh
```

**What to expect:**

- **First Reboot:** After OS installation and initial configuration
- **Second Reboot:** After services are configured via Ansible playbook
- **Final Step:** Once you see the login prompt, press `Ctrl + ]` to exit the console

> 🎬 Sit back and watch the automation work its magic!

### Step 5 — Access Your Infrastructure Server

Time to explore! SSH into your newly deployed infrastructure server:

```bash
ssh lab-infra-server.lab.local
```

> 💡 Replace `lab-infra-server.lab.local` with your actual server name and domain if different.

---

# ✅ Your Lab is Ready! Time to Build Something Amazing! 🎉

## 🛠️ Your New Superpowers: VM Management Tools

Your workstation is now equipped with powerful lab management tools:

### 📦 VM Deployment & Management

```
tux2lab vm install-golden            # 🚀 Deploy VMs instantly from golden images
tux2lab vm install-pxe               # 🌐 Deploy VMs via network PXE boot
tux2lab vm reimage-golden            # 🔄 Reinstall VMs from golden images
tux2lab vm reimage-pxe               # 🔄 Reinstall VMs via PXE boot
tux2lab golden-image create          # 🎨 Create reusable golden base images
tux2lab golden-image list            # 📋 List available golden images
tux2lab golden-image cleanup         # 🧹 Remove unused golden images
```

### 🎮 VM Operations

```
tux2lab vm list                      # 📊 View all VMs and their status
tux2lab vm info                      # ℹ️  Display detailed VM information
tux2lab vm console                   # 🖥️  Connect to VM serial console
tux2lab vm start                     # ▶️  Power on VMs
tux2lab vm stop                      # ⏹️  Force power-off VMs
tux2lab vm shutdown                  # 🔽 Graceful VM shutdown
tux2lab vm restart                   # 🔄 Hard restart VMs
tux2lab vm reboot                    # 🔃 Graceful VM reboot
tux2lab vm remove                    # 🗑️  Delete VMs completely
```

### 🔧 VM Configuration

```
tux2lab vm resize                    # 📏 Resize memory, CPU, or disk
tux2lab vm disk-add                  # 💾 Add new storage disks to VM
tux2lab vm disk-resize               # 📐 Resize additional disks
tux2lab vm disk-attach               # 🔗 Attach disks from detached storage
tux2lab vm disk-detach               # 📤 Detach and save disks for later use
tux2lab vm disk-delete               # 🗑️  Permanently delete detached disks
tux2lab vm nic-add                   # 🌐 Add network interfaces to VM
tux2lab vm nic-remove                # ❌ Remove network interfaces from VM
```

### 🌐 Network & Infrastructure Management

```
tux2lab ipv6-route                   # 🛣️  Manage IPv6 default routes (enable/disable/auto/status)
tux2lab start                        # 🏁 Start the entire lab infrastructure
tux2lab health                       # 🏥 Check lab infrastructure health
tux2lab dns                          # 🌍 Manage local DNS records
tux2lab distro                       # 📦 Manage OS distributions for provisioning
```

> 💡 **Pro tips:**
> - Use `tux2lab --help` or `tux2lab <command> --help` for detailed usage information
> - Tab completion is available — source `tux2lab-completion.bash` in your shell

---

## 🎭 The Secret Sauce: Backend Automation Tools

These powerful tools run on your infrastructure server, making everything work
seamlessly:

- 🌐 **dnsbinder** — Automatically manages DNS records for your local domain as you create/destroy VMs
- ⚡ **ksmanager** — Handles iPXE & golden-image based OS provisioning using kickstart automation
- 📦 **prepare-distro-for-ksmanager** — Downloads and prepares multiple Linux distributions (AlmaLinux, Rocky, Ubuntu, openSUSE, and more!)

---

## 🎊 Congratulations! Welcome to Your Virtual Datacenter!

You've just built a professional-grade, fully automated home lab that rivals enterprise infrastructure!

### 🌟 What Can You Do Now?

- 🧪 **Experiment freely** — Spin up and destroy VMs in seconds
- 📚 **Learn by doing** — Practice DevOps, automation, and infrastructure management
- 🏢 **Simulate production** — Test multi-tier applications in realistic environments
- 🚀 **Develop skills** — Master tools used in real enterprise datacenters
- 🔬 **Test and break things** — Build, destroy, rebuild without fear

Your journey to infrastructure mastery starts here! 🧑‍💻🖥️🧠

---

## 💬 Support & Contributing

- Need help? Found a bug? Have ideas? [Open an issue](https://github.com/Muthukumar-Subramaniam/tux2lab/issues) on GitHub!
- Want to contribute? Pull requests are welcome! Feel free to improve the automation, add new distros, or enhance documentation.

---

## 📜 License

This project is open source and licensed under the [GNU General Public License v3.0](LICENSE).

---

Built with ❤️ for the home lab community
