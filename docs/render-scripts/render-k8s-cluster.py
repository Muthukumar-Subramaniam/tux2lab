#!/usr/bin/env python3
from render_common import *

lines = []

# tux2lab vm list: plain header, rows green because every guest is healthy
lines.append(prompt("~", "tux2lab vm list"))
lines.append(whole("VM-Name                   VM-State OS-State OS-Distro", DEFAULT))
lines.append(whole("------------------------------------------------------------------------", DEFAULT))
for n in ("k8s-cp1", "k8s-cp2", "k8s-cp3"):
    lines.append(whole(f"{n}.musubram.internal running  healthy  Debian GNU/Linux 13 (trixie)", GREEN))
for n in ("k8s-w1", "k8s-w2", "k8s-w3", "k8s-w4"):
    lines.append(whole(f"{n}.musubram.internal  running  healthy  Debian GNU/Linux 13 (trixie)", GREEN))
lines.append(prompt("~", ""))

# tux2lab lb list: cyan header, plain separator and rows
lines.append(prompt("~", "tux2lab lb list"))
lines.append(whole("NAME                        IPv4          IPv6                     PORT     TARGET PORT  ALGORITHM    BACKENDS", CYAN))
lines.append(whole("----                        ----          ----                     ----     -----------  ---------    --------", DEFAULT))
lines.append(whole("k8s-cp.musubram.internal    10.28.28.5    fd28:2808:2020:3000::5   6443     6443         least-conn   3 backend(s)", DEFAULT))
lines.append(whole("ironweb.musubram.internal   10.28.28.10   fd28:2808:2020:3000::a   80       31053        round-robin  4 backend(s)", DEFAULT))
lines.append(prompt("~", ""))

lines.append(prompt("~", "tux2lab lb status --name k8s-cp.musubram.internal"))
lines.append(whole("[INFO] Load Balancer: k8s-cp.musubram.internal (10.28.28.5:6443)", MAGENTA))
for t in ("DNS record (k8s-cp.musubram.internal)...",
          "IPv4 10.28.28.5 on labbr0...",
          "IPv6 fd28:2808:2020:3000::5 on labbr0...",
          "Nginx config (k8s-cp.musubram.internal)...",
          "Port reachable (10.28.28.5:6443)...",
          "Port reachable ([fd28:2808:2020:3000::5]:6443)...",
          "Backend k8s-cp1.musubram.internal:6443...",
          "Backend k8s-cp2.musubram.internal:6443...",
          "Backend k8s-cp3.musubram.internal:6443..."):
    lines.append(task(t, "[DONE]", GREEN))
lines.append(whole("[SUCCESS] All checks passed (9/9)", GREEN))
lines.append(prompt("~", ""))

# kubectl prints these tables uncoloured, so they are rendered as-is
lines.append(prompt("~", "kubectl get nodes"))
lines.append(whole("NAME                        STATUS   ROLES           AGE   VERSION", DEFAULT))
for n in ("k8s-cp1", "k8s-cp2", "k8s-cp3"):
    lines.append(whole(f"{n}.musubram.internal   Ready    control-plane   11d   v1.36.3", DEFAULT))
for n in ("k8s-w1", "k8s-w2", "k8s-w3", "k8s-w4"):
    lines.append(whole(f"{n}.musubram.internal    Ready    worker          11d   v1.36.3", DEFAULT))
lines.append(prompt("~", ""))

lines.append(prompt("~", "kubectl get svc -n ironweb"))
lines.append(whole("NAME      TYPE       CLUSTER-IP      EXTERNAL-IP   PORT(S)          AGE", DEFAULT))
lines.append(whole("ironweb   NodePort   10.101.20.160   <none>        9090:31053/TCP   11d", DEFAULT))
lines.append(prompt("~", ""))

lines.append(prompt("~", "kubectl get pods -n ironweb"))
lines.append(whole("NAME                       READY   STATUS    RESTARTS        AGE", DEFAULT))
for p in ("55jlt", "dmfxs", "mtqds", "r9mzk"):
    lines.append(whole(f"ironweb-78dbcf7b7f-{p}   1/1     Running   2 (4h21m ago)   11d", DEFAULT))
lines.append(prompt("~", ""))

render(lines, "tux2lab-k8s-cluster.png")
