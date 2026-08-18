# Prefer system OVMF firmware (matches installed QEMU), fall back to vendored copy
if [[ -f /usr/share/edk2/ovmf/OVMF_CODE.fd ]]; then
    # RHEL/Fedora/CentOS (edk2-ovmf)
    OVMF_CODE_PATH='/usr/share/edk2/ovmf/OVMF_CODE.fd'
    OVMF_VARS_PATH='/usr/share/edk2/ovmf/OVMF_VARS.fd'
elif [[ -f /usr/share/qemu/ovmf-x86_64-code.bin ]]; then
    # openSUSE/SLES (qemu-ovmf-x86_64) — raw .bin firmware
    OVMF_CODE_PATH='/usr/share/qemu/ovmf-x86_64-code.bin'
    OVMF_VARS_PATH='/usr/share/qemu/ovmf-x86_64-vars.bin'
else
    OVMF_CODE_PATH='/tux2lab/qemu-kvm-manage/ovmf-uefi-firmware/OVMF_CODE.fd'
    OVMF_VARS_PATH='/tux2lab/qemu-kvm-manage/ovmf-uefi-firmware/OVMF_VARS.fd'
fi

# Explicitly declare NVRAM template format as raw. Libvirt >= 11.6 defaults
# to qcow2 NVRAM and refuses raw templates without this hint. Older libvirt
# silently ignores the attribute — safe to set unconditionally.
OVMF_NVRAM_TEMPLATE_FORMAT_OPT=",nvram.templateFormat=raw"
