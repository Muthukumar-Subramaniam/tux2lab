#!/bin/bash
#
# shutdown-vm.sh
# 
# Gracefully shuts down a running VM using virsh shutdown (sends ACPI signal)
# This requires guest tools to be installed for proper handling
#
# Usage:
#   source /path/to/shutdown-vm.sh
#   
#   # Default behavior: errors cause return 1
#   shutdown_vm "vm-hostname"
#   
#   # Warnings only mode: always returns 0
#   SHUTDOWN_VM_STRICT=false shutdown_vm "vm-hostname"
#   
#   # Custom message context
#   SHUTDOWN_VM_CONTEXT="for maintenance" shutdown_vm "vm-hostname"
#
# Environment Variables:
#   SHUTDOWN_VM_STRICT - If "false", warnings only (default: true, returns 1 on errors)
#   SHUTDOWN_VM_CONTEXT - Custom context message (default: "Sending shutdown signal")
#
# Returns:
#   0 - VM shutdown signal sent successfully or wasn't running
#   1 - Failed to send shutdown signal (only in strict mode)

shutdown_vm() {
    local vm_hostname="$1"
    local context="${SHUTDOWN_VM_CONTEXT:-Sending shutdown signal}"
    local strict_mode="${SHUTDOWN_VM_STRICT:-true}"
    
    if [[ -z "$vm_hostname" ]]; then
        print_error "shutdown_vm: VM hostname not provided."
        return 1
    fi
    
    # Check if VM exists
    if ! sudo virsh list --all | awk -v vm="$vm_hostname" '$2 == vm {found=1; exit} END {exit !found}'; then
        print_error "VM \"$vm_hostname\" does not exist."
        return 1
    fi
    
    # Check if VM is running
    if ! sudo virsh list | awk -v vm="$vm_hostname" '$2 == vm {found=1; exit} END {exit !found}'; then
        print_info "VM \"$vm_hostname\" is not running (already stopped)."
        return 0
    fi
    
    # VM is running, proceed with graceful shutdown
    print_task "${context} to VM \"$vm_hostname\"..."
    
    if error_msg=$(sudo virsh shutdown "$vm_hostname" 2>&1); then
        print_task_done
        return 0
    else
        if [[ "$strict_mode" == "true" ]]; then
            print_task_fail
            print_error "$error_msg"
            return 1
        else
            print_warning "Could not send shutdown signal to VM \"$vm_hostname\"."
            print_warning "$error_msg"
            return 0
        fi
    fi
}
