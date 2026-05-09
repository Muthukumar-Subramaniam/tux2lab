#!/bin/bash
#----------------------------------------------------------------------------------------#
# Get MAC Address from Existing VM                                                      #
#----------------------------------------------------------------------------------------#

# Function to get the MAC address of the first network interface of an existing VM
get_vm_mac_address() {
    local vm_name="$1"
    local mac
    local vm_xml="/etc/libvirt/qemu/${vm_name}.xml"

    # Extract MAC address directly from the VM XML definition file
    mac=$(sudo grep -oP "(?<=<mac address=')[^']+" "$vm_xml" 2>/dev/null | head -1)

    if [[ -z "$mac" ]]; then
        return 1
    fi

    echo "$mac"
    return 0
}
