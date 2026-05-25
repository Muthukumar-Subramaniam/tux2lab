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
    local cur prev
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
    local golden_image_subcommands="build create list cleanup"

    # IPv6 route subcommands
    local ipv6_route_subcommands="enable disable check auto status"

    # Distro names
    local all_distros="almalinux rocky oraclelinux centos-stream rhel ubuntu-lts opensuse-leap"
    local rhel_distros="almalinux rocky oraclelinux centos-stream rhel"

    # DNS options
    local dns_options="-c --create -d --delete -dy -r --rename -ry -cf --create-from-file -cfy -cif --create-with-ip-file -cify -df --delete-from-file -dfy -ci --create-with-ip -cc --create-cname -dc --delete-cname -dcy --setup -y --yes -h --help"

    # ===== FIRST ARGUMENT (top-level command) =====
    if [[ ${COMP_CWORD} -eq 1 ]]; then
        if [[ ${cur} == -* ]]; then
            COMPREPLY=( $(compgen -W "${options}" -- "${cur}") )
        else
            COMPREPLY=( $(compgen -W "${commands}" -- "${cur}") )
        fi
        return 0
    fi

    local cmd="${COMP_WORDS[1]}"

    # ===== VM COMMAND =====
    if [[ "${cmd}" == "vm" ]]; then
        # Complete vm subcommand at position 2
        if [[ ${COMP_CWORD} -eq 2 ]]; then
            if [[ ${cur} == -* ]]; then
                COMPREPLY=( $(compgen -W "-h --help -v --version" -- "${cur}") )
            else
                COMPREPLY=( $(compgen -W "${vm_subcommands}" -- "${cur}") )
            fi
            return 0
        fi

        local vm_subcmd="${COMP_WORDS[2]}"

        # Complete distro names after -d/--distro
        if [[ "${prev}" == "-d" || "${prev}" == "--distro" ]]; then
            case "${vm_subcmd}" in
                install-golden|install-pxe|reimage-golden|reimage-pxe)
                    COMPREPLY=( $(compgen -W "${all_distros}" -- "${cur}") )
                    return 0
                    ;;
            esac
        fi

        # Complete options per vm subcommand
        if [[ ${cur} == -* ]]; then
            case "${vm_subcmd}" in
                install-golden|install-pxe)
                    COMPREPLY=( $(compgen -W "-H --hosts -c --console -d --distro -v --version -h --help" -- "${cur}") )
                    ;;
                reimage-golden|reimage-pxe)
                    COMPREPLY=( $(compgen -W "-H --hosts -c --console -C --clean-install -d --distro -v --version -f --force -h --help" -- "${cur}") )
                    ;;
                start)
                    COMPREPLY=( $(compgen -W "-H --hosts -h --help" -- "${cur}") )
                    ;;
                stop|shutdown|restart|reboot)
                    COMPREPLY=( $(compgen -W "-H --hosts -f --force -h --help" -- "${cur}") )
                    ;;
                remove)
                    COMPREPLY=( $(compgen -W "-H --hosts -f --force --ignore-ksmanager-cleanup -h --help" -- "${cur}") )
                    ;;
                list)
                    COMPREPLY=( $(compgen -W "-h --help" -- "${cur}") )
                    ;;
                info|validate)
                    COMPREPLY=( $(compgen -W "-H --hosts -h --help" -- "${cur}") )
                    ;;
                console)
                    COMPREPLY=( $(compgen -W "-H --host -h --help" -- "${cur}") )
                    ;;
                resize)
                    COMPREPLY=( $(compgen -W "-H --host -f --force -h --help" -- "${cur}") )
                    ;;
                disk-add)
                    COMPREPLY=( $(compgen -W "-H --host -f --force -n --count -s --size -h --help" -- "${cur}") )
                    ;;
                disk-resize)
                    COMPREPLY=( $(compgen -W "-H --host -f --force -d --disk -g --gib -h --help" -- "${cur}") )
                    ;;
                disk-attach)
                    COMPREPLY=( $(compgen -W "-H --host -f --force -d --disks -h --help" -- "${cur}") )
                    ;;
                disk-detach)
                    COMPREPLY=( $(compgen -W "-H --host -f --force -d --disks -h --help" -- "${cur}") )
                    ;;
                disk-delete)
                    COMPREPLY=( $(compgen -W "-d --disks -h --help" -- "${cur}") )
                    ;;
                nic-add)
                    COMPREPLY=( $(compgen -W "-H --host -f --force -c --count -n --network -h --help" -- "${cur}") )
                    ;;
                nic-remove)
                    COMPREPLY=( $(compgen -W "-H --host -f --force -m --macs -h --help" -- "${cur}") )
                    ;;
                snapshot-create)
                    COMPREPLY=( $(compgen -W "-H --hosts -l --label -d --desc -f --force -h --help" -- "${cur}") )
                    ;;
                snapshot-list)
                    COMPREPLY=( $(compgen -W "-H --hosts -h --help" -- "${cur}") )
                    ;;
                snapshot-info)
                    COMPREPLY=( $(compgen -W "-H --hosts -n --name -h --help" -- "${cur}") )
                    ;;
                snapshot-delete)
                    COMPREPLY=( $(compgen -W "-H --hosts -n --name -f --force -h --help" -- "${cur}") )
                    ;;
                snapshot-revert)
                    COMPREPLY=( $(compgen -W "-H --hosts -n --name -f --force -h --help" -- "${cur}") )
                    ;;
                *)
                    COMPREPLY=( $(compgen -W "-h --help" -- "${cur}") )
                    ;;
            esac
            return 0
        fi

        # Complete positional keywords for resize
        if [[ "${vm_subcmd}" == "resize" ]]; then
            COMPREPLY=( $(compgen -W "memory cpu disk" -- "${cur}") )
            return 0
        fi

        return 0
    fi

    # ===== DISTRO COMMAND =====
    if [[ "${cmd}" == "distro" ]]; then
        if [[ ${COMP_CWORD} -eq 2 ]]; then
            if [[ ${cur} == -* ]]; then
                COMPREPLY=( $(compgen -W "-h --help" -- "${cur}") )
            else
                COMPREPLY=( $(compgen -W "${distro_subcommands}" -- "${cur}") )
            fi
            return 0
        fi

        local distro_subcmd="${COMP_WORDS[2]}"

        # Complete distro names after setup/cleanup subcommand
        if [[ ${COMP_CWORD} -eq 3 ]] && [[ "${distro_subcmd}" == "setup" || "${distro_subcmd}" == "cleanup" ]]; then
            if [[ ${cur} == -* ]]; then
                COMPREPLY=( $(compgen -W "-v --version -h --help" -- "${cur}") )
            else
                COMPREPLY=( $(compgen -W "${all_distros}" -- "${cur}") )
            fi
            return 0
        fi

        # Complete RHEL-based distro names after download-infra-iso
        if [[ ${COMP_CWORD} -eq 3 ]] && [[ "${distro_subcmd}" == "download-infra-iso" ]]; then
            if [[ ${cur} == -* ]]; then
                COMPREPLY=( $(compgen -W "-h --help" -- "${cur}") )
            else
                COMPREPLY=( $(compgen -W "${rhel_distros}" -- "${cur}") )
            fi
            return 0
        fi

        # Complete --version/-v flag after distro name for setup/cleanup
        if [[ "${distro_subcmd}" == "setup" || "${distro_subcmd}" == "cleanup" ]]; then
            if [[ ${cur} == -* ]]; then
                COMPREPLY=( $(compgen -W "-v --version -h --help" -- "${cur}") )
                return 0
            fi
        fi

        return 0
    fi

    # ===== IPV6-ROUTE COMMAND =====
    if [[ "${cmd}" == "ipv6-route" ]]; then
        if [[ ${COMP_CWORD} -eq 2 ]]; then
            if [[ ${cur} == -* ]]; then
                COMPREPLY=( $(compgen -W "-h --help" -- "${cur}") )
            else
                COMPREPLY=( $(compgen -W "${ipv6_route_subcommands}" -- "${cur}") )
            fi
            return 0
        fi
        return 0
    fi

    # ===== GOLDEN-IMAGE COMMAND =====
    if [[ "${cmd}" == "golden-image" ]]; then
        if [[ ${COMP_CWORD} -eq 2 ]]; then
            if [[ ${cur} == -* ]]; then
                COMPREPLY=( $(compgen -W "-h --help" -- "${cur}") )
            else
                COMPREPLY=( $(compgen -W "${golden_image_subcommands}" -- "${cur}") )
            fi
            return 0
        fi

        local gi_subcmd="${COMP_WORDS[2]}"

        # Complete distro names after -d/--distro flag for build/cleanup
        if [[ "${gi_subcmd}" == "build" || "${gi_subcmd}" == "create" || "${gi_subcmd}" == "cleanup" ]] && [[ "${prev}" == "-d" || "${prev}" == "--distro" ]]; then
            COMPREPLY=( $(compgen -W "${all_distros}" -- "${cur}") )
            return 0
        fi

        # Complete flags after build/create subcommand
        if [[ "${gi_subcmd}" == "build" || "${gi_subcmd}" == "create" ]]; then
            if [[ ${cur} == -* ]]; then
                COMPREPLY=( $(compgen -W "-d --distro -v --version -h --help" -- "${cur}") )
                return 0
            fi
        fi

        # Complete flags after cleanup subcommand
        if [[ "${gi_subcmd}" == "cleanup" ]]; then
            if [[ ${cur} == -* ]]; then
                COMPREPLY=( $(compgen -W "-d --distro -v --version -f --force -h --help" -- "${cur}") )
                return 0
            fi
        fi

        # Complete flags after list subcommand
        if [[ "${gi_subcmd}" == "list" ]]; then
            if [[ ${cur} == -* ]]; then
                COMPREPLY=( $(compgen -W "-h --help" -- "${cur}") )
                return 0
            fi
        fi

        return 0
    fi

    # ===== DNS COMMAND =====
    if [[ "${cmd}" == "dns" ]]; then
        # DNS accepts its option as the first argument (position 2)
        if [[ ${COMP_CWORD} -eq 2 ]]; then
            COMPREPLY=( $(compgen -W "${dns_options}" -- "${cur}") )
            return 0
        fi

        # After a file-based operation, complete file paths
        local dns_opt="${COMP_WORDS[2]}"
        case "${dns_opt}" in
            -cf|--create-from-file|-cfy|-cif|--create-with-ip-file|-cify|-df|--delete-from-file|-dfy)
                if [[ ${COMP_CWORD} -eq 3 ]]; then
                    compopt -o default
                    COMPREPLY=()
                    return 0
                fi
                ;;
        esac

        # After the main option + argument, offer --yes
        if [[ ${cur} == -* ]]; then
            COMPREPLY=( $(compgen -W "-y --yes" -- "${cur}") )
            return 0
        fi

        return 0
    fi

    # ===== DESTROY COMMAND =====
    if [[ "${cmd}" == "destroy" ]]; then
        if [[ ${cur} == -* ]]; then
            COMPREPLY=( $(compgen -W "--wipe-iso-files-too -h --help" -- "${cur}") )
        else
            COMPREPLY=( $(compgen -W "--wipe-iso-files-too" -- "${cur}") )
        fi
        return 0
    fi

    # ===== REBUILD COMMAND =====
    if [[ "${cmd}" == "rebuild" ]]; then
        if [[ ${cur} == -* ]]; then
            COMPREPLY=( $(compgen -W "--clean-state -h --help" -- "${cur}") )
        else
            COMPREPLY=( $(compgen -W "--clean-state" -- "${cur}") )
        fi
        return 0
    fi

    # ===== SIMPLE COMMANDS (start, stop, enable, disable, health, deploy) =====
    if [[ "${cmd}" == "start" || "${cmd}" == "stop" || "${cmd}" == "enable" || "${cmd}" == "disable" || "${cmd}" == "health" || "${cmd}" == "deploy" ]]; then
        if [[ ${cur} == -* ]]; then
            COMPREPLY=( $(compgen -W "-h --help" -- "${cur}") )
            return 0
        fi
        return 0
    fi

    return 0
}

# Register completion function
complete -F _tux2lab_completions tux2lab
