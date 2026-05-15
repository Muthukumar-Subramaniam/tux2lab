#!/usr/bin/env bash
#----------------------------------------------------------------------------------------#
# If you encounter any issues with this script, or have suggestions or feature requests, #
# please open an issue at: https://github.com/Muthukumar-Subramaniam/tux2lab/issues   #
#----------------------------------------------------------------------------------------#
set -euo pipefail

source /tux2lab/common-utils/color-functions.sh
source /tux2lab/qemu-kvm-manage/scripts-to-manage-vms/functions/defaults.sh

# Function to show help
fn_show_help() {
    print_cyan "Usage: tux2lab vm disk-delete [OPTIONS]
Options:
  -d, --disks <list>   Comma-separated list of disk files to delete from detached storage
  -h, --help           Show this help message

Examples:
  tux2lab vm disk-delete                         # Interactive mode - select disks
  tux2lab vm disk-delete -d disk1.qcow2,disk2.qcow2  # Delete specific disks

WARNING:
  This permanently deletes disk files from detached storage.
  Deleted disks cannot be recovered!
"
}

# Parse arguments
disks_arg=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            fn_show_help
            exit 0
            ;;
        -d|--disks)
            if [[ -z "${2:-}" || "${2:-}" == -* ]]; then
                print_error "Option -d/--disks requires a value."
                exit 1
            fi
            disks_arg="$2"
            shift 2
            ;;
        -*)
            print_error "Unknown option: $1"
            fn_show_help
            exit 1
            ;;
        *)
            print_error "Unexpected argument: $1"
            print_info "This command does not take positional arguments."
            fn_show_help
            exit 1
            ;;
    esac
done

DETACHED_DIR="/tux2lab-data/detached-data-disks"

# Check detached disks directory
if [[ ! -d "$DETACHED_DIR" ]]; then
    print_error "Detached disks directory does not exist: $DETACHED_DIR"
    print_info "No detached disks available to delete."
    exit 1
fi

# Get list of available detached disks
print_info "Scanning detached disks..."
AVAILABLE_DISKS=()
while IFS= read -r disk_file; do
    AVAILABLE_DISKS+=("$(basename "$disk_file")")
done < <(sudo find "$DETACHED_DIR" -maxdepth 1 -type f -name "*.qcow2" 2>/dev/null)

if [[ ${#AVAILABLE_DISKS[@]} -eq 0 ]]; then
    print_warning "No detached disks found in $DETACHED_DIR"
    exit 0
fi

# Get disks to delete (from argument or prompt)
DISKS_TO_DELETE=()

# Escape dots in hostname for regex matching
escaped_infra_hostname="${lab_infra_server_hostname//./\\.}"

if [[ -n "$disks_arg" ]]; then
    # Parse comma-separated disk list
    IFS=',' read -ra DISKS_TO_DELETE <<< "$disks_arg"
    
    # Validate each disk
    for disk in "${DISKS_TO_DELETE[@]}"; do
        # Remove whitespace
        disk="${disk#"${disk%%[![:space:]]*}"}"  # Trim leading
        disk="${disk%"${disk##*[![:space:]]}"}"  # Trim trailing
        
        # Check if disk exists in detached directory
        if [[ ! -f "$DETACHED_DIR/$disk" ]]; then
            print_error "Disk $disk not found in detached storage: $DETACHED_DIR"
            exit 1
        fi
    done
    print_info "Using specified disks: ${DISKS_TO_DELETE[*]}"
else
    # Interactive mode - show available disks with lab infra highlighting
    print_notify "Available detached disks:"
    for i in "${!AVAILABLE_DISKS[@]}"; do
        disk="${AVAILABLE_DISKS[$i]}"
        disk_path="$DETACHED_DIR/$disk"
        disk_size=""
        if [[ -f "$disk_path" ]]; then
            disk_size=$(sudo qemu-img info "$disk_path" | awk '/virtual size/ {print $3, $4}')
        fi
        
        # Highlight lab infra server disks
        if [[ "$disk" =~ ^${escaped_infra_hostname}_vd[b-z]\.qcow2$ ]]; then
            if [[ -n "$disk_size" ]]; then
                print_yellow "  $((i+1))) $disk ($disk_size) [LAB INFRA SERVER]"
            else
                print_yellow "  $((i+1))) $disk [LAB INFRA SERVER]"
            fi
        else
            if [[ -n "$disk_size" ]]; then
                echo "  $((i+1))) $disk ($disk_size)"
            else
                echo "  $((i+1))) $disk"
            fi
        fi
    done
    echo "  q) Quit"
    
    print_info "Enter disk numbers to delete (space-separated, e.g., '1 3' or 'all' for all disks):"
    read -rp "Selection: " selection
    
    if [[ "$selection" == "q" || "$selection" == "Q" ]]; then
        print_info "Quitting without any action."
        exit 0
    fi
    
    if [[ "$selection" == "all" || "$selection" == "ALL" ]]; then
        DISKS_TO_DELETE=("${AVAILABLE_DISKS[@]}")
        print_info "Selected all disks: ${DISKS_TO_DELETE[*]}"
    else
        # Parse space-separated numbers
        for num in $selection; do
            if [[ ! "$num" =~ ^[0-9]+$ ]]; then
                print_error "Invalid selection: $num"
                exit 1
            fi
            idx=$((num - 1))
            if (( idx < 0 || idx >= ${#AVAILABLE_DISKS[@]} )); then
                print_error "Invalid disk number: $num"
                exit 1
            fi
            DISKS_TO_DELETE+=("${AVAILABLE_DISKS[$idx]}")
        done
        print_info "Selected disks: ${DISKS_TO_DELETE[*]}"
    fi
fi

# Check if any selected disks belong to lab infra server
lab_infra_disks=()
for disk in "${DISKS_TO_DELETE[@]}"; do
    if [[ "$disk" =~ ^${escaped_infra_hostname}_vd[b-z]\.qcow2$ ]]; then
        lab_infra_disks+=("$disk")
    fi
done

# Confirm deletion
print_warning "WARNING: The following disk(s) will be PERMANENTLY DELETED:"
for disk in "${DISKS_TO_DELETE[@]}"; do
    disk_path="$DETACHED_DIR/$disk"
    disk_size=""
    if [[ -f "$disk_path" ]]; then
        disk_size=$(sudo qemu-img info "$disk_path" | awk '/virtual size/ {print $3, $4}')
    fi
    
    # Highlight lab infra server disks
    if [[ "$disk" =~ ^${escaped_infra_hostname}_vd[b-z]\.qcow2$ ]]; then
        if [[ -n "$disk_size" ]]; then
            print_yellow "  - $disk ($disk_size) [LAB INFRA SERVER]"
        else
            print_yellow "  - $disk [LAB INFRA SERVER]"
        fi
    else
        if [[ -n "$disk_size" ]]; then
            echo "  - $disk ($disk_size)"
        else
            echo "  - $disk"
        fi
    fi
done

print_warning "This action CANNOT be undone!"

# Special confirmation for lab infra server disks
if [[ ${#lab_infra_disks[@]} -gt 0 ]]; then
    echo ""
    print_warning "⚠️  WARNING: You are deleting ${#lab_infra_disks[@]} disk(s) from the lab infra server!"
    print_warning "These disks belonged to: $lab_infra_server_hostname"
    print_warning "Ensure you have backups before proceeding."
    read -rp "Type 'delete-lab-infra-disks' to confirm deletion of lab infra server disks: " lab_confirm
    if [[ "$lab_confirm" != "delete-lab-infra-disks" ]]; then
        print_info "Operation cancelled by user."
        exit 0
    fi
fi

read -rp "Type 'DELETE' in uppercase to confirm permanent deletion: " confirm
if [[ "$confirm" != "DELETE" ]]; then
    print_info "Operation cancelled."
    exit 0
fi

# Delete disks
deleted_count=0
for disk in "${DISKS_TO_DELETE[@]}"; do
    disk_path="$DETACHED_DIR/$disk"
    
    print_task "Deleting $disk..." nskip
    if error_msg=$(sudo rm -f "$disk_path" 2>&1); then
        print_task_done
        ((++deleted_count))
    else
        print_task_fail
        print_error "$error_msg"
        continue
    fi
done

if [[ $deleted_count -eq 0 ]]; then
    print_error "Failed to delete any disks."
    exit 1
fi

print_success "Permanently deleted $deleted_count disk(s) from detached storage."
print_info "Deleted disks cannot be recovered."
