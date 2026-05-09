#!/usr/bin/env bash
#----------------------------------------------------------------------------------------#
# If you encounter any issues with this script, or have suggestions or feature requests, #
# please open an issue at: https://github.com/Muthukumar-Subramaniam/tux2lab/issues   #
#----------------------------------------------------------------------------------------#
# Script Name : qlabvmctl-completion.bash
# Description : Bash completion script for qlabvmctl.sh
# Installation: Source this file in your ~/.bashrc or copy to /etc/bash_completion.d/
# Usage       : source qlabvmctl-completion.bash

_qlabvmctl_completions() {
    local cur prev subcommands
    COMPREPLY=()
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD-1]}"
    
    # All available subcommands
    subcommands="build-golden-image install-golden install-pxe reimage-golden reimage-pxe start stop shutdown restart reboot remove list info console resize disk-add disk-resize disk-attach disk-detach disk-delete nic-add nic-remove ipv6-route version"
    
    # Top-level options
    local options="-h --help -v --version"
    
    # If we're completing the first argument (subcommand)
    if [[ ${COMP_CWORD} -eq 1 ]]; then
        if [[ ${cur} == -* ]]; then
            # Complete options
            COMPREPLY=( $(compgen -W "${options}" -- "${cur}") )
        else
            # Complete subcommands
            COMPREPLY=( $(compgen -W "${subcommands}" -- "${cur}") )
        fi
        return 0
    fi
    
    # If we're completing flags after a subcommand
    if [[ ${cur} == -* ]]; then
        COMPREPLY=( $(compgen -W "-h --help" -- "${cur}") )
        return 0
    fi
    
    return 0
}

# Register completion function for both qlabvmctl.sh and qlabvmctl (in case symlink exists)
complete -F _qlabvmctl_completions qlabvmctl.sh
complete -F _qlabvmctl_completions qlabvmctl
