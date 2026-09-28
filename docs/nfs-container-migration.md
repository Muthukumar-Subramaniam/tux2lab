# Container NFS Migration

## Status

Development implementation on `migration/nfs-host-to-container`, branched from
`main` at `0d0c7dc01395a484a98f2ef3a72f6aea0b465bf9`. The original experiment
scripts and results are backed up on origin in commit
`a3cf462a6445780c0024ec741ce22c88b160eef1`.

The live lab still uses its released engine and host NFS. Implementation and
isolated tests do not authorize a live handover, host package removal or a merge
to main. This is not yet a release-ready replacement for host NFS.

## Maintained Code

| Owner | Responsibility |
| --- | --- |
| [container/nfs-service.sh](../container/nfs-service.sh) | Daemon supervision, readiness, persistent state, export registration and cleanup |
| [container/entrypoint.sh](../container/entrypoint.sh) | Engine-wide failure supervision and shutdown trap |
| [shared-functions/nfs-config.sh](../shared-functions/nfs-config.sh) | Export, daemon and firewall configuration |
| [shared-functions/container-nfs.sh](../shared-functions/container-nfs.sh) | Host preflight, image compatibility, readiness and shutdown verification |
| [shared-functions/run-container.sh](../shared-functions/run-container.sh) | Mount layout, launch and replacement with retained previous engine |
| [setup/migrate-nfs-to-container.sh](../setup/migrate-nfs-to-container.sh) | Explicit host-service handover and rollback |
| [container/run-nfs-tests.sh](../container/run-nfs-tests.sh) | Rootless regression tests and isolated integration tests |

Deployment, start, stop, rebuild, destroy, health and busy-ISO cache flushing use
the container owner. Legacy engines are rejected before replacement or teardown.
The old host helper is retained only as migration reference; normal lifecycle
commands no longer invoke it. Host NFS packages remain installed for rollback and
pending kernel-helper dependency testing.

The [September 17](experiments/kernel-nfs-container-2026-09-17/README.md) and
[September 24](experiments/kernel-nfs-container-2026-09-24/README.md) directories
are immutable experiment evidence, not alternate maintained implementations.
Their host-specific replay tools cover historical cold-start and PXE experiments
that have not yet been replaced by acceptance tests of the integrated engine.
Do not use those wrappers for deployment or mix them with the migration command.

## Design

- The host still supplies the kernel, NFS modules, ISO mounts and bridge.
- Host networking means there can be only one kernel NFS owner in that network
  namespace. Active host daemons, RPC listeners and existing kernel exports cause
  startup to fail instead of being overwritten.
- An exportable filesystem is bound at `/export` as the NFSv4 `fsid=0` root.
  The data tree is mounted at `/export/tux2lab-data` with recursive slave mount
  propagation. A `/tux2lab-data` symlink preserves existing engine paths and
  NFSv3 mount requests. NFSv4 clients continue using `:/tux2lab-data`.
- Exports are read-only and restricted to the configured numeric IPv4/IPv6
  subnets. Existing `no_root_squash` semantics are retained: this is a trusted lab
  export, not an authorization boundary for hostile lab clients.
- NFSv3 remains enabled for Ubuntu's actual initramfs mount helper. The earlier
  Ubuntu 24.04 test required v3 despite the v4 boot argument.
- NFS state lives in `/tux2lab-data/nfs/state`, mounted at `/var/lib/nfs`.
  `nfsdcld` runs in the engine. Persistent directories and successful restart are
  not proof of active-client state reclaim. Statd, writable storage and NLM lock
  recovery are not supported acceptance claims for this read-only installer use.
- A dedicated `inet tux2lab_nfs` nftables table drops reserved RPC ports on
  interfaces other than the lab bridge and loopback. NFS binds to the configured
  bridge addresses; ancillary RPC listeners may still show wildcard bindings.
  Fixed lockd ports are host-wide settings, so host NFS client mounts are rejected.
- Other firewall policy still applies. The guard does not override a host DROP
  policy. Monitoring compares the current stateless nftables JSON with the
  installed ruleset and stops the engine if the table or its protection changes.
- Shutdown stops kernel threads before removing exports, daemons, control mounts
  and firewall rules. If shutdown cannot be verified, lifecycle commands retain
  network/filesystem state and fail instead of continuing ISO teardown.

Reserved ports: TCP `111,2049,20048,32803,32765`; UDP
`111,2049,20048,32769,32765,32766`. Statd ports are reserved for future recovery
work; reservation does not imply that statd runs or that locking is validated.

## Build and Test

From `/tux2lab`:

```bash
sudo podman build --network=host -t localhost/tux2lab-engine:nfs-migration \
  -f container/Containerfile .
bash container/run-nfs-tests.sh
bash container/run-nfs-tests.sh --firewall localhost/tux2lab-engine:nfs-migration
bash container/run-nfs-tests.sh --service localhost/tux2lab-engine:nfs-migration
```

The default suite needs Bash only and uses temporary files and command mocks.
The two integration modes need rootful Podman, the built image and host kernel
support. They create disposable private network namespaces, never share the
host network, and never stop host services. The service test uses dedicated
scratch directories on `/tux2lab-data` and deliberately skips host-wide lockd
sysctl writes. It does not prove fixed lockd port allocation on the production
network namespace. These tests do not start the full engine or install guests.

Verified in this implementation checkpoint:

- Numeric client configuration, image rejection, active-server rejection,
  failed-replacement recovery and guarded host rollback (rootless mocks).
- Actual IPv4/IPv6 TCP/UDP access to each reserved port: bridge and loopback
  accepted, outside interface blocked (isolated namespace).
- NFSv4 IPv4/IPv6 and NFSv3 IPv4 original-path reads and server-side write
  rejection, restart with persistent state, mountd failure detection, and listener
  cleanup (isolated kernel NFS server).
- Local image build, Bash syntax and ShellCheck of new implementation code.
  Existing surrounding scripts still have baseline ShellCheck diagnostics;
  indirect-call analysis produces informational diagnostics for test mocks and
  EXIT traps. The mock test suite is checked at warning severity.

## September 28 Review

The first hardening pass corrected five unsafe inspection paths:

- Shutdown reads the protected kernel thread count with privilege and rejects
  failed or invalid reads instead of silently skipping them.
- Container lookup distinguishes a genuinely missing container from a Podman
  inspection failure. Stop, replacement and rollback abort on inspection errors.
- Existing kernel exports are read and validated directly. Their `/proc` file
  reports zero size even when it contains data, so a file-size test is unsafe.
- Firewall readiness verifies the installed rules, not just table existence.
  Removing the input rules while retaining the table now fails readiness.
- Host preflight requires successful systemd and mount-table inspection. Active
  or transitional units and unknown state are rejected before module loading.
  Failed service units are accepted only with a verified zero main PID.

Rootless regressions cover each path. The isolated NFS protocol, read-only,
restart and mountd-failure checks passed again, as did the dual-stack packet
tests and the new real firewall-rule-removal check. Touched production scripts
pass ShellCheck; the dynamically mocked suite passes at warning severity.

This completes the first review pass, not live acceptance. Actual fixed lockd
port allocation under host networking is still unverified: the isolated service
test deliberately skips those host-wide sysctl writes. The next stage is the
complete-engine and ISO-propagation test plan. No host handover or registry image
publication was performed for this review.

## Planned Handover

Do not execute this section until an integrated acceptance window is authorized.
Use a dedicated lab host with no unrelated NFS exports or clients. Shut down
guests and finish installer sessions first. Stop any external NFS clients too;
the preflight cannot discover every UDP client. Do not run other lab lifecycle
commands concurrently. The migration lock serializes migration commands only.

```bash
sudo bash setup/migrate-nfs-to-container.sh --check localhost/tux2lab-engine:nfs-migration
sudo bash setup/migrate-nfs-to-container.sh --apply localhost/tux2lab-engine:nfs-migration
```

The command keeps the original container as `tux2lab-engine-host-nfs-backup`,
records host unit states, exports and lockd settings under
`/var/lib/tux2lab/nfs-migration`, and masks discovered host NFS/RPC services and
the rpcbind socket. Host package files and NFS configuration remain untouched.
It creates only container-specific NFS config files, not unrelated service config.
Failure attempts rollback; a cleanup failure instead retains the checkpoint for
inspection and refuses to start a second owner.

An image must carry `io.tux2lab.nfs=container-v1`. Released v2.1.1 is rejected.
For subsequent rebuilds, select the development image explicitly:

```bash
TUX2LAB_ENGINE_IMAGE=localhost/tux2lab-engine:nfs-migration tux2lab rebuild
```

Keep the backup container and migration checkpoint through acceptance. Destroy
refuses to proceed while the migration backup exists. Do not prune all images
while rollback may still be needed. Do not uninstall
host NFS utilities. Fresh-host deployment and host service policy still need a
separate acceptance pass; the migration command expects an existing host export.

## Rollback and Failures

With clients quiesced and no other lifecycle command running:

```bash
sudo bash setup/migrate-nfs-to-container.sh --rollback
```

Rollback first stops and verifies container NFS, restores the retained engine,
unmasks only recorded units, restores lockd settings, starts originally active
units, reloads exports and checks the recorded export set and unit enable states.
Successful rollback archives its checkpoint with a timestamp. Return to `main`
for legacy host-backed lifecycle commands afterward. Do not blindly overwrite
host configuration changed since migration; reconcile those changes first.

A SIGKILL of engine PID 1, host crash or failed kernel shutdown may bypass cleanup
and leave kernel listeners. Do not force-delete the engine or unmount ISOs to
hide that state. Inspect the retained engine, logs, kernel threads and listeners;
recover ownership in a dedicated maintenance window before retrying. Automated
recovery from this failure class is not established by the mountd-child test.

## Remaining Acceptance Gates

1. Full integrated engine handover and rollback with all DNS/DHCP/HTTP/TFTP/NTP/RA
   services, actual propagated ISO mounts, and the unchanged 2 GiB Alma/Ubuntu
   PXE workflows. Historical experiments used a standalone server.
2. Actual fixed lockd port allocation and RPC listener audit under host networking,
   including host firewall reloads and IPv4-only configurations.
3. Repeated container recreation, durable handles, active-client reclaim, abrupt
   PID 1 failure, reboot and interrupted migration recovery.
4. Host executable/upcall dependency audit before removing any host NFS packages.
5. Representative host filesystems/distributions and supported guest versions.
   Read-only installation success does not establish writable shared storage.

Push tested checkpoints to `origin/migration/nfs-host-to-container` and verify the
remote tip. Runtime data, VM disks, generated credentials and local image binaries
are not part of a Git backup.