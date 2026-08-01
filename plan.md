# Plan: IPv6 Offset Mapping + Stack Mode + TTL + Resource Overrides

## TL;DR
Implement offset-based IPv6 addressing, per-record TTL, `--stack` mode for VMs, resource allocation overrides, and self-managing IPv6 routes via tux2lab-sync. Enables IPv4-only, IPv6-only, and dual-stack VM deployments. LB stays dual-stack always.

## Phase 1: dnsbinder — Offset IPv6 Mapping

**Goal**: Replace 4-octet hex embedding with simple offset-based mapping.

**Mapping**:
- IPv4: `network_base + offset` (e.g., offset 2 → 10.28.28.2)
- IPv6: `prefix::offset` (e.g., offset 2 → fd28:2808:2020:3000::2)
- Offsets 1–1022: dual-stack or IPv4-only hosts (IPv6 slot reserved even if unused)
- Offsets 1023+: IPv6-only hosts

**Files**: `named-manage/dnsbinder.sh` — AAAA creation section (~line 1620-1640)

**Changes**:
- Replace hex-octet embedding with: offset = IPv4 - network_base; IPv6 = prefix::offset_hex
- Reverse zone PTR creation updated accordingly

---

## Phase 2: dnsbinder — `-c4` and `-c6` Flags

**Goal**: Create IPv4-only or IPv6-only records.

**New flags**: `-c4` (A only), `-c6` (AAAA only, offset 1023+), `-d4`, `-d6`

**Files**: `named-manage/dnsbinder.sh` — dispatch, fn_create_host_record, zone write logic

**Changes**:
- Skip AAAA for `-c4`, skip A for `-c6`
- `-c6` allocates from separate offset counter (1023+)
- Reverse zone: only create PTR for active stack

---

## Phase 3: dnsbinder — TTL Support

**Goal**: Per-record TTL for A/AAAA/CNAME.

**Flags**: `--ttl <seconds>` with create, standalone `dnsbinder --ttl hostname 60`

**Files**: `named-manage/dnsbinder.sh` — zone write, new --ttl dispatch

**Changes**:
- TTL in zone format: `hostname 300 IN A x.x.x.x`
- Standalone update: sed-replace record line with TTL version
- Applies to A + AAAA + PTR

---

## Phase 4: ksmanager — `--stack` Mode

**Goal**: Deploy VMs as IPv4-only, IPv6-only, or dual-stack.

**Flag**: `--stack dual|ipv4|ipv6` (default: dual)

**Files**:
- `ksmanager/ksmanager.sh` — DNS, DHCP, network-config
- `parse-vm-command-args.sh` — pass --stack through
- `golden-boot-templates/network-config-for-mac-address` — conditional sections

**Changes**:
- DNS: call `-c`/`-c4`/`-c6` based on stack
- DHCP: skip DHCPv4 or DHCPv6 reservation per stack
- Network-config: disable unused stack in NM config
- MAC cache: store stack mode
- PXE --stack ipv6: temp IPv4 for install, post-install removes IPv4 config + A record
- Warning if `--stack ipv6` and ipv6-route not active

---

## Phase 5: generate-service-configs.sh — DHCPv6 Pool Reposition

**Goal**: Move DHCPv6 pool to non-overlapping range.

**New pool**: `::f000` to `::ffff` (4096 leases)

**Files**: `setup/generate-service-configs.sh` — generate_kea_dhcp6

---

## Phase 6: VM Resource Allocation Overrides

**Goal**: Allow custom CPU, memory, and disk size per VM at create/reimage time.

**Flags**: `--cpu <count>` `--memory <MB>` `--root-disk-size <GB>` (override defaults)

**Applicable to**: `tux2lab vm install` and `tux2lab vm reimage` (both golden and PXE)

**Files**:
- `qemu-kvm-manage/scripts-to-manage-vms/functions/parse-vm-command-args.sh` — parse new flags
- `qemu-kvm-manage/scripts-to-manage-vms/kvm-install-golden.sh` — pass to virt-install
- `qemu-kvm-manage/scripts-to-manage-vms/kvm-install-pxe.sh` — pass to virt-install
- `qemu-kvm-manage/scripts-to-manage-vms/kvm-reimage-golden.sh` — resize disk if needed
- `qemu-kvm-manage/scripts-to-manage-vms/kvm-reimage-pxe.sh` — resize disk if needed
- `qemu-kvm-manage/scripts-to-manage-vms/functions/defaults.sh` — default values

**Changes**:
- Parse --cpu, --memory, --root-disk-size from args
- Default: cpu=2, memory=2048, root-disk-size=30 (from defaults.sh)
- Pass to virt-install: --vcpus, --memory, --disk size=
- Reimage: if new disk size > current, resize. If smaller, warn and skip.
- Store in VM metadata for info display

---

## Phase 7: IPv6 Default Route via tux2lab-sync

**Goal**: Replace SSH-based `ipv6-route enable/disable` with self-managing VMs via tux2lab-sync.

**Mechanism**:
- `tux2lab ipv6-route enable` → creates `/tux2lab-data/lab-config/ipv6-route-active`
- `tux2lab ipv6-route disable` → removes the flag file
- `tux2lab-sync` (runs every 5min on VMs) checks `http://infra-server/lab-config/ipv6-route-active`
  - If present → `ip -6 route add default via <gateway>` (idempotent)
  - If absent → `ip -6 route del default` (idempotent)
- `tux2lab start` → re-enables IPv6 forwarding on host if flag file exists

**Files**:
- `common-utils/tux2lab-sync` — add ipv6 route check section
- `qemu-kvm-manage/scripts-to-manage-vms/kvm-ipv6-route.sh` — simplify to just manage flag file + host forwarding
- `qemu-kvm-manage/scripts-to-manage-vms/start.sh` — re-enable forwarding if flag present

**Benefits**:
- New VMs get the route automatically on first sync
- No SSH dependency
- Self-healing (route re-applied every 5 min if lost)
- Single source of truth (flag file)

---

## IPv6 Address Space Layout

```
fd28:2808:2020:3000::/64

::1              = gateway (infra server)
::2 to ::3fe     = dual-stack / IPv4-only (offsets 2–1022)
::3ff to ::efff  = IPv6-only hosts (offset 1023+)
::f000 to ::ffff = DHCPv6 dynamic pool
```

## Key Decisions
- LB always dual-stack (no --stack for LB)
- PXE --stack ipv6: temporarily assigns IPv4 for install (dual-stack boot), post-install removes IPv4 config and A record, final state is IPv6-only
- Golden image builds always dual-stack; clones get per-VM stack
- IPv6-only warning only if ipv6-route not active
- Default --stack=dual — zero change for existing workflows
- All changes additive — no existing behavior changes
