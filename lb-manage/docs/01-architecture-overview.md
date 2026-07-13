# tux2lab lb — Architecture Overview

## What Are We Building?

A **TCP stream load balancer manager** integrated into the tux2lab lab platform.
It uses nginx's `stream` module to distribute TCP traffic across multiple backend servers.

Each load balancer gets:
1. Its own **dedicated IP address** (dual-stack: IPv4 + IPv6)
2. A **DNS record** (A + AAAA) pointing to that IP
3. An **nginx stream config** that listens on that IP and proxies to backends
4. A **registry entry** tracking its state

---

## Why TCP Stream (L4) and Not HTTP Reverse Proxy (L7)?

| Layer | What it does | When you need it |
|-------|-------------|-----------------|
| **L4 (TCP stream)** | Forwards raw TCP bytes — doesn't inspect content | K8s API (6443), databases (5432/3306), etcd (2379), message queues, any TCP service |
| **L7 (HTTP)** | Inspects HTTP headers, can route by path/host | Path-based routing, header injection, SSL termination |

**For a lab**, every service we load-balance is TCP:
- Kubernetes API server → TCP 6443
- NodePort services → TCP 30000-32767
- PostgreSQL/MySQL → TCP 5432/3306
- etcd → TCP 2379
- Redis → TCP 6379
- gRPC → TCP 50051

L4 is simpler, faster, and covers 100% of lab use cases.

---

## How It Works — The Flow

```
┌─────────────────────────────────────────────────────────────────────┐
│                        tux2lab lb create                             │
│  --name k8s-api --port 6443 --target-port 6443                      │
│  --backends k8s-cp1,k8s-cp2,k8s-cp3 --algorithm least-conn         │
└─────────────────────────────────────────────────────────────────────┘
                                │
                                ▼
┌─────────────────────────────────────────────────────────────────────┐
│ Step 1: Create DNS Record via dnsbinder                             │
│                                                                     │
│   dnsbinder -c k8s-api                                              │
│   → Creates A record:    k8s-api.user.internal → 10.28.28.5        │
│   → Creates AAAA record: k8s-api.user.internal → fd28:...:0005     │
│   (IPv6 auto-derived from IPv4 by dnsbinder)                        │
└─────────────────────────────────────────────────────────────────────┘
                                │
                                ▼
┌─────────────────────────────────────────────────────────────────────┐
│ Step 2: Add Secondary IP to Network Interface                       │
│                                                                     │
│   Host mode:  ip addr add 10.28.28.5/22 dev labbr0                 │
│               ip addr add fd28:...:0005/64 dev labbr0               │
│                                                                     │
│   VM mode:    ip addr add 10.28.28.5/22 dev eth0                    │
│               ip addr add fd28:...:0005/64 dev eth0                 │
│                                                                     │
│   The LB now has its own IP on the lab network!                     │
└─────────────────────────────────────────────────────────────────────┘
                                │
                                ▼
┌─────────────────────────────────────────────────────────────────────┐
│ Step 3: Generate nginx Stream Config                                │
│                                                                     │
│   Writes /etc/nginx/stream.d/k8s-api.conf                          │
│   (upstream block + server block — see sample config)               │
└─────────────────────────────────────────────────────────────────────┘
                                │
                                ▼
┌─────────────────────────────────────────────────────────────────────┐
│ Step 4: Validate & Reload                                           │
│                                                                     │
│   nginx -t              → Validate config syntax                    │
│   systemctl reload nginx → Apply without downtime                   │
└─────────────────────────────────────────────────────────────────────┘
                                │
                                ▼
┌─────────────────────────────────────────────────────────────────────┐
│ Step 5: Register in State                                           │
│                                                                     │
│   Adds entry to /tux2lab-data/lb-hub/lb-registry.json               │
│   (name, port, target_port, algorithm, ipv4, ipv6, backends, etc.)  │
└─────────────────────────────────────────────────────────────────────┘
                                │
                                ▼
┌─────────────────────────────────────────────────────────────────────┐
│ Step 6: Verify                                                      │
│                                                                     │
│   nc -z 10.28.28.5 6443  → Port reachable?                         │
│   nc -z fd28:...:0005 6443 → IPv6 reachable?                       │
│   ✓ Load balancer is live!                                          │
└─────────────────────────────────────────────────────────────────────┘
```

---

## Network Topology

```
┌─────────────────────────────────────────────────────────────────────┐
│                         KVM HOST                                     │
│                                                                     │
│   ┌─────────────────────────────────────────────────────────────┐   │
│   │                      labbr0 (bridge)                         │   │
│   │         Primary:  10.28.28.1/22 + fd28:...:0001/64           │   │
│   │                                                              │   │
│   │   [Host Mode LB IPs added here as secondary addresses]       │   │
│   │         Secondary: 10.28.28.5/22 (k8s-api LB)               │   │
│   │         Secondary: 10.28.28.6/22 (pg-cluster LB)            │   │
│   └──────────────────────────┬──────────────────────────────────┘   │
│                              │                                       │
└──────────────────────────────┼───────────────────────────────────────┘
                               │
          ┌────────────────────┼─────────────────────┐
          │                    │                     │
          ▼                    ▼                     ▼
┌──────────────────┐ ┌──────────────────┐ ┌──────────────────┐
│  Lab Infra VM    │ │   k8s-cp1 VM     │ │   k8s-cp2 VM     │
│  (tux2lab-engine)│ │  10.28.28.10     │ │  10.28.28.11     │
│  10.28.28.2      │ │                  │ │                  │
│                  │ │  Runs: kube-api  │ │  Runs: kube-api  │
│  eth0:           │ │  on port 6443    │ │  on port 6443    │
│   Primary: .2    │ └──────────────────┘ └──────────────────┘
│                  │
│  [VM Mode LB IPs │
│   added to eth0] │
│   Secondary: .5  │
│   (k8s-api LB)   │
└──────────────────┘
```

**Host mode:** LB IPs go on `labbr0` (the bridge itself handles traffic)
**VM mode:** LB IPs go on `eth0` of the infra VM (nginx runs inside the VM)

---

## Component Map

```
┌─────────────────────────────────────────────────────────────────┐
│                    User's Workstation (KVM Host)                  │
│                                                                  │
│  tux2lab lb create/delete/update/list/status                     │
│       │                                                          │
│       ▼                                                          │
│  lb.sh (CLI wrapper)                                             │
│       │                                                          │
│       ├── Host mode: sudo /tux2lab/lb-manage/lbmanager.sh        │
│       │                                                          │
│       └── VM mode: ssh infra-server →                            │
│                    sudo /tux2lab/lb-manage/lbmanager.sh           │
│                                                                  │
└──────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────┐
│                    Infra Server (Host or VM)                      │
│                                                                  │
│  lbmanager.sh                                                    │
│       │                                                          │
│       ├── dnsbinder.sh  → Create/delete DNS A/AAAA records       │
│       ├── ip command    → Add/remove secondary IPs               │
│       ├── nginx         → Stream config generation + reload      │
│       └── jq            → JSON registry CRUD                     │
│                                                                  │
│  State:                                                          │
│       /tux2lab-data/lb-hub/lb-registry.json                      │
│       /etc/nginx/stream.d/<name>.conf                            │
│                                                                  │
│  Systemd:                                                        │
│       tux2lab-lb.service → Runs "lbmanager.sh restore" on boot   │
│                                                                  │
└──────────────────────────────────────────────────────────────────┘
```

---

## Why Secondary IPs?

Instead of nginx listening on `0.0.0.0:<port>` (which would conflict with other services),
each LB gets its own dedicated IP. This means:

- **No port conflicts** — Two LBs can both use port 6443 (different IPs)
- **Clean DNS** — `k8s-api.user.internal` resolves to the LB's own IP
- **Isolation** — Each LB is independently addressable
- **Dual-stack** — Every LB is reachable over both IPv4 and IPv6

The `ip addr add` command adds these as secondary addresses to the existing interface.
The systemd oneshot service re-applies them on every boot (since secondary IPs are ephemeral).

---

## Boot Persistence

Secondary IPs added with `ip addr add` are **lost on reboot**. The systemd service handles this:

```
[tux2lab-lb.service]
        │
        ▼
lbmanager.sh restore
        │
        ├── Read lb-registry.json
        ├── For each LB:
        │     ├── Check if IP already on interface (idempotent)
        │     ├── If missing: ip addr add <ipv4>/22 dev <interface>
        │     └── If missing: ip addr add <ipv6>/64 dev <interface>
        └── Reload nginx (once, at the end)
```

---

## CLI Subcommands Summary

| Command | Purpose |
|---------|---------|
| `tux2lab lb create` | Create a new load balancer (DNS + IP + nginx + registry) |
| `tux2lab lb delete` | Remove a load balancer (reverse of create) |
| `tux2lab lb update` | Modify backends, ports, or algorithm |
| `tux2lab lb list` | Show all load balancers in a table |
| `tux2lab lb status` | Health check — DNS, IP, nginx, port reachability |
| `tux2lab lb restore` | Re-apply all secondary IPs from registry (also used by systemd on boot) |
| `tux2lab lb` | Interactive menu (no subcommand) |
