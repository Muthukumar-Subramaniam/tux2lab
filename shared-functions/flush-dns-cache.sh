#!/usr/bin/env bash
# Flush the host DNS resolver cache. Non-fatal if unavailable.

flush_dns_cache() {
    print_task "Flushing DNS cache..."
    if command -v resolvectl &>/dev/null; then
        if resolvectl flush-caches 2>/dev/null; then
            print_task_done
        else
            print_task_fail
            print_warning "Failed to flush DNS cache."
        fi
    else
        print_task_fail
        print_warning "resolvectl not found — DNS cache not flushed."
    fi
}
