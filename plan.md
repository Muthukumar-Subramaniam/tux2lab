# Plan: v2.0.0 Remaining Features (6 Phases)

## TL;DR
Implement offset-based IPv6 addressing, per-record TTL, `--stack` mode for VMs, resource allocation overrides, and self-managing IPv6 routes via tux2lab-sync. Enables IPv4-only, IPv6-only, and dual-stack VM deployments. LB stays dual-stack always.

## Phase 1: dnsbinder — Offset IPv6 Mapping + DHCPv6 Pool (~4h)

**Goal**: Replace 4-octet hex embedding with simple offset-based mapping. Reposition DHCPv6 pool.

**Mapping**:
- IPv4: `network_base + offset` (e.g., offset 2 → 10.28.28.2)
- IPv6: `prefix::offset` (e.g., offset 2 → fd28:2808:2020:3000::2)
- Offsets 1–1022: dual-stack or IPv4-only hosts (IPv6 slot reserved even if unused)
- Offsets 1023+: IPv6-only hosts
- DHCPv6 pool: `::f001` to `::f063` (99 leases, matching IPv4 pool size)

**Files**: `named-manage/dnsbinder.sh`, `setup/generate-service-configs.sh`

**Changes**:
- Replace hex-octet embedding with: offset = IPv4 - network_base; IPv6 = prefix::offset_hex
- Reverse zone PTR creation updated accordingly
- DHCPv6 pool: `::f001` to `::f063` (99 leases)
- DHCP pool DNS reservations:
  - `dhcp-v4-lease1` to `dhcp-v4-lease99` (A records, `-c4` style, prevents allocation into IPv4 pool)
  - `dhcp-v6-lease1` to `dhcp-v6-lease99` (AAAA records, `-c6` style, prevents allocation into IPv6 pool)

---

## Phase 2: dnsbinder — TTL Support (~1.5h)

**Goal**: Per-record TTL for A/AAAA/CNAME.

**Flags**: `--ttl <seconds>` with create, standalone `dnsbinder --ttl hostname 60`

**Files**: `named-manage/dnsbinder.sh` — zone write, new --ttl dispatch

**Changes**:
- TTL in zone format: `hostname 300 IN A x.x.x.x`
- Standalone update: sed-replace record line with TTL version
- Applies to A + AAAA + CNAME + PTR

---

## Phase 3: dnsbinder — `-c4` and `-c6` Flags (~3h)

**Goal**: Create IPv4-only or IPv6-only records.

**New flags**: `-c4` (A only), `-c6` (AAAA only, offset 1023+), `-d4`, `-d6`

**Files**: `named-manage/dnsbinder.sh` — dispatch, fn_create_host_record, zone write logic

**Changes**:
- Skip AAAA for `-c4`, skip A for `-c6`
- `-c6` allocates from separate offset counter (1023+)
- Reverse zone: only create PTR for active stack

---

## Phase 4: ksmanager — `--ipv4-only` / `--ipv6-only` Flags (~6h)

**Goal**: Deploy VMs as IPv4-only, IPv6-only, or dual-stack.

**Flags**: `--ipv4-only` or `--ipv6-only` (no flag = dual-stack default)

**Files**:
- `ksmanager/ksmanager.sh` — DNS, DHCP, network-config
- `parse-vm-command-args.sh` — pass --stack through
- `golden-boot-templates/network-config-for-mac-address` — conditional sections

**Changes**:
- DNS: call `-c`/`-c4`/`-c6` based on flag
- DHCP: skip DHCPv4 or DHCPv6 reservation per flag
- Network-config: disable unused stack in NM config
- MAC cache: store stack mode (ipv4-only/ipv6-only/dual)
- PXE --ipv6-only: temp IPv4 for install, post-install removes IPv4 config + A record
- Warning if `--ipv6-only` and ipv6-route not active

---

## Phase 5: VM Resource Allocation Overrides (~3h)

**Goal**: Allow custom CPU, memory, and disk size per VM at create/reimage time.

**Flags**: `--cpu <count>` `--memory <MB>` `--root-disk-size <GB>` (override defaults)

**Applicable to**: `tux2lab vm install` and `tux2lab vm reimage` (both golden and PXE)

**Files**:
- `parse-vm-command-args.sh` — parse new flags
- `kvm-install-golden.sh` / `kvm-install-pxe.sh` — pass to virt-install
- `kvm-reimage-golden.sh` / `kvm-reimage-pxe.sh` — resize disk if needed
- `functions/defaults.sh` — default values

**Changes**:
- Default: cpu=2, memory=2048, root-disk-size=30 (from defaults.sh)
- Pass to virt-install: --vcpus, --memory, --disk size=
- Reimage: if new disk size > current, resize. If smaller, warn and skip.
- Store in VM metadata for info display

---

## Phase 6: IPv6 Default Route via tux2lab-sync (~1.5h)

**Goal**: Replace SSH-based `ipv6-route enable/disable` with self-managing VMs.

**Mechanism**:
- `tux2lab ipv6-route enable` → creates `/tux2lab-data/lab-config/ipv6-route-active`
- `tux2lab ipv6-route disable` → removes the flag file
- `tux2lab-sync` (every 5min) checks flag via HTTP:
  - Present → `ip -6 route add default via <gateway>` (idempotent)
  - Absent → `ip -6 route del default` (idempotent)
- `tux2lab start` → re-enables IPv6 forwarding on host if flag present

**Benefits**:
- New VMs get route on first sync (no SSH needed)
- Self-healing (re-applied every 5 min)
- Single source of truth (flag file)

---

## IPv6 Address Space Layout

```
fd28:2808:2020:3000::/64

::1              = gateway (infra server)
::2 to ::3fe     = dual-stack / IPv4-only (offsets 2–1022)
                   (offsets ~924–1022 reserved by IPv4 DHCP pool, IPv6 counterparts unused)
::3ff to ::efff  = IPv6-only hosts (offset 1023+)
::f001 to ::f063 = DHCPv6 dynamic pool (99 leases)
```

## Key Decisions
- LB always dual-stack (no --stack for LB)
- PXE --ipv6-only: temp IPv4 for install, post-install removes it, final state IPv6-only
- Golden image builds always dual-stack; clones get per-VM stack
- IPv6-only warning only if ipv6-route not active
- Default --stack=dual — zero change for existing workflows
- DHCP pool DNS records prevent accidental allocation into pool ranges
- All changes additive — no existing behavior changes

## Execution: ~19h total across 2–3 focused sessions
