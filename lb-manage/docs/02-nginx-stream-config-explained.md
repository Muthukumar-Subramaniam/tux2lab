# Nginx Stream Config — How It Works

## Background: nginx stream module

nginx has two main proxy modes:
- `http { }` — Layer 7, inspects HTTP headers (what you normally see in nginx configs)
- `stream { }` — Layer 4, proxies raw TCP/UDP bytes (what we use for load balancing)

The `stream` block lives at the **top level** of nginx.conf (same level as `http`),
NOT inside the `http` block.

---

## nginx.conf Structure (after LB setup)

```nginx
# /etc/nginx/nginx.conf (relevant sections only)

# Load the stream module (required on RHEL/Fedora/Azure Linux)
load_module /usr/lib64/nginx/modules/ngx_stream_module.so;

# ... existing worker/events config ...

# Existing HTTP block (serves PXE/kickstart content — untouched)
http {
    include /etc/nginx/conf.d/*.conf;
    # ... tux2lab web serving config ...
}

# NEW: Stream block for TCP load balancers
# Each .conf file in stream.d/ defines one load balancer
stream {
    include /etc/nginx/stream.d/*.conf;
}
```

**Important:** There can only be ONE `stream { }` block in the entire nginx config.
Individual LB configs go inside `/etc/nginx/stream.d/` and are included into it.

---

## Sample LB Config: Kubernetes API Server HA

Created by: `tux2lab lb create --name k8s-api --port 6443 --target-port 6443 --backends k8s-cp1,k8s-cp2,k8s-cp3 --algorithm least-conn`

```nginx
# /etc/nginx/stream.d/k8s-api.conf
# Managed by tux2lab lbmanager — do not edit manually

log_format k8s_api_log '$remote_addr [$time_local] '
                       '$protocol $status $bytes_sent bytes_sent '
                       'to: $upstream_addr';

upstream k8s_api_upstream {
    least_conn;

    server k8s-cp1.user.internal:6443 max_fails=3 fail_timeout=30s;
    server k8s-cp2.user.internal:6443 max_fails=3 fail_timeout=30s;
    server k8s-cp3.user.internal:6443 max_fails=3 fail_timeout=30s;
}

server {
    listen 10.28.28.5:6443;
    listen [fd28:2808:2020:3000::5]:6443;

    proxy_pass k8s_api_upstream;
    proxy_timeout 10m;
    proxy_connect_timeout 5s;

    access_log /var/log/nginx/k8s-api_access.log k8s_api_log;
    error_log  /var/log/nginx/k8s-api_error.log info;
}
```

---

## Sample LB Config: PostgreSQL Cluster

Created by: `tux2lab lb create --name pg-primary --port 5432 --target-port 5432 --backends pg1,pg2,pg3 --algorithm round-robin`

```nginx
# /etc/nginx/stream.d/pg-primary.conf
# Managed by tux2lab lbmanager — do not edit manually

log_format pg_primary_log '$remote_addr [$time_local] '
                          '$protocol $status $bytes_sent bytes_sent '
                          'to: $upstream_addr';

upstream pg_primary_upstream {
    # round-robin is the default — no directive needed

    server pg1.user.internal:5432 max_fails=3 fail_timeout=30s;
    server pg2.user.internal:5432 max_fails=3 fail_timeout=30s;
    server pg3.user.internal:5432 max_fails=3 fail_timeout=30s;
}

server {
    listen 10.28.28.6:5432;
    listen [fd28:2808:2020:3000::6]:5432;

    proxy_pass pg_primary_upstream;
    proxy_timeout 10m;
    proxy_connect_timeout 5s;

    access_log /var/log/nginx/pg-primary_access.log pg_primary_log;
    error_log  /var/log/nginx/pg-primary_error.log info;
}
```

---

## Sample LB Config: K8s NodePort Service (different listen vs target port)

Created by: `tux2lab lb create --name my-webapp --port 443 --target-port 30443 --backends k8s-w1,k8s-w2,k8s-w3`

```nginx
# /etc/nginx/stream.d/my-webapp.conf
# Managed by tux2lab lbmanager — do not edit manually

log_format my_webapp_log '$remote_addr [$time_local] '
                         '$protocol $status $bytes_sent bytes_sent '
                         'to: $upstream_addr';

upstream my_webapp_upstream {
    server k8s-w1.user.internal:30443 max_fails=3 fail_timeout=30s;
    server k8s-w2.user.internal:30443 max_fails=3 fail_timeout=30s;
    server k8s-w3.user.internal:30443 max_fails=3 fail_timeout=30s;
}

server {
    listen 10.28.28.7:443;
    listen [fd28:2808:2020:3000::7]:443;

    proxy_pass my_webapp_upstream;
    proxy_timeout 10m;
    proxy_connect_timeout 5s;

    access_log /var/log/nginx/my-webapp_access.log my_webapp_log;
    error_log  /var/log/nginx/my-webapp_error.log info;
}
```

---

## Algorithm Directives

| CLI Flag | nginx Directive | Behavior |
|----------|----------------|----------|
| `--algorithm round-robin` | *(none — it's the default)* | Rotate through backends equally |
| `--algorithm least-conn` | `least_conn;` | Send to backend with fewest active connections |
| `--algorithm ip-hash` | `hash $remote_addr consistent;` | Same client IP always goes to same backend (sticky) |

---

## Key Config Details

| Directive | Purpose | Our Value |
|-----------|---------|-----------|
| `max_fails=3` | Mark backend as down after 3 failed connections | Reasonable for lab |
| `fail_timeout=30s` | Time window for max_fails AND how long to wait before retrying | 30 seconds |
| `proxy_timeout 10m` | Idle timeout for established connections | 10 minutes (good for DB, K8s API) |
| `proxy_connect_timeout 5s` | How long to wait for backend TCP handshake | 5 seconds |
| `listen <ip>:<port>` | Bind to specific IP (not 0.0.0.0) | LB's dedicated secondary IP |

---

## What Happens When a Backend Goes Down?

```
Client → connects to k8s-api.user.internal:6443
       → resolves to 10.28.28.5
       → nginx receives on 10.28.28.5:6443
       → tries k8s-cp1:6443 — CONNECTION REFUSED (node is down)
       → marks k8s-cp1 as failed (fail count: 1)
       → retries on k8s-cp2:6443 — SUCCESS
       → proxies traffic to k8s-cp2

After 3 failures within 30s:
       → k8s-cp1 marked "unavailable" for 30 seconds
       → all new connections go to k8s-cp2 and k8s-cp3
       → after 30s, nginx retries k8s-cp1 again
```

This is automatic — no manual intervention needed. nginx handles failover natively.
