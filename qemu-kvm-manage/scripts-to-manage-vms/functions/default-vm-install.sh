# Set default values if not provided
DISK_PATH="${DISK_PATH:-/tux2lab-data/vms/${qemu_kvm_hostname}/${qemu_kvm_hostname}.qcow2}"
NVRAM_PATH="${NVRAM_PATH:-/tux2lab-data/vms/${qemu_kvm_hostname}/${qemu_kvm_hostname}_VARS.fd}"

VENDORED_VIRT_MANAGER_DIR="/tux2lab/vendor/virt-manager"

if ! virt_install_error=$(sudo PYTHONPATH="${VENDORED_VIRT_MANAGER_DIR}" python3 "${VENDORED_VIRT_MANAGER_DIR}/virt-install" \
  --name "${qemu_kvm_hostname}" \
  --features acpi=on,apic=on \
  --memory 2048 \
  --vcpus 2 \
  --disk "path=${DISK_PATH},size=20,bus=virtio,boot.order=1" \
  --os-variant "${OS_VARIANT:-almalinux9}" \
  --network "network=tux2lab,model=virtio,mac=${GENERATED_MAC},boot.order=2" \
  --graphics none \
  --noautoconsole \
  --machine q35 \
  --watchdog none \
  --cpu host-model \
  --boot "loader=${OVMF_CODE_PATH},nvram.template=${OVMF_VARS_PATH}${OVMF_NVRAM_TEMPLATE_FORMAT_OPT},nvram=${NVRAM_PATH},menu=on" \
  2>&1 >/dev/null); then
    echo "$virt_install_error" >&2
    return 1
fi
