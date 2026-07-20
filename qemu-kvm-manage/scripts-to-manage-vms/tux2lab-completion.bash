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

    # Ensure comma is a readline word boundary from the first invocation.
    # This allows clean display and correct insertion for comma-separated
    # host lists (-H/--hosts). Safe for other commands — aligns with the
    # bash-completion package default. Set once, idempotent thereafter.
    [[ "${COMP_WORDBREAKS}" != *,* ]] && COMP_WORDBREAKS="${COMP_WORDBREAKS},"

    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD-1]}"

    # Top-level commands
    local commands="vm golden-image distro ipv6-route deploy destroy rebuild sync start stop enable disable health info dns version"

    # Top-level options
    local options="-h --help -v --version"

    # VM subcommands
    local vm_subcommands="install reimage start stop shutdown restart reboot remove list info validate console resize disk-add disk-resize disk-attach disk-detach disk-delete nic-add nic-remove snapshot-create snapshot-list snapshot-info snapshot-delete snapshot-revert"

    # Distro subcommands
    local distro_subcommands="list setup cleanup"

    # Golden image subcommands
    local golden_image_subcommands="build create rebuild list cleanup"

    # IPv6 route subcommands
    local ipv6_route_subcommands="enable disable check auto status"

    # Distro names and versions (sourced from single source of truth)
    # Unset guard so re-sourcing works (declare -A is function-local, doesn't persist)
    unset _DISTRO_VERSIONS_CONF_LOADED
    source /tux2lab/ks-manage/distro-versions.conf 2>/dev/null || true
    local all_distros="${!DISTRO_AVAILABLE_VERSIONS[*]}"
    local rhel_distros="almalinux rocky oraclelinux centos-stream rhel"

    # Existing VM names (from filesystem — instant, no virsh overhead)
    local existing_vms
    existing_vms=$(ls /tux2lab-data/vms/ 2>/dev/null || true)

    # Helper: complete comma-separated hostnames with deduplication
    # Uses COMP_LINE for context detection (immune to COMP_WORDBREAKS changes)
    # Adds comma to COMP_WORDBREAKS so readline displays only hostnames
    # and replaces only the part after the last comma.
    _complete_comma_separated_hosts() {
        local cur_val="$1"
        local suffix="${cur_val}"
        local -a already_used=()

        if [[ "${cur_val}" == *,* ]]; then
            suffix="${cur_val##*,}"
            IFS=',' read -ra already_used <<< "${cur_val%,*}"
        fi

        # Build filtered list excluding already-used hostnames
        local available=""
        local vm used h
        for vm in ${existing_vms}; do
            used=false
            for h in "${already_used[@]}"; do
                if [[ "$vm" == "$h" ]]; then
                    used=true
                    break
                fi
            done
            $used || available+="$vm "
        done

        # Nothing available — all hosts consumed or no match
        if [[ -z "${available}" ]]; then
            COMPREPLY=()
            return
        fi

        # Return suffix-only matches — readline prepends prefix via COMP_WORDBREAKS
        COMPREPLY=( $(compgen -W "${available}" -- "${suffix}") )

        # Suppress trailing space — user may type comma for additional hosts
        [[ ${#COMPREPLY[@]} -gt 0 ]] && compopt -o nospace 2>/dev/null
    }

    # Helper: find distro from COMP_WORDS
    _find_distro_in_words() {
        for word in "${COMP_WORDS[@]}"; do
            for d in ${all_distros}; do
                [[ "$word" == "$d" ]] && echo "$d" && return
            done
        done
    }

    # DNS options
    local dns_options="-c --create -d --delete -dy -r --rename -ry -cf --create-from-file -cfy -cif --create-with-ip-file -cify -df --delete-from-file -dfy -ci --create-with-ip -cc --create-cname -dc --delete-cname -dcy -q --query --setup -y --yes --inline -h --help"

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

        # === COMP_LINE-BASED CONTEXT DETECTION ===
        # With comma in COMP_WORDBREAKS, COMP_WORDS splits at commas making
        # "prev" unreliable for comma-separated values. Use COMP_LINE (raw
        # command text) which is always immune to COMP_WORDBREAKS changes.
        local _comp_prefix="${COMP_LINE:0:COMP_POINT}"

        # Host completion: -H/--hosts/--host with comma-separated deduplication
        if [[ "$_comp_prefix" =~ (-H|--hosts|--host)[[:space:]]+([^[:space:]]*)$ ]]; then
            local _host_val="${BASH_REMATCH[2]}"
            case "${vm_subcmd}" in
                install) return 0 ;;
                *)
                    if [[ -n "$existing_vms" ]]; then
                        _complete_comma_separated_hosts "$_host_val"
                    fi
                    return 0
                    ;;
            esac
        fi

        # Suppress completion for comma-separated options that have no completable
        # values. Only match unambiguous long forms — short forms like -d and -m
        # are overloaded (-d = --distro in install/reimage, -m = --memory in resize)
        if [[ "$_comp_prefix" =~ (--disks|--macs)[[:space:]]+[^[:space:]]*$ ]]; then
            return 0
        fi

        # Complete distro names after -d/--distro
        if [[ "${prev}" == "-d" || "${prev}" == "--distro" ]]; then
            case "${vm_subcmd}" in
                install|reimage)
                    COMPREPLY=( $(compgen -W "${all_distros}" -- "${cur}") )
                    return 0
                    ;;
            esac
        fi

        # Complete version values after -v/--version
        if [[ "${prev}" == "-v" || "${prev}" == "--version" ]]; then
            case "${vm_subcmd}" in
                install|reimage)
                    local found_distro
                    found_distro=$(_find_distro_in_words)
                    if [[ -n "$found_distro" ]]; then
                        compopt -o nosort 2>/dev/null
                        COMPREPLY=( $(compgen -W "${DISTRO_AVAILABLE_VERSIONS[$found_distro]}" -- "${cur}") )
                    fi
                    return 0
                    ;;
            esac
        fi

        # After a non-boolean flag, suppress completion (it expects a user value).
        # Distro (-d/--distro) and version (-v/--version) for install/reimage are
        # already handled above with their own completion handlers.
        # -H/--hosts/--host is handled earlier via COMP_LINE detection.
        case "${prev}" in
            -f|--force|-C|--clean-install|--ignore-ksmanager-cleanup|-h|--help) ;;
            -c|--console)
                case "${vm_subcmd}" in
                    install|reimage) ;;
                    *) return 0 ;;
                esac
                ;;
            -*) return 0 ;;
        esac

        # Complete positional keywords and flags for resize
        if [[ "${vm_subcmd}" == "resize" ]]; then
            COMPREPLY=( $(compgen -W "-m --memory -c --cpu -d --disk -H --host -f --force -h --help" -- "${cur}") )
            return 0
        fi

        # Complete options per vm subcommand
        case "${vm_subcmd}" in
            install)
                COMPREPLY=( $(compgen -W "--via-golden --via-pxe -H --hosts -c --console -d --distro -v --version -h --help" -- "${cur}") )
                ;;
            reimage)
                COMPREPLY=( $(compgen -W "--via-golden --via-pxe -H --hosts -c --console -C --clean-install -d --distro -v --version -f --force -h --help" -- "${cur}") )
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
                COMPREPLY=( $(compgen -W "-m --memory -c --cpu -d --disk -H --host -f --force -h --help" -- "${cur}") )
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
                COMPREPLY=( $(compgen -W "-h --help" -- "${cur}") )
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
            # Offer versions after -v/--version
            if [[ "${prev}" == "-v" || "${prev}" == "--version" ]]; then
                local found_distro
                found_distro=$(_find_distro_in_words)
                if [[ -n "$found_distro" ]]; then
                    compopt -o nosort 2>/dev/null
                    COMPREPLY=( $(compgen -W "${DISTRO_AVAILABLE_VERSIONS[$found_distro]}" -- "${cur}") )
                fi
                return 0
            fi
            COMPREPLY=( $(compgen -W "-v --version -h --help" -- "${cur}") )
            return 0
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

        # Complete distro names as positional argument for build/cleanup/rebuild
        if [[ "${gi_subcmd}" == "build" || "${gi_subcmd}" == "create" || "${gi_subcmd}" == "cleanup" || "${gi_subcmd}" == "rebuild" ]]; then
            local gi_opts="-v --version -h --help"
            [[ "${gi_subcmd}" == "cleanup" ]] && gi_opts="-v --version -f --force -h --help"
            # Offer versions after -v/--version
            if [[ "${prev}" == "-v" || "${prev}" == "--version" ]]; then
                local found_distro
                found_distro=$(_find_distro_in_words)
                if [[ -n "$found_distro" ]]; then
                    compopt -o nosort 2>/dev/null
                    COMPREPLY=( $(compgen -W "${DISTRO_AVAILABLE_VERSIONS[$found_distro]}" -- "${cur}") )
                fi
                return 0
            fi
            # Offer distro names if one hasn't been provided yet
            local distro_given=false
            for word in "${COMP_WORDS[@]:3}"; do
                [[ "$word" == "$cur" ]] && continue
                for d in ${all_distros}; do
                    [[ "$word" == "$d" ]] && distro_given=true && break 2
                done
            done
            if ! $distro_given; then
                if [[ ${cur} == -* ]]; then
                    COMPREPLY=( $(compgen -W "-h --help" -- "${cur}") )
                else
                    COMPREPLY=( $(compgen -W "${all_distros}" -- "${cur}") )
                fi
            else
                COMPREPLY=( $(compgen -W "${gi_opts}" -- "${cur}") )
            fi
            return 0
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

        # After the main option + argument, offer --yes/--inline
        if [[ ${cur} == -* ]]; then
            COMPREPLY=( $(compgen -W "-y --yes --inline" -- "${cur}") )
            return 0
        fi

        return 0
    fi

    # ===== DESTROY COMMAND =====
    if [[ "${cmd}" == "destroy" ]]; then
        local all_opts="--wipe-iso-files-too -h --help"
        local opts=""
        for opt in $all_opts; do
            local already_used=false
            for i in $(seq 2 $((COMP_CWORD - 1))); do
                if [[ "${COMP_WORDS[i]}" == "$opt" ]]; then
                    already_used=true
                    break
                fi
            done
            $already_used || opts="$opts $opt"
        done
        COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
        return 0
    fi

    # ===== REBUILD COMMAND =====
    if [[ "${cmd}" == "rebuild" ]]; then
        local all_opts="--clean-state -h --help"
        local opts=""
        for opt in $all_opts; do
            local already_used=false
            for i in $(seq 2 $((COMP_CWORD - 1))); do
                if [[ "${COMP_WORDS[i]}" == "$opt" ]]; then
                    already_used=true
                    break
                fi
            done
            $already_used || opts="$opts $opt"
        done
        COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
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
