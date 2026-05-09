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
    local commands="vm start health dns version"
    
    # Top-level options
    local options="-h --help -v --version"
    
    # VM subcommands
    local vm_subcommands="build-golden-image install-golden install-pxe reimage-golden reimage-pxe start stop shutdown restart reboot remove list info console resize disk-add disk-resize disk-attach disk-detach disk-delete nic-add nic-remove ipv6-route"
    
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
    
    # Complete flags for other commands
    if [[ ${cur} == -* ]]; then
        COMPREPLY=( $(compgen -W "-h --help" -- "${cur}") )
        return 0
    fi
    
    return 0
}

# Register completion function
complete -F _tux2lab_completions tux2lab
