#!/usr/bin/env python3
from render_common import *

HBAR = "━"*74
lines = []
lines.append(prompt("~", "tux2lab golden-image build almalinux -v 10"))
lines.append(task("Checking internet connectivity...", "[DONE]", GREEN))
lines.append(task("Generating MAC address for golden image VM...", "[DONE]", GREEN))
lines.append(whole("[INFO] Creating PXE environment for golden image...", MAGENTA))
lines.append(whole("[INFO] OS distribution selected: almalinux 10", MAGENTA))
lines.append(task("Creating DNS record...", "[DONE]", GREEN))
lines.append(task("Flushing DNS cache...", "[DONE]", GREEN))
lines.append(task("Caching MAC address...", "[DONE]", GREEN))
lines.append(task("Generating kickstart profile and iPXE configs...", "[DONE]", GREEN))
lines.append(task("Finalizing configuration files...", "[DONE]", GREEN))
lines.append(task("Updating KEA DHCP reservations...", "[DONE]", GREEN))
lines.append(task("Updating provisioning registry...", "[DONE]", GREEN))
lines.append(whole("[INFO] Kickstart configs ready.", MAGENTA))
lines.append(whole("[INFO] Starting installation to create the golden image disk...", MAGENTA))
lines.append(whole(HBAR, CYAN))
lines.append(whole("Preparing Golden Image with OS Installation via PXE Network Boot", CYAN))
lines.append(whole(HBAR, CYAN))
lines.append(whole("  To monitor: tux2lab vm console -H almalinux-10-golden-image.musubram.internal", YELLOW))
lines.append(whole("  This may take several minutes depending on the distribution and internet speed.", YELLOW))
lines.append(whole("  ✓ Golden image preparation completed (4m 28s)", GREEN))
lines.append(task("Cleaning up provisioning environment...", "[DONE]", GREEN))
lines.append(task("Cleaning up temporary VM...", "[DONE]", GREEN))
lines.append(whole("[SUCCESS] Golden image created successfully for almalinux 10", GREEN))
lines.append(prompt("~", ""))

render(lines, "tux2lab-golden-build.png")
