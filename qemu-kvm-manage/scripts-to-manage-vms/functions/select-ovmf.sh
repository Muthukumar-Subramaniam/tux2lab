OVMF_CODE_PATH='/tux2lab/qemu-kvm-manage/ovmf-uefi-firmware/OVMF_CODE.fd'
OVMF_VARS_PATH='/tux2lab/qemu-kvm-manage/ovmf-uefi-firmware/OVMF_VARS.fd'

# Fallback to system OVMF firmware if vendored firmware is missing
if [[ ! -f "$OVMF_CODE_PATH" ]]; then
    if [[ -f /usr/share/edk2/ovmf/OVMF_CODE.fd ]]; then
        OVMF_CODE_PATH='/usr/share/edk2/ovmf/OVMF_CODE.fd'
        OVMF_VARS_PATH='/usr/share/edk2/ovmf/OVMF_VARS.fd'
    elif [[ -f /usr/share/OVMF/OVMF_CODE_4M.fd ]]; then
        OVMF_CODE_PATH='/usr/share/OVMF/OVMF_CODE_4M.fd'
        OVMF_VARS_PATH='/usr/share/OVMF/OVMF_VARS_4M.fd'
    fi
fi

# Explicitly declare NVRAM template format as raw. Libvirt >= 11.6 defaults
# to qcow2 NVRAM and refuses raw templates without this hint. Older libvirt
# silently ignores the attribute — safe to set unconditionally.
OVMF_NVRAM_TEMPLATE_FORMAT_OPT=",nvram.templateFormat=raw"
