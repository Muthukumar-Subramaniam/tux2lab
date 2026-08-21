#!/usr/bin/env python3
from render_common import *

# Column widths from prepare-distro-for-ksmanager.sh
C_DISTRO, C_ID, C_VER, C_PXE = 20, 16, 12, 15
GROUP_SEP = "-"*78

DISTROS = [
    ("AlmaLinux", "almalinux", ["10", "9", "8"]),
    ("Rocky Linux", "rocky", ["10", "9", "8"]),
    ("OracleLinux", "oraclelinux", ["10", "9", "8"]),
    ("CentOS Stream", "centos-stream", ["10", "9", "8"]),
    ("RHEL", "rhel", ["10", "9", "8"]),
    ("Ubuntu Server LTS", "ubuntu-lts", ["26.04", "24.04", "22.04"]),
    ("Debian", "debian", ["13", "12", "11"]),
    ("openSUSE Leap", "opensuse-leap", ["16.0"]),
]

def status_seg(ready):
    text = "Ready" if ready else "Not-Ready"
    return text, (GREEN if ready else YELLOW)

def build(pxe_set, golden_set, outname):
    lines = []
    lines.append(prompt("~", "tux2lab distro list"))
    header = ("DISTRO".ljust(C_DISTRO) + " " + "DISTRO-ID".ljust(C_ID) + " " +
              "VERSION".ljust(C_VER) + " " + "PXE-READY".ljust(C_PXE) + " " + "GOLDEN-IMAGE")
    sep = ("------".ljust(C_DISTRO) + " " + "---------".ljust(C_ID) + " " +
           "-------".ljust(C_VER) + " " + "---------".ljust(C_PXE) + " " + "------------")
    lines.append(whole(header, CYAN))
    lines.append(whole(sep, CYAN))
    first_group = True
    for label, did, versions in DISTROS:
        if first_group:
            first_group = False
        else:
            lines.append(whole(GROUP_SEP, CYAN))
        first_ver = True
        for ver in versions:
            dl = label if first_ver else ""
            il = did if first_ver else ""
            first_ver = False
            ptxt, pcol = status_seg((did, ver) in pxe_set)
            gtxt, gcol = status_seg((did, ver) in golden_set)
            prefix = dl.ljust(C_DISTRO) + " " + il.ljust(C_ID) + " " + ver.ljust(C_VER) + " "
            lines.append([seg(prefix, DEFAULT), seg(ptxt.ljust(C_PXE), pcol),
                          seg(" ", DEFAULT), seg(gtxt, gcol)])
    lines.append(prompt("~", ""))
    render(lines, outname)

# Before: nothing prepared. After: almalinux 10 PXE-ready (distro setup done, golden not yet built)
build(set(), set(), "tux2lab-distro-list-before.png")
build({("almalinux", "10")}, set(), "tux2lab-distro-list-after.png")
# After golden image build: almalinux 10 is both PXE-ready and has a golden image
build({("almalinux", "10")}, {("almalinux", "10")}, "tux2lab-distro-list-after-golden.png")
