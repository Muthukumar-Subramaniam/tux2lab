# Implementation Plan — Build Order & File Map

## Build Order (for the marathon session)

```
Phase 1 ──► Phase 2 ──► Phase 3 ──► Phase 4 ──► Phase 5
  │            │            │            │            │
  ▼            ▼            ▼            ▼            ▼
lbmanager.sh  systemd     lb.sh       tux2lab.sh   configure
(core logic)  service    (wrapper)    (dispatch)   (bootstrap)
```

---

## Phase 1: Core Manager — `lb-manage/lbmanager.sh`
*This is 80% of the work. Everything else is wiring.*

### Internal Functions to Implement:

```
lbmanager.sh
├── fn_show_help()              — Usage text
├── fn_acquire_lock()           — mkdir-based lock + PID file + trap
├── fn_release_lock()           — Remove lock dir
├── fn_validate_name()          — Lowercase alnum + hyphen, no leading/trailing hyphen
├── fn_validate_port()          — Integer 1-65535
├── fn_validate_backends()      — Comma-split, each resolves via getent
├── fn_validate_algorithm()     — Must be: round-robin, least-conn, ip-hash
│
├── fn_read_registry()          — Cat + jq parse lb-registry.json
├── fn_get_lb()                 — Query single LB by name from registry
├── fn_lb_exists()              — Boolean check
├── fn_add_lb_to_registry()     — jq append to .load_balancers[]
├── fn_remove_lb_from_registry()— jq delete from .load_balancers[]
├── fn_update_lb_in_registry()  — jq update specific LB entry
│
├── fn_create_dns_record()      — Call dnsbinder to create A/AAAA
├── fn_delete_dns_record()      — Call dnsbinder to delete record
├── fn_resolve_ip()             — getent hosts → extract IPv4 and IPv6
│
├── fn_add_secondary_ip()       — ip addr add (idempotent — check first)
├── fn_remove_secondary_ip()    — ip addr del
├── fn_check_ip_on_interface()  — ip addr show | grep
│
├── fn_generate_nginx_config()  — Write /etc/nginx/stream.d/<name>.conf
├── fn_remove_nginx_config()    — rm config file
├── fn_validate_nginx()         — nginx -t
├── fn_reload_nginx()           — systemctl reload nginx
├── fn_check_port_conflict()    — ss -tlnp | grep <ip>:<port>
│
├── fn_create()                 — Orchestrates full create flow
├── fn_delete()                 — Orchestrates full delete flow
├── fn_update()                 — Orchestrates update flow
├── fn_list()                   — Table output
├── fn_status()                 — Health checks per LB
├── fn_restore()                — Boot-time IP restoration
├── fn_interactive_menu()       — Numbered menu TUI
│
└── main()                      — Arg parsing + subcommand dispatch
```

### Argument Parsing Pattern:

```bash
# Subcommand dispatch (bottom of script)
case "${1:-}" in
    create)  shift; fn_create "$@" ;;
    delete)  shift; fn_delete "$@" ;;
    update)  shift; fn_update "$@" ;;
    list)    shift; fn_list "$@" ;;
    status)  shift; fn_status "$@" ;;
    restore) shift; fn_restore "$@" ;;
    -h|--help) fn_show_help ;;
    "")      fn_interactive_menu ;;
    *)       print_error "Unknown command: $1"; fn_show_help; exit 1 ;;
esac
```

### Flag Parsing (within each subcommand function):

```bash
fn_create() {
    local name="" port="" target_port="" backends="" algorithm="round-robin" yes_flag=false
    local prev_arg=""

    for arg in "$@"; do
        case "$prev_arg" in
            --name)        name="$arg" ;;
            --port)        port="$arg" ;;
            --target-port) target_port="$arg" ;;
            --backends)    backends="$arg" ;;
            --algorithm)   algorithm="$arg" ;;
        esac
        prev_arg="$arg"
        [[ "$arg" == "-y" ]] && yes_flag=true
    done

    # Interactive prompts for missing fields
    [[ -z "$name" ]] && read -rp "Enter LB name: " name
    # ... etc
}
```

---

## Phase 2: Systemd Service — `lb-manage/tux2lab-lb.service`

```ini
[Unit]
Description=tux2lab Load Balancer IP Restore
After=network-online.target nginx.service
Wants=network-online.target
Requires=nginx.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/tux2lab/lb-manage/lbmanager.sh restore

[Install]
WantedBy=multi-user.target
```

---

## Phase 3: CLI Wrapper — `qemu-kvm-manage/scripts-to-manage-vms/lb.sh`

```
lb.sh
├── Source color-functions.sh + defaults.sh
├── Help text (if -h/--help)
├── Validate subcommand against whitelist
├── Check labbr0 is up
├── If host mode:
│     └── sudo /tux2lab/lb-manage/lbmanager.sh "$@"
└── If VM mode:
      ├── SSH connectivity check
      ├── Escape args: printf '%q ' "$@"
      └── ssh infra-server "sudo /tux2lab/lb-manage/lbmanager.sh ${escaped_args}"
```

---

## Phase 4: CLI Integration

### tux2lab.sh additions:
```bash
# In show_usage():
echo "  lb              Manage TCP load balancers"

# In case dispatch:
lb) "${SCRIPT_DIR}/lb.sh" "$@" ;;
```

### tux2lab-completion.bash additions:
```bash
# Top-level commands list:
commands="... dns lb deploy ..."

# lb subcommands:
lb) COMPREPLY=($(compgen -W "create delete update list status restore" -- "$cur")) ;;
```

---

## Phase 5: Bootstrap in configure-lab-infra-server.sh

```bash
# --- Load Balancer Prerequisites ---
print_task "Configuring load balancer prerequisites"

# Ensure stream.d directory exists
mkdir -p /etc/nginx/stream.d

# Add stream block to nginx.conf if not present
if ! grep -q 'stream.d' /etc/nginx/nginx.conf; then
    cat >> /etc/nginx/nginx.conf <<'EOF'

stream {
    include /etc/nginx/stream.d/*.conf;
}
EOF
fi

# Create LB state directory
mkdir -p /tux2lab-data/lb-hub

# Initialize empty registry if not exists
if [[ ! -f /tux2lab-data/lb-hub/lb-registry.json ]]; then
    echo '{"load_balancers":[]}' > /tux2lab-data/lb-hub/lb-registry.json
fi

# Install and enable systemd service
cp /tux2lab/lb-manage/tux2lab-lb.service /etc/systemd/system/
systemctl daemon-reload
systemctl enable tux2lab-lb.service

print_task_done
```

---

## File Tree (what we're building)

```
lb-manage/
├── lbmanager.sh              ← Core script (create/delete/update/list/status/restore)
├── tux2lab-lb.service        ← Systemd oneshot for boot persistence
└── docs/                     ← These explanation files (remove after session)
    ├── 01-architecture-overview.md
    ├── 02-nginx-stream-config-explained.md
    ├── 03-implementation-plan.md
    └── 04-sample-registry.json

qemu-kvm-manage/scripts-to-manage-vms/
├── lb.sh                     ← NEW: CLI wrapper
├── tux2lab.sh                ← MODIFIED: add lb dispatch
└── tux2lab-completion.bash   ← MODIFIED: add lb completions

configure-lab-infra-server/
└── configure-lab-infra-server.sh  ← MODIFIED: add LB bootstrap section
```

---

## Runtime File Tree (on infra server after deployment)

```
/tux2lab-data/
└── lb-hub/
    └── lb-registry.json        ← LB state (JSON)

/etc/nginx/
├── nginx.conf                  ← Contains: stream { include stream.d/*.conf; }
└── stream.d/
    ├── k8s-api.conf            ← One file per LB
    ├── pg-primary.conf
    └── my-webapp.conf

/etc/systemd/system/
└── tux2lab-lb.service          ← Runs "lbmanager.sh restore" on boot

/var/log/nginx/
├── k8s-api_access.log          ← Per-LB access logs
├── k8s-api_error.log
├── pg-primary_access.log
└── pg-primary_error.log
```
