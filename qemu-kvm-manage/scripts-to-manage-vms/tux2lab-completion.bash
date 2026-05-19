#!/usr/bin/env bash
#----------------------------------------------------------------------------------------#
# If you encounter any issues with this script, or have suggestions or feature requests, #
# please open an issue at: https://github.com/Muthukumar-Subramaniam/tux2lab/issues   #
#----------------------------------------------------------------------------------------#
# Script Name : tux2lab-completion.bash
# Description : Bash completion script for tux2lab
# Installation: Source this file in your ~/.bashrc or copy to /etc/bash_completion.d/
# Usage       : source tux2lab-completion.bash

_tux2lab_completions() {
    local cur prev subcommands
    COMPREPLY=()
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD-1]}"
    
    # Top-level commands
    local commands="vm golden-image distro ipv6-route deploy destroy rebuild start stop enable disable health dns version"
    
    # Top-level options
    local options="-h --help -v --version"
    
    # VM subcommands
    local vm_subcommands="install-golden install-pxe reimage-golden reimage-pxe start stop shutdown restart reboot remove list info validate console resize disk-add disk-resize disk-attach disk-detach disk-delete nic-add nic-remove snapshot-create snapshot-list snapshot-info snapshot-delete snapshot-revert"
    
    # Distro subcommands
    local distro_subcommands="list setup cleanup download-infra-iso"
    
    # Golden image subcommands
    local golden_image_subcommands="build list cleanup"
    
    # IPv6 route subcommands
    local ipv6_route_subcommands="enable disable check auto status"
    
    # If we're completing the first argument (command)
    if [[ ${COMP_CWORD} -eq 1 ]]; then
        if [[ ${cur} == -* ]]; then
            COMPREPLY=( $(compgen -W "${options}" -- "${cur}") )
        else
            COMPREPLY=( $(compgen -W "${commands}" -- "${cur}") )
        fi
        return 0
    fi
    
    # If the first argument is "vm", complete vm subcommands
    if [[ "${COMP_WORDS[1]}" == "vm" ]]; then
        if [[ ${COMP_CWORD} -eq 2 ]]; then
            if [[ ${cur} == -* ]]; then
                COMPREPLY=( $(compgen -W "-h --help -v --version" -- "${cur}") )
            else
                COMPREPLY=( $(compgen -W "${vm_subcommands}" -- "${cur}") )
            fi
            return 0
        fi
        
        # Complete flags after vm subcommand
        if [[ ${cur} == -* ]]; then
            COMPREPLY=( $(compgen -W "-h --help -f" -- "${cur}") )
            return 0
        fi
    fi
    
    # If the first argument is "distro", complete distro subcommands
    if [[ "${COMP_WORDS[1]}" == "distro" ]]; then
        if [[ ${COMP_CWORD} -eq 2 ]]; then
            if [[ ${cur} == -* ]]; then
                COMPREPLY=( $(compgen -W "-h --help" -- "${cur}") )
            else
                COMPREPLY=( $(compgen -W "${distro_subcommands}" -- "${cur}") )
            fi
            return 0
        fi
        
        # Complete distro names after setup/cleanup
        if [[ ${COMP_CWORD} -eq 3 ]] && [[ "${COMP_WORDS[2]}" == "setup" || "${COMP_WORDS[2]}" == "cleanup" ]]; then
            COMPREPLY=( $(compgen -W "almalinux rocky oraclelinux centos-stream rhel ubuntu-lts opensuse-leap" -- "${cur}") )
            return 0
        fi

        # Complete RHEL-based distro names after download-infra-iso
        if [[ ${COMP_CWORD} -eq 3 ]] && [[ "${COMP_WORDS[2]}" == "download-infra-iso" ]]; then
            COMPREPLY=( $(compgen -W "almalinux rocky oraclelinux centos-stream rhel" -- "${cur}") )
            return 0
        fi
        
        # Complete --version after distro name
        if [[ ${COMP_CWORD} -eq 4 ]] && [[ ${cur} == -* ]]; then
            COMPREPLY=( $(compgen -W "--version" -- "${cur}") )
            return 0
        fi
    fi
    
    # If the first argument is "ipv6-route", complete ipv6-route subcommands
    if [[ "${COMP_WORDS[1]}" == "ipv6-route" ]]; then
        if [[ ${COMP_CWORD} -eq 2 ]]; then
            if [[ ${cur} == -* ]]; then
                COMPREPLY=( $(compgen -W "-h --help" -- "${cur}") )
            else
                COMPREPLY=( $(compgen -W "${ipv6_route_subcommands}" -- "${cur}") )
            fi
            return 0
        fi
    fi
    
    # If the first argument is "golden-image", complete golden-image subcommands
    if [[ "${COMP_WORDS[1]}" == "golden-image" ]]; then
        if [[ ${COMP_CWORD} -eq 2 ]]; then
            if [[ ${cur} == -* ]]; then
                COMPREPLY=( $(compgen -W "-h --help" -- "${cur}") )
            else
                COMPREPLY=( $(compgen -W "${golden_image_subcommands}" -- "${cur}") )
            fi
            return 0
        fi
        
        # Complete distro names after -d/--distro flag for build/cleanup
        if [[ "${COMP_WORDS[2]}" == "build" || "${COMP_WORDS[2]}" == "cleanup" ]] && [[ "${prev}" == "-d" || "${prev}" == "--distro" ]]; then
            COMPREPLY=( $(compgen -W "almalinux rocky oraclelinux centos-stream rhel ubuntu-lts opensuse-leap" -- "${cur}") )
            return 0
        fi

        # Complete flags after build subcommand
        if [[ "${COMP_WORDS[2]}" == "build" ]]; then
            COMPREPLY=( $(compgen -W "-d --distro -v --version -h --help" -- "${cur}") )
            return 0
        fi

        # Complete flags after cleanup subcommand
        if [[ "${COMP_WORDS[2]}" == "cleanup" ]]; then
            COMPREPLY=( $(compgen -W "-d --distro -v --version -f --force -h --help" -- "${cur}") )
            return 0
        fi
    fi
    
    # If the first argument is "destroy", complete flags
    if [[ "${COMP_WORDS[1]}" == "destroy" ]]; then
        if [[ ${cur} == -* ]]; then
            COMPREPLY=( $(compgen -W "--wipe-iso-files-too -h --help" -- "${cur}") )
            return 0
        fi
    fi

    # If the first argument is "rebuild", complete flags
    if [[ "${COMP_WORDS[1]}" == "rebuild" ]]; then
        if [[ ${cur} == -* ]]; then
            COMPREPLY=( $(compgen -W "--clean-state -h --help" -- "${cur}") )
            return 0
        fi
    fi

    # Complete flags for other commands
    if [[ ${cur} == -* ]]; then
        COMPREPLY=( $(compgen -W "-h --help" -- "${cur}") )
        return 0
    fi
    
    return 0
}

# Register completion function
complete -F _tux2lab_completions tux2lab
