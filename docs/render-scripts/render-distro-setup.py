#!/usr/bin/env python3
from render_common import *

lines = []
lines.append(prompt("~", "tux2lab distro setup almalinux -v 10"))
lines.append(task("Ensuring ISO directory exists...", "[DONE]", GREEN))
lines.append(task("Downloading CHECKSUM file...", "[DONE]", GREEN))
lines.append(whole("[INFO] Disk space check passed: 273 GiB available (minimum 5 GiB)", MAGENTA))
lines.append(whole("[INFO] Downloading AlmaLinux 10 Boot ISO...", MAGENTA))
lines.append(whole("  % Total    % Received % Xferd  Average Speed   Time    Time     Time  Current", DEFAULT))
lines.append(whole("                                 Dload  Upload   Total   Spent    Left  Speed", DEFAULT))
lines.append(whole("100 1007M  100 1007M    0     0  5753k      0  0:02:59  0:02:59 --:--:-- 7101k", DEFAULT))
lines.append(whole("[SUCCESS] Download complete.", GREEN))
lines.append(whole("[INFO] Calculating SHA256 checksum (this may take a few minutes)...", MAGENTA))
lines.append(task("Comparing checksums", "[DONE]", GREEN))
lines.append(whole("[SUCCESS] Checksum matched. ISO file is valid.", GREEN))
lines.append(task("Preparing mount point: /tux2lab-data/os-repos/almalinux/10", "[DONE]", GREEN))
lines.append(task("Adding entry to iso-mounts config...", "[DONE]", GREEN))
lines.append(task("Mounting ISO to /tux2lab-data/os-repos/almalinux/10...", "[DONE]", GREEN))
lines.append(whole("[SUCCESS] Setup complete for AlmaLinux 10.", GREEN))
lines.append(prompt("~", ""))

render(lines, "tux2lab-distro-setup.png")
