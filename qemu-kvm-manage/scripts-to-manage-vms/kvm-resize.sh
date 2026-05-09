#!/bin/bash
#----------------------------------------------------------------------------------------#
# If you encounter any issues with this script, or have suggestions or feature requests, #
# please open an issue at: https://github.com/Muthukumar-Subramaniam/tux2lab/issues   #
#----------------------------------------------------------------------------------------#

source /tux2lab/qemu-kvm-manage/scripts-to-manage-vms/functions/defaults.sh
source /tux2lab/common-utils/color-functions.sh

# Function to show help
fn_show_help() {
    print_cyan "Usage: tux2lab vm resize [-f] [memory <GiB>] [cpu <count>] [disk <GiB>] [hostname]

Resources (can be combined in any order):
  memory <GiB>         Set VM memory — power of 2 (2, 4, 8, 16...), less than host memory
  cpu <count>          Set VM vCPUs — power of 2, min 2
  disk <GiB>           Set OS disk to target size — must be larger than current size,
                       multiple of 5, max increase of 100 GiB per operation

Options:
  -f, --force          Force power-off without prompt if VM is running
  -h, --help           Show this help message

Arguments:
  hostname             Name of the VM to resize (optional, will prompt if not given)

Examples:
  tux2lab vm resize vm1                              # Interactive mode
  tux2lab vm resize -f memory 8 vm1                  # Set memory to 8 GiB
  tux2lab vm resize -f cpu 4 vm1                     # Set vCPUs to 4
  tux2lab vm resize -f disk 50 vm1                   # Set OS disk to 50 GiB
  tux2lab vm resize -f memory 8 cpu 4 vm1            # Set memory and CPU together
  tux2lab vm resize -f disk 50 memory 8 cpu 4 vm1    # Resize all three at once
"
}

# Parse arguments
force_poweroff=false
vm_hostname_arg=""
memory_arg=""
cpu_arg=""
disk_arg=""
declare -a resize_order=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            fn_show_help
            exit 0
            ;;
        -f|--force)
            force_poweroff=true
            shift
            ;;
        memory)
            if [[ -z "$2" || "$2" == -* ]]; then
                print_error "'memory' requires a size value in GiB."
                exit 1
            fi
            memory_arg="$2"
            resize_order+=(memory)
            shift 2
            ;;
        cpu)
            if [[ -z "$2" || "$2" == -* ]]; then
                print_error "'cpu' requires a vCPU count value."
                exit 1
            fi
            cpu_arg="$2"
            resize_order+=(cpu)
            shift 2
            ;;
        disk)
            if [[ -z "$2" || "$2" == -* ]]; then
                print_error "'disk' requires a size value in GiB."
                exit 1
            fi
            disk_arg="$2"
            resize_order+=(disk)
            shift 2
            ;;
        -*)
            print_error "Unknown option: $1"
            fn_show_help
            exit 1
            ;;
        *)
            if [[ -n "$vm_hostname_arg" ]]; then
                print_error "Unexpected argument: $1"
                fn_show_help
                exit 1
            fi
            vm_hostname_arg="$1"
            shift
            ;;
    esac
done

# Use argument or prompt for hostname
source /tux2lab/qemu-kvm-manage/scripts-to-manage-vms/functions/input-hostname.sh "$vm_hostname_arg"

# Lab infra server protection
if [[ "$qemu_kvm_hostname" == "$lab_infra_server_hostname" ]]; then
    print_warning "You are about to resize the lab infra server: $lab_infra_server_hostname!"
    print_warning "This operation requires shutting down all lab services temporarily."
    print_warning "CPU/Memory/Disk changes may affect the performance of lab services."
    read -r -p "If you understand the impact, confirm by typing 'resize-lab-infra-server': " confirmation
    if [[ "$confirmation" != "resize-lab-infra-server" ]]; then
        print_info "Operation cancelled by user."
        exit 1
    fi
fi

# Check if VM exists in 'virsh list --all'
print_task "Checking if VM exists..."
if ! sudo virsh list --all | awk '{print $2}' | grep -Fxq "$qemu_kvm_hostname"; then
    print_task_fail
    print_error "VM \"$qemu_kvm_hostname\" does not exist."
    exit 1
fi
print_task_done

fn_shutdown_or_poweroff() {
    # If force flag is set, try graceful shutdown first, then force if needed
    if [[ "$force_poweroff" == true ]]; then
        print_task "Shutting down VM (graceful then force if needed)..."
        source /tux2lab/qemu-kvm-manage/scripts-to-manage-vms/functions/shutdown-vm.sh
        SHUTDOWN_VM_CONTEXT="Attempting graceful shutdown" SHUTDOWN_VM_STRICT=false shutdown_vm "$qemu_kvm_hostname" &>/dev/null
        
        # Wait for VM to shut down with timeout
        TIMEOUT=30
        ELAPSED=0
        while sudo virsh list | awk '{print $2}' | grep -Fxq "$qemu_kvm_hostname"; do
            if (( ELAPSED >= TIMEOUT )); then
                source /tux2lab/qemu-kvm-manage/scripts-to-manage-vms/functions/poweroff-vm.sh
                if ! POWEROFF_VM_CONTEXT="Forcing power off after timeout" POWEROFF_VM_STRICT=true poweroff_vm "$qemu_kvm_hostname" &>/dev/null; then
                    print_task_fail
                    exit 1
                fi
                break
            fi
            sleep 2
            ((ELAPSED+=2))
        done
        
        if ! sudo virsh list | awk '{print $2}' | grep -Fxq "$qemu_kvm_hostname"; then
            print_task_done
        fi
        return 0
    fi
    
    print_warning "VM \"$qemu_kvm_hostname\" is still running!"
    print_info "Select an option to proceed:
  1) Try Graceful Shutdown
  2) Force Power Off
  q) Quit"

    read -rp "Enter your choice: " selected_choice

    case "$selected_choice" in
        1)
            print_task "Shutting down VM gracefully..."
            source /tux2lab/qemu-kvm-manage/scripts-to-manage-vms/functions/shutdown-vm.sh
            if ! SHUTDOWN_VM_CONTEXT="Initiating graceful shutdown" shutdown_vm "$qemu_kvm_hostname" &>/dev/null; then
                print_task_fail
                exit 1
            fi
            
            # Wait for VM to shut down with timeout
            TIMEOUT=60
            ELAPSED=0
            while sudo virsh list | awk '{print $2}' | grep -Fxq "$qemu_kvm_hostname"; do
                if (( ELAPSED >= TIMEOUT )); then
                    print_task_fail
                    print_warning "VM did not shut down within ${TIMEOUT}s."
                    print_info "You may want to force power off instead."
                    exit 1
                fi
                sleep 2
                ((ELAPSED+=2))
            done
            print_task_done
            ;;
        2)
            print_task "Forcing power off VM..."
            source /tux2lab/qemu-kvm-manage/scripts-to-manage-vms/functions/poweroff-vm.sh
            if ! POWEROFF_VM_CONTEXT="Forcing power off" POWEROFF_VM_STRICT=true poweroff_vm "$qemu_kvm_hostname" &>/dev/null; then
                print_task_fail
                exit 1
            fi
            print_task_done
            ;;
        q)
            print_info "Quitting without any action."
            exit 0
            ;;
        *)
            print_error "Invalid option!"
            exit 1
            ;;
    esac
}

validate_memory_args() {
    host_mem_kib=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
    host_mem_gib=$(( host_mem_kib / 1024 / 1024 ))
    (( host_mem_gib % 2 != 0 )) && host_mem_gib=$(( host_mem_gib + 1 ))

    current_mem_kib=$(sudo virsh dominfo "$qemu_kvm_hostname" | awk '/^Max memory/ {print $3}')
    current_vm_mem_gib=$(( current_mem_kib / 1024 / 1024 ))

    if [[ -n "$memory_arg" ]]; then
        if ! [[ "$memory_arg" =~ ^[0-9]+$ ]]; then
            print_error "Invalid memory size: $memory_arg. Must be numeric."
            exit 1
        fi
        if (( memory_arg < 2 || (memory_arg & (memory_arg - 1)) != 0 )); then
            print_error "Memory size must be a power of 2 (2, 4, 8...)."
            exit 1
        fi
        if (( memory_arg >= host_mem_gib )); then
            print_error "Memory size must be less than host memory ${host_mem_gib} GiB."
            exit 1
        fi
        if (( memory_arg == current_vm_mem_gib )); then
            print_error "New memory size (${memory_arg} GiB) is same as current memory size."
            exit 1
        fi
    fi
}

validate_cpu_args() {
    current_vcpus_of_vm=$(sudo virsh dominfo "$qemu_kvm_hostname" | awk '/^CPU\(s\)/ {print $2}')
    host_cpu_count=$(nproc)

    if [[ -n "$cpu_arg" ]]; then
        if ! [[ "$cpu_arg" =~ ^[0-9]+$ ]]; then
            print_error "Invalid vCPU count: $cpu_arg. Must be numeric."
            exit 1
        fi
        if (( cpu_arg < 2 )); then
            print_error "vCPU count must be at least 2."
            exit 1
        fi
        if ! (( (cpu_arg & (cpu_arg - 1)) == 0 )); then
            print_error "vCPU count must be a power of 2 (2, 4, 8...)."
            exit 1
        fi
        if (( cpu_arg > host_cpu_count )); then
            print_error "Cannot exceed host CPU count ${host_cpu_count}."
            exit 1
        fi
        if (( cpu_arg == current_vcpus_of_vm )); then
            print_error "New vCPU count (${cpu_arg}) is same as current vCPU count."
            exit 1
        fi
    fi
}

validate_disk_args() {
    vm_qcow2_disk_path="/tux2lab-data/vms/${qemu_kvm_hostname}/${qemu_kvm_hostname}.qcow2"

    if [ ! -f "$vm_qcow2_disk_path" ]; then
        print_error "OS disk image not found at $vm_qcow2_disk_path"
        exit 1
    fi

    # Get current disk size (works whether VM is running or stopped)
    local capacity_bytes
    capacity_bytes=$(sudo virsh domblkinfo "$qemu_kvm_hostname" vda 2>/dev/null | awk '/^Capacity:/ {print $2}')
    if [[ -n "$capacity_bytes" && "$capacity_bytes" -gt 0 ]] 2>/dev/null; then
        current_disk_gib=$(( capacity_bytes / 1024 / 1024 / 1024 ))
    else
        current_disk_gib=$(sudo qemu-img info "${vm_qcow2_disk_path}" 2>/dev/null | awk '/virtual size/ {for(i=1;i<=NF;i++) if($i ~ /^[0-9]+$/ && $(i+1)=="GiB") {print $i; exit}}')
    fi

    if [[ -z "$current_disk_gib" || "$current_disk_gib" -eq 0 ]] 2>/dev/null; then
        print_error "Unable to determine current OS disk size for VM '$qemu_kvm_hostname'."
        exit 1
    fi

    if [[ -n "$disk_arg" ]]; then
        if ! [[ "$disk_arg" =~ ^[0-9]+$ ]]; then
            print_error "Invalid OS disk size: $disk_arg. Must be numeric."
            exit 1
        fi
        if (( disk_arg % 5 != 0 )); then
            print_error "OS disk size must be a multiple of 5 GiB."
            exit 1
        fi
        if (( disk_arg <= current_disk_gib )); then
            print_error "Target size (${disk_arg} GiB) must be larger than current OS disk size (${current_disk_gib} GiB)."
            exit 1
        fi
        if (( disk_arg - current_disk_gib > 100 )); then
            print_error "Increase of $(( disk_arg - current_disk_gib )) GiB exceeds max of 100 GiB per operation."
            exit 1
        fi
    fi
}

resize_vm_memory() {
    host_mem_kib=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    host_mem_gib=$(( host_mem_kib / 1024 / 1024 ))
    (( host_mem_gib % 2 != 0 )) && host_mem_gib=$(( host_mem_gib + 1 ))

    current_mem_kib=$(sudo virsh dominfo "$qemu_kvm_hostname" | awk '/^Max memory/ {print $3}')
    current_vm_mem_gib=$(( current_mem_kib / 1024 / 1024 ))

    # Get memory size from argument or prompt
    if [[ -n "$memory_arg" ]]; then
        vm_mem_gib="$memory_arg"
    else
        # Prompt for memory size
        print_info "Memory of Host Machine: ${host_mem_gib} GiB"
        print_info "Memory of VM '${qemu_kvm_hostname}': ${current_vm_mem_gib} GiB"
        print_info "Allowed sizes: Powers of 2 — e.g., 2, 4, 8... but less than ${host_mem_gib} GiB"

        while true; do
            read -rp "Enter new VM memory size (GiB): " vm_mem_gib

            if ! [[ "$vm_mem_gib" =~ ^[0-9]+$ ]]; then
                print_error "Invalid input for VM memory size. Must be numeric."
                continue
            fi

            if (( vm_mem_gib < 2 || (vm_mem_gib & (vm_mem_gib - 1)) != 0 )); then
                print_error "VM memory size must be a power of 2 (2, 4, 8...)"
                continue
            fi

            if (( vm_mem_gib >= host_mem_gib )); then
                print_error "VM memory size must be less than host memory ${host_mem_gib} GiB"
                continue
            fi

            if (( vm_mem_gib == current_vm_mem_gib )); then
                print_error "New memory size is same as current memory size (${current_vm_mem_gib} GiB)"
                continue
            fi
            break
        done
    fi

    vm_mem_kib=$(( vm_mem_gib * 1024 * 1024 ))
    print_task "Updating VM memory to ${vm_mem_gib} GiB..."
    if sudo virsh setmaxmem "$qemu_kvm_hostname" "$vm_mem_kib" --config &>/dev/null && \
       sudo virsh setmem "$qemu_kvm_hostname" "$vm_mem_kib" --config &>/dev/null; then
        print_task_done
        resize_summary+=("VM '${qemu_kvm_hostname}' memory resized to ${vm_mem_gib} GiB.")
    else
        print_task_fail
        print_error "Failed to update VM memory."
        exit 1
    fi
}

resize_vm_cpu() {
    current_vcpus_of_vm=$(sudo virsh dominfo "$qemu_kvm_hostname" | awk '/^CPU\(s\)/ {print $2}')
    host_cpu_count=$(nproc)

    # Get CPU count from argument or prompt
    if [[ -n "$cpu_arg" ]]; then
        new_vcpus_of_vm="$cpu_arg"
    else
        # Prompt for CPU count
        print_info "Host logical CPUs: $host_cpu_count"
        print_info "Current vCPUs of VM '${qemu_kvm_hostname}': $current_vcpus_of_vm"
        print_info "Allowed values: Powers of 2 — e.g., 2, 4, 8... up to ${host_cpu_count}"

        while true; do
            read -rp "Enter new vCPU count: " new_vcpus_of_vm

            if ! [[ "$new_vcpus_of_vm" =~ ^[0-9]+$ ]]; then
                print_error "Invalid input for vCPU count. Must be numeric."
                continue
            fi

            if (( new_vcpus_of_vm < 2 )); then
                print_error "vCPU count must be at least 2."
                continue
            fi

            if ! (( (new_vcpus_of_vm & (new_vcpus_of_vm - 1)) == 0 )); then
                print_error "vCPU count must be a power of 2 (2, 4, 8...)"
                continue
            fi

            if (( new_vcpus_of_vm > host_cpu_count )); then
                print_error "Cannot exceed host CPU count ${host_cpu_count}"
                continue
            fi

            if (( new_vcpus_of_vm == current_vcpus_of_vm )); then
                print_error "New vCPU count is same as current vCPU count (${current_vcpus_of_vm})"
                continue
            fi
            break
        done
    fi

    print_task "Updating VM vCPUs to ${new_vcpus_of_vm}..."
    if sudo virsh setvcpus "$qemu_kvm_hostname" "$new_vcpus_of_vm" --maximum --config &>/dev/null && \
       sudo virsh setvcpus "$qemu_kvm_hostname" "$new_vcpus_of_vm" --config &>/dev/null; then
        print_task_done
        resize_summary+=("VM '${qemu_kvm_hostname}' vCPUs resized to ${new_vcpus_of_vm}.")
    else
        print_task_fail
        print_error "Failed to update vCPU count."
        exit 1
    fi
}

resize_vm_disk() {
    # Get target disk size from argument or prompt
    if [[ -n "$disk_arg" ]]; then
        target_disk_gib="$disk_arg"
    else
        # current_disk_gib may not be set if interactive mode (no validate_disk_args call)
        if [[ -z "$current_disk_gib" ]]; then
            vm_qcow2_disk_path="/tux2lab-data/vms/${qemu_kvm_hostname}/${qemu_kvm_hostname}.qcow2"

            if [ ! -f "$vm_qcow2_disk_path" ]; then
print_error "OS disk image not found at $vm_qcow2_disk_path"
            exit 1
        fi

            current_disk_gib=$(sudo qemu-img info "${vm_qcow2_disk_path}" 2>/dev/null | awk '/virtual size/ {for(i=1;i<=NF;i++) if($i ~ /^[0-9]+$/ && $(i+1)=="GiB") {print $i; exit}}')
        fi

        # Prompt for target disk size
        print_info "Current OS disk size of VM '${qemu_kvm_hostname}': ${current_disk_gib} GiB"
        print_info "Enter a target size larger than ${current_disk_gib} GiB (multiple of 5, max increase: 100 GiB)"

        while true; do
            read -rp "Enter target disk size (GiB): " target_disk_gib

            if ! [[ "$target_disk_gib" =~ ^[0-9]+$ ]]; then
                print_error "Invalid input for OS disk size. Must be numeric."
                continue
            fi

            if (( target_disk_gib % 5 != 0 )); then
                print_error "OS disk size must be a multiple of 5 GiB."
                continue
            fi

            if (( target_disk_gib <= current_disk_gib )); then
                print_error "Target size must be larger than current OS disk size (${current_disk_gib} GiB)."
                continue
            fi

            if (( target_disk_gib - current_disk_gib > 100 )); then
                print_error "Increase of $(( target_disk_gib - current_disk_gib )) GiB exceeds max of 100 GiB per operation."
                continue
            fi
            break
        done
    fi

    grow_size_gib=$(( target_disk_gib - current_disk_gib ))

    print_task "Growing OS disk by ${grow_size_gib} GiB (${current_disk_gib} → ${target_disk_gib} GiB)..."
    if sudo qemu-img resize "$vm_qcow2_disk_path" +${grow_size_gib}G &>/dev/null; then
        print_task_done
        disk_was_resized=true
        resize_summary+=("VM '${qemu_kvm_hostname}' OS disk resized to ${target_disk_gib} GiB.")
    else
        print_task_fail
        print_error "OS disk resize failed!"
        exit 1
    fi
}

# Check if VM is running and shutdown if needed
fn_check_vm_power_state() {
    if ! sudo virsh list | awk '{print $2}' | grep -Fxq "$qemu_kvm_hostname"; then
        print_info "VM is not running."
    else
        fn_shutdown_or_poweroff
    fi
}

# Start VM after all resize operations and handle disk post-steps
fn_start_vm_after_resize() {
    print_task "Starting VM..."
    if sudo virsh start "${qemu_kvm_hostname}" &>/dev/null; then
        print_task_done
    else
        print_task_fail
        print_error "Failed to start VM after resize."
        exit 1
    fi

    if [[ "$disk_was_resized" == true ]]; then
        print_task "Waiting for SSH access..."
        SSH_TARGET_HOST="${qemu_kvm_hostname}"
        MAX_SSH_WAIT_SECONDS=120
        SSH_RETRY_INTERVAL_SECONDS=5
        SSH_OPTS="-o LogLevel=QUIET -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

        ssh_start_time=$(date +%s)
        while true; do
            sleep "$SSH_RETRY_INTERVAL_SECONDS"
            if ssh $SSH_OPTS ${lab_infra_admin_username}@${SSH_TARGET_HOST} "true" &>/dev/null; then
                print_task_done
                break
            fi
            ssh_current_time=$(date +%s)
            ssh_elapsed_time=$((ssh_current_time - ssh_start_time))
            if [ "$ssh_elapsed_time" -ge "$MAX_SSH_WAIT_SECONDS" ]; then
                print_task_fail
                print_warning "Timed out waiting for SSH after $MAX_SSH_WAIT_SECONDS seconds."
                print_info "Execute lab-rootfs-extender utility manually from $SSH_TARGET_HOST once booted."
                exit 1
            fi
        done

        if ! /tux2lab/common-utils/lab-rootfs-extender $SSH_TARGET_HOST; then
            print_error "Failed to extend root filesystem."
            exit 1
        fi
    fi

    # Print summary of all resize operations
    for msg in "${resize_summary[@]}"; do
        print_success "$msg"
    done
}

# Initialize tracking variables
declare -a resize_summary=()
disk_was_resized=false

# Check if any resource type was provided on the command line
if [[ ${#resize_order[@]} -gt 0 ]]; then
    # Automated mode — validate, shutdown, apply, start once (in CLI order)
    for type in "${resize_order[@]}"; do
        case "$type" in
            memory) validate_memory_args ;;
            cpu)    validate_cpu_args ;;
            disk)   validate_disk_args ;;
        esac
    done

    fn_check_vm_power_state

    for type in "${resize_order[@]}"; do
        case "$type" in
            memory) resize_vm_memory ;;
            cpu)    resize_vm_cpu ;;
            disk)   resize_vm_disk ;;
        esac
    done

    fn_start_vm_after_resize
    exit 0
fi

# Interactive mode — show menu with multi-select
print_info "Select resource(s) to resize for VM '$qemu_kvm_hostname':
  1) Memory
  2) CPU
  3) Disk
  a) All (Memory + CPU + Disk)
  q) Quit

Enter choice(s) — comma-separated for multiple (e.g., 1,3):"

while true; do
    read -rp "Choice: " resize_choice

    do_memory=false
    do_cpu=false
    do_disk=false
    valid_input=true

    case "$resize_choice" in
        q)
            print_info "Quitting without any action."
            exit 0
            ;;
        a)
            do_memory=true
            do_cpu=true
            do_disk=true
            ;;
        *)
            IFS=',' read -ra choices <<< "$resize_choice"
            for c in "${choices[@]}"; do
                c="${c#"${c%%[![:space:]]*}"}"
                c="${c%"${c##*[![:space:]]}"}"
                case "$c" in
                    1) do_memory=true ;;
                    2) do_cpu=true ;;
                    3) do_disk=true ;;
                    *)
                        print_error "Invalid option: $c"
                        valid_input=false
                        break
                        ;;
                esac
            done
            ;;
    esac

    if [[ "$valid_input" == true ]] && [[ "$do_memory" == true || "$do_cpu" == true || "$do_disk" == true ]]; then
        break
    fi
done

fn_check_vm_power_state

[[ "$do_memory" == true ]] && resize_vm_memory
[[ "$do_cpu" == true ]] && resize_vm_cpu
[[ "$do_disk" == true ]] && resize_vm_disk

fn_start_vm_after_resize
