#!/usr/bin/env python3
from render_common import *

C_D, C_ID, C_V, C_SZ, C_C = 20, 16, 12, 22, 30

def header_lines():
    h = ("  " + "DISTRO".ljust(C_D) + " " + "DISTRO-ID".ljust(C_ID) + " " +
         "VERSION".ljust(C_V) + " " + "SIZE (DISK / VIRTUAL)".ljust(C_SZ) + " " + "CREATED".ljust(C_C))
    s = ("  " + "------".ljust(C_D) + " " + "---------".ljust(C_ID) + " " +
         "-------".ljust(C_V) + " " + "---------------------".ljust(C_SZ) + " " + "-------".ljust(C_C))
    return [whole(h, CYAN), whole(s, CYAN)]

def row(name, did, ver, size, created):
    line = ("  " + name.ljust(C_D) + " " + did.ljust(C_ID) + " " + ver.ljust(C_V) + " " +
            size.ljust(C_SZ) + " " + created.ljust(C_C))
    return whole(line, GREEN)

# Before: no golden images
lines = []
lines.append(prompt("~", "tux2lab golden-image list"))
lines.append(whole("[INFO] No golden images found.", MAGENTA))
lines.append(whole("[INFO] Create one with: tux2lab golden-image build", MAGENTA))
lines.append(prompt("~", ""))
render(lines, "tux2lab-golden-list-before.png")

# After: only AlmaLinux 10 built
lines = []
lines.append(prompt("~", "tux2lab golden-image list"))
lines += header_lines()
lines.append(row("AlmaLinux", "almalinux", "10", "2.7 GiB / 30 GiB", "2026-08-20 09:29:24"))
lines.append(prompt("~", ""))
render(lines, "tux2lab-golden-list-after.png")
