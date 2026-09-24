# Kernel NFS Container Experiment

Date: 2026-09-17. Repository baseline: `0d0c7dc01395a484a98f2ef3a72f6aea0b465bf9`.

Status: experiment complete, original host NFS restored and verified. This directory
archives the final test scripts and implementation handoff. It does not enable
container NFS in tux2lab or change production configuration.

Maintained implementation and tests now live in the project directories listed in
the [migration runbook](../../nfs-container-migration.md). This directory remains
historical evidence only; its scripts are not the deployment interface.

Follow-up: [September 24 independence and cold-start tests](../kernel-nfs-container-2026-09-24/README.md)
closed the running-host-daemon and unloaded-module test gaps, repeated both PXE
installs, and exercised mountd failure rollback. The original results below remain
the September 17 record; consult the follow-up for current findings and limits.

**Read before running:** these are privileged, host-specific diagnostic scripts,
not portable deployment tools. The handover stops host NFS/RPC services and changes
the shared kernel server's exports. Do not run it on a host with other NFS users,
active installations, or unrelated exports. No scripts were rerun against live
services while preparing this archive.

## Conclusion

Kernel NFS can serve host-mounted ISO filesystems from a rootful, privileged Podman
container with host networking and a separate mount namespace. Two real PXE
installations completed and booted from disk, each with 2 GiB RAM and two CPUs.

The reproduced NFSv4 failure was an implicit pseudoroot on the container's overlay
filesystem, not a categorical inability to export host ISO submounts. An explicit,
exportable ext4-backed `fsid=0` root fixed it while preserving client paths.

This proves the read-only installer use case on the tested host. It does not prove
all host distributions, all guest installers, writable shared storage, active-client
restart recovery, minimum privileges, or independence from every host NFS utility.

## Environment and Baseline

| Item | Observed value |
| --- | --- |
| Host | CBL-Mariner `2.0.20260331` |
| Kernel | `5.15.202.1-1.cm2` |
| Data backing filesystem | `/tux2lab-data` on ext4 `/dev/sda3` |
| ISO mounts | 20 existing ISO9660 mounts under `/tux2lab-data/os-repos`, shared propagation |
| Host resources | About 31 GiB RAM, no swap; about 280 GiB disk space available initially |
| Temporary directory | `/tmp/tux2lab-kernel-nfs-test-20260917-f2f902b4`, on tmpfs |
| Bridge | `labbr0`, IPv4 `10.28.28.1`, IPv6 `fd28:2808:2020:3000::1` |
| Lab domain / IPv4 subnet | `musubram.internal`, `10.28.28.0/22` |
| Existing infrastructure container | `tux2lab-engine`, `ghcr.io/muthukumar-subramaniam/tux2lab-engine:2.1.1` |
| Test container | `tux2lab-kernel-nfs-test`, rootful Podman, `--network=host --userns=host --privileged` |
| Test userspace | Alpine 3.21, `nfs-utils 2.6.4-r3`, Bash |
| Test image tag | `localhost/tux2lab-kernel-nfs-test:20260917-f2f902b4` |
| Recorded test image ID | `7874e0cdadcd2a7699634a69f338c2a19d28804780932efca4b659a741df8103` |
| NFS before and after test | `-2 +3 +4 +4.1 +4.2`, eight server threads |

The original host services were active: `nfs-server.service`,
`nfs-mountd.service`, `rpcbind.service`, `rpcbind.socket`, `rpc-statd.service`,
and `nfs-idmapd.service`. The first five were stopped for the final container test.
**Host `nfs-idmapd.service` was left active.** Its necessity was not isolated.
The host NFS packages and configuration were retained throughout.

The seven original guests (`k8s-cp1` through `k8s-cp3`, and `k8s-w1` through
`k8s-w4`, all in `musubram.internal`) remained running. The infrastructure
container was not restarted or replaced. At initial preflight there were no NFS
TCP connections, NFSv4 client-directory entries, or detected installation processes.

Original export, restored after testing:

```text
/tux2lab-data *.musubram.internal(ro,fsid=1,no_subtree_check,no_root_squash,crossmnt) 10.28.28.0/22(ro,fsid=1,no_subtree_check,no_root_squash,crossmnt)
```

## Working Mount and Export Layout

```text
Host ext4 scratch directory          -> container /export
Host /tux2lab-data (ro,rslave)        -> container /export/tux2lab-data
Container /tux2lab-data symlink      -> /export/tux2lab-data
Host scratch state directory        -> container /var/lib/nfs
```

The host scratch directory was created under `/tux2lab-data` so the pseudoroot
was on verified ext4, not the container overlay. See [exports](exports) for the
exact `fsid=0` parent and `fsid=1` data export. Both retain the existing read-only
access policy and `crossmnt` traversal.

NFSv4 clients still mount `server:/tux2lab-data/...`, relative to `/export` as the
pseudoroot. NFSv3 clients use the original absolute path through the container
symlink; mountd was observed to canonicalize it to `/export/tux2lab-data/...`.
The final design used a symlink, not a second data bind at the original path.

The control filesystem is mounted at `/proc/fs/nfsd`. With host networking,
container tools manage the same network-namespace-scoped kernel server as host
tools. Changing ports alone does not create an independent kernel instance.

The final server runs rpcbind, foreground mountd on port 20048, and eight kernel
NFS threads with v3/v4 and UDP enabled. Data listeners use bridge addresses via
`[nfsd] host = IPv4,IPv6` in container configuration. The test did not establish
complete confinement of every ancillary RPC listener to the bridge.

`rpc.mountd` is needed for export authorization/cache handling even with v4.
The final experiment does not start `rpc.statd`; it is not a locking-capable
writable-storage acceptance test.

## Preserved Files

These seven files are byte-for-byte copies of the final temporary files. Earlier
intermediate script versions are not archived. Scripts are invoked with Bash, so
they do not require executable permission. Do not generalize or silently repair
this snapshot when implementing production support; use separate production edits.

| File | Role |
| --- | --- |
| [Containerfile](Containerfile) | Alpine image with Bash and NFS utilities |
| [exports](exports) | Explicit pseudoroot and nested data export |
| [server.sh](server.sh) | Container startup, NFS configuration and cleanup |
| [handover.sh](handover.sh) | Host-specific preflight, service handover and rollback |
| [read-test.sh](read-test.sh) | Bounded mounts and full-file comparisons over v4 or v3 |
| [mount-lifecycle-test.sh](mount-lifecycle-test.sh) | Two live ISO mount/unmount/remount rounds |
| [export-probe.sh](export-probe.sh) | Isolated export-registration and rpc.nfsd argument probe |

The runtime `state/` directory is deliberately not archived. Neither are ISO
contents, VM disks, credentials, generated guest configuration, or complete raw
terminal logs. Diagnostic excerpts and acceptance observations are recorded below.
The original temporary directory and local test image were retained after testing.

The image recipe uses a mutable Alpine tag and package repositories. A future
rebuild may not reproduce the recorded image ID or NFS utility version. Preserve
or pin the tested image if exact binary reproduction is required.

## Test Results

| Test | Result and evidence |
| --- | --- |
| Direct ext4 and ISO export registration | Passed in a container with a separate network namespace using the isolated probe |
| Original-path NFSv4 mount with implicit overlay root | Failed; mountd could not export `/` |
| Explicit ext4-backed pseudoroot | Passed with original client paths unchanged |
| IPv4 NFSv4.2 reads | Full `cmp` passed for lab environment JSON, Alma stage2 image and Ubuntu live squashfs |
| IPv6 NFSv4.2 reads | Same three comparisons passed, using `proto=tcp6` |
| IPv4 NFSv3 reads | Same comparisons passed with original client paths |
| Live ISO mount lifecycle | Two mount/read/unmount rounds passed without restarting the server |
| Container stop, host restoration, fresh container | Repeated during the experiment; fresh client reads passed |
| AlmaLinux 9 PXE installation | Installed AlmaLinux 9.8, rebooted and booted from disk with 2 GiB / 2 CPUs |
| Ubuntu 24.04 PXE installation, v4-only server | Failed in initramfs before reaching the live installer |
| Ubuntu 24.04 PXE installation, v3/v4 server | Installed Ubuntu 24.04.4 and booted from disk with 2 GiB / 2 CPUs |
| Final host rollback | All six baseline services active, original exports and eight threads restored; full-file read comparisons passed again |
| Original lab and cleanup | Seven original VMs and engine running; both test VMs and their records removed; source worktree clean before this archive was added |

The lifecycle test remounted an existing Alma ISO loop device at a new scratch
directory, then checked container visibility and NFS reads. It did not exercise
every newly downloaded ISO, replacement image identity or nested mount topology.

Recreation tests used released clients and subsequent fresh mounts. They did not
prove NFSv4 state reclaim, open-file continuity or lock recovery during a restart.
The final script snapshot includes the v3 compatibility added after the initial
v4-only tests; not every matrix row was rerun against this exact final version.

### PXE Acceptance Evidence

| Guest | Identity | Completion evidence |
| --- | --- | --- |
| AlmaLinux | `nfs-probe-alma9.musubram.internal`, `10.28.28.11`, MAC `52:54:00:e3:b5:09` | Guest agent reported AlmaLinux 9.8, kernel `5.14.0-687.48.1.el9_8.x86_64`, root XFS on `/dev/vda3`; console reached installed-hostname login |
| Ubuntu | `nfs-probe-ubuntu24.musubram.internal`, `10.28.28.12`, MAC `52:54:00:6e:1c:bc` | Subiquity install finished; reboot event observed; kernel `6.8.0-100-generic` booted with a disk-root UUID; console reached installed-hostname login |

Both used 30 GiB virtual root disks. Libvirt reported `2097152 KiB` configured
memory and two CPUs. This is not a measurement of peak installer RAM or proof
that every supported installer works at 2 GiB. Ubuntu's guest agent did not connect,
so its acceptance evidence came from the serial console rather than agent queries.

Recorded Ubuntu excerpts:

```text
rpc.mountd: authenticated mount request from 10.28.28.12:784 for /export/tux2lab-data/os-repos/ubuntu-lts/24.04 (/export/tux2lab-data)
finish: subiquity/Install/install:
2026-09-17 13:36:00.967+0000: event 'reboot' for domain 'nfs-probe-ubuntu24.musubram.internal'
Command line: BOOT_IMAGE=/vmlinuz-6.8.0-100-generic root=UUID=b09f2ded-bda6-4346-8a76-2f95e8f9f2ad ro console=ttyS0,115200n8 nomodeset
Ubuntu 24.04.4 LTS nfs-probe-ubuntu24.musubram.internal ttyS0
nfs-probe-ubuntu24 login:
```

No PXE templates were edited for either test. Other guest distributions and other
host distributions were not tested. Azure Linux 3 NFS capability was not established;
its current tux2lab HTTP path must not be counted as container-NFS test coverage.

## Failures and Lessons

| Observation | Interpretation and response |
| --- | --- |
| Client NFSv4 mount returned `No such file or directory`; mountd logged `Cannot export /, possibly unsupported filesystem or fsid= required` and denied `/` | Implicit pseudoroot used the overlay-backed container root. Explicit ext4-backed `/export` with `fsid=0` fixed this reproduced failure. |
| `rpc.nfsd --no-nfs-version 2` returned `2: Unsupported version` | Tested Alpine utility already excluded v2. Removed that argument from rpc.nfsd; mountd accepted it. |
| Repeated `rpc.nfsd --host IPv4 --host IPv6` segfaulted | Reproduced with the tested Alpine utility. One IPv4 host worked; configuring both addresses in `[nfsd] host` worked. Do not generalize to every nfs-utils version. |
| Cleanup hung waiting for mountd | Removed the unbounded child wait from the experimental cleanup; targeted container stop triggered host restoration. Production cleanup still needs bounded shutdown and failure testing. |
| IPv6 helper returned `Address family for hostname not supported` with `proto=tcp` | Corrected the diagnostic mount to use bracketed IPv6 and `proto=tcp6`; full reads passed. |
| Ubuntu could not find a network live filesystem against the v4-only server | Its actual initramfs `nfsmount` rejected an explicit v4 request with `nfsmount: bad NFS version '4'`, despite `nfsopts=nfsvers=4` in the template. Enabling v3/RPC compatibility allowed the unchanged installer to complete. |
| Initial `rpc.statd` startup failed | Removed from this read-only experiment. Missing `sm` and `sm.bak` directories were later observed, but the cause was not proved. |
| `can't open /var/lib/nfs/rmtab for writing` | Later inspection found rmtab present and guest mounts succeeded. Root cause and clean-state startup behavior remain unresolved. |
| Podman reported `Could not retrieve exit code from event: died not found: unable to find event`, wrapper exit 127 | Observed when externally stopping the `--rm` test container. Rollback still printed `RESTORED` and independent service/export/read checks passed. Do not ignore exit 127 generally. |
| Running VM removal as root was rejected | Run `tux2lab vm remove` as the normal sudo-capable user, not via `sudo bash`. |

Earlier wrappers also returned 139 for the rpc.nfsd crash, 143 on termination,
and 1 for startup failure. These are diagnostic history, not passing test results.
The archived scripts preserve the final workarounds, not all failing variants.

Static review of the archived wrapper also identified a service-check limitation:
`systemctl is-active` with multiple units returns success if at least one is active.
Its combined preflight/rollback checks therefore do not prove that every required
unit is active. The rollback uses `set +e` and does not separately enforce success
of the final export reload. Production code must check each unit and operation,
not rely on the `RESTORED` message. The experiment's independent checks did show
all six units active, the expected exports and successful reads.

## Reproduction Runbook

This is a reviewed manual maintenance procedure for the recorded host layout,
not an unattended test suite. It interrupts NFS. Obtain a maintenance window and
verify there are no unrelated exports or clients, including UDP/NFSv3 users that
the wrapper's TCP/v4 checks can miss. Its process-name checks are not a lock
against another installer starting during handover.

### 1. Prepare Without Changing Services

The host must already provide Podman, Bash, NFS client/server utilities, kernel NFS
support, the recorded systemd units, lab bridge addresses, and the existing ISO
mounts. Noninteractive `sudo -n` must work. Do not remove host packages for this
replay. Both host NFS and mountd must initially be active; verify each explicitly
because the script's combined check does not enforce that requirement fully.

Run as the normal lab user. Restore the archive only into a missing working
directory; if it already exists, compare it and stop on any mismatch:

```bash
cd /tux2lab
ARCHIVE="$PWD/docs/experiments/kernel-nfs-container-2026-09-17"
WORK_DIR=/tmp/tux2lab-kernel-nfs-test-20260917-f2f902b4
IMAGE=localhost/tux2lab-kernel-nfs-test:20260917-f2f902b4
sudo -n true
if [[ ! -e "$WORK_DIR" ]]; then
    mkdir -p "$WORK_DIR"
    cp "$ARCHIVE"/{Containerfile,exports,server.sh,handover.sh,read-test.sh,mount-lifecycle-test.sh,export-probe.sh} "$WORK_DIR/"
fi
for name in Containerfile exports server.sh handover.sh read-test.sh mount-lifecycle-test.sh export-probe.sh; do
    cmp "$ARCHIVE/$name" "$WORK_DIR/$name" || exit 1
done
for script in "$WORK_DIR"/*.sh; do
    bash -n "$script" || exit 1
done
sudo -n exportfs -v
sudo -n systemctl is-active nfs-server.service nfs-mountd.service rpcbind.service rpcbind.socket rpc-statd.service nfs-idmapd.service
sudo -n cat /proc/fs/nfsd/versions /proc/fs/nfsd/threads
sudo -n virsh list --all
sudo -n podman ps --format '{{.Names}} {{.Status}}'
```

Record the baseline output outside the repository, without copying credentials.
Ensure neither test VM name is already in use. If the local image is absent,
rebuild it, noting the mutable dependency caveat above:

```bash
sudo -n podman build --no-cache -t "$IMAGE" \
    -f "$WORK_DIR/Containerfile" "$WORK_DIR"
```

### 2. Handover and Read Tests

Keep the foreground wrapper running in one terminal:

```bash
sudo -n bash /tmp/tux2lab-kernel-nfs-test-20260917-f2f902b4/handover.sh
```

Wait for `READY: container NFSv3/v4 server`, versions `-2 +3 +4 +4.1 +4.2`
and eight threads. In another terminal, confirm the first five baseline units are
inactive, the test container is running, and the original engine is still running.
The host idmapd unit remains active in this exact replay.

```bash
WORK_DIR=/tmp/tux2lab-kernel-nfs-test-20260917-f2f902b4
sudo -n bash "$WORK_DIR/read-test.sh" 10.28.28.1
sudo -n bash "$WORK_DIR/read-test.sh" '[fd28:2808:2020:3000::1]'
sudo -n env NFS_TEST_VERSION=3 bash "$WORK_DIR/read-test.sh" 10.28.28.1
sudo -n bash "$WORK_DIR/mount-lifecycle-test.sh"
sudo -n podman logs --tail 50 tux2lab-kernel-nfs-test
```

Run the lifecycle/cache-flush test before starting guests. `soft` mounts and
bounded `timeout` calls are diagnostic choices for read-only comparisons, not
production client defaults. The helper compares full files without printing their
contents and recursively unmounts its client mount on exit.

### 3. Real PXE Installation

Only after the read tests pass, create fresh disposable guests using the normal
CLI as the lab user. Confirm the names are unused first:

```bash
tux2lab vm install --via-pxe -H nfs-probe-alma9 -d almalinux -v 9 \
    --memory 2 --cpu 2 --root-disk-size 30
tux2lab vm install --via-pxe -H nfs-probe-ubuntu24 -d ubuntu-lts -v 24.04 \
    --memory 2 --cpu 2 --root-disk-size 30
```

Observe each serial console with `sudo -n virsh console <fqdn> --safe`.
Detach with Ctrl+]. A reboot event can be observed without a polling loop:

```bash
sudo -n virsh event nfs-probe-ubuntu24.musubram.internal --event reboot --timeout 900 --timestamp
sudo -n virsh dominfo nfs-probe-alma9.musubram.internal
sudo -n virsh dominfo nfs-probe-ubuntu24.musubram.internal
sudo -n virsh qemu-agent-command nfs-probe-alma9.musubram.internal '{"execute":"guest-get-osinfo"}'
sudo -n virsh qemu-agent-command nfs-probe-alma9.musubram.internal '{"execute":"guest-get-fsinfo"}'
```

Reboot alone is not acceptance. Require installed-system boot with disk-root
evidence and the expected hostname/OS. If the guest agent is unavailable, retain
serial installer completion and the subsequent disk-root kernel command line.
Capture console and container logs before deleting the guests/container; `--rm`
does not preserve the container log for this archive.

**Do not stop NFS while a guest still uses its NFS-backed live environment.**
If an installation fails, collect evidence and stop only that disposable guest
before restoring the server. Never interpret reaching Subiquity as completion.

### 4. Cleanup and Restore

These commands permanently delete the named guests and their data. Use them only
for the two guests created by this replay, after collecting acceptance evidence.
Do not use the top-level `tux2lab destroy` command.

```bash
tux2lab vm remove -f -H nfs-probe-alma9,nfs-probe-ubuntu24
sudo -n podman stop --time 15 tux2lab-kernel-nfs-test
```

Let the handover wrapper finish. It stops kernel NFS, unexports the test exports,
starts the original RPC/NFS services, reloads host exports and removes the empty
pseudoroot directory. Do not kill its terminal before rollback finishes.

Independently verify restoration, including after a Podman exit-event error:

```bash
sudo -n systemctl is-active nfs-server.service nfs-mountd.service rpcbind.service rpcbind.socket rpc-statd.service nfs-idmapd.service
sudo -n cat /proc/fs/nfsd/versions /proc/fs/nfsd/threads
sudo -n exportfs -v
sudo -n bash /tmp/tux2lab-kernel-nfs-test-20260917-f2f902b4/read-test.sh 10.28.28.1
sudo -n podman ps --format '{{.Names}} {{.Status}}'
sudo -n virsh list --all
find /tux2lab-data /tux2lab-data/os-repos /tmp -maxdepth 1 \
    \( -name '.nfs-kernel-test-*' -o -name 'tux2lab-nfs-client.*' \) -print
```

Expect all six units active, original exports, eight threads, successful file
comparisons, only the original seven VMs, no test container and no scratch mount
directories. Normal VM removal cleans disks, pools, hosts entries and ksmanager
records. The image and working directory remain as evidence; do not remove shared
ISOs or copy runtime state into this repository.

If rollback fails, preserve the error and verify the test container is stopped
before manual intervention. On this recorded host, the wrapper's restore sequence
is the following; it affects the entire host-network NFS server and must not be
used against an unrelated active server:

```bash
sudo -n /usr/sbin/rpc.nfsd 0
sudo -n /usr/sbin/exportfs -ua
sudo -n systemctl start rpcbind.socket rpcbind.service rpc-statd.service nfs-server.service nfs-mountd.service
sudo -n /usr/sbin/exportfs -ra
```

Then repeat the independent restoration checks. An EXIT trap does not protect
against power loss, SIGKILL or every partial startup failure.

### Isolated Diagnostic Probe

This is an optional export-registration probe, not a client read test. Its network
namespace must remain separate from the host. **Never run this probe directly on
the host or change it to `--network=host`: its cleanup stops and unexports NFS.**

```bash
sudo -n podman run --rm --network=none --userns=host --privileged \
    -v /tux2lab-data:/tux2lab-data:ro,rslave \
    -v /tmp/tux2lab-kernel-nfs-test-20260917-f2f902b4:/test:ro \
    localhost/tux2lab-kernel-nfs-test:20260917-f2f902b4 /test/export-probe.sh
```

It registers ext4 and ISO exports to loopback. Optional script arguments are passed
to rpc.nfsd, and `NFS_TEST_HOSTS` can write its configuration. This was used to
isolate the repeated-host-argument crash; crashing variants are not part of the
normal acceptance replay.

## Clean Integration Handoff

### Required Host Support

The container supplies NFS userspace, not a kernel. The host needs `CONFIG_NFSD`
built in or the matching loadable module, NFSv4 support, RPC/export/locking
infrastructure, loop and ISO9660 support, and IPv6 when serving IPv6 clients.
Kernel support may be delivered in a separate distro kernel-modules package.
Installing container NFS utilities cannot replace missing host kernel features.

No custom kernel patch was needed on this host. Module loading from an initially
unloaded state, reboot persistence, and a host without installed NFS utilities
were not tested. The read-test and rollback scripts themselves use host utilities.

### Decisions and Risks Before Implementation

1. Decide whether NFS joins the engine or remains a dedicated companion container.
   Only the disposable companion was tested. Sharing the engine changes lifecycle
   behavior: an unrelated service failure could interrupt installer NFS access.
2. Establish one owner for host-network NFS/RPC. Detect unrelated exports, services
   and listeners; refuse destructive takeover. Snapshot prior service state for
   rollback instead of assuming every unit was active. The archived wrapper uses
   global `exportfs -ua` and is not a general migration implementation.
3. Choose a stable exportable pseudoroot and persistent recovery-state directory.
   Do not use `/tmp` in production. Validate the actual filesystem and do not
   infer exportability from directory existence. Test stable file handles and
   server identity across recreation and reboot.
4. Preserve both v4 client-relative paths and v3 absolute paths. The engine
   already mounts data at `/tux2lab-data` with writable submounts for other services;
   the test's symlink cannot simply replace that mount. Design aliases/mounts and
   verify their identity and propagation without breaking existing services.
5. Keep v3/v4 compatibility until the actual guest initramfs matrix justifies a
   change. Do not remove v3 based solely on the Ubuntu PXE argument. Determine
   required RPC transports and bind/firewall every listener, not just port 2049.
6. Test with host idmapd stopped. Supply any needed daemon inside the container.
   Resolve clean-state rmtab initialization and statd requirements explicitly.
   Do not claim writable lock support from the read-only installer tests.
7. Supervise required userspace daemons, verify kernel threads and real reads for
   readiness, and implement bounded cleanup. Avoid copying the diagnostic
   `set -x`, daemonized rpcbind supervision gap or broad process-name cleanup
   directly into the multi-service engine.
8. Retain existing export authorization during migration, but review exposure:
   `crossmnt` exposes child mounts and `no_root_squash` is an existing policy,
   not a security recommendation. Handle IPv4-only labs and SELinux/AppArmor
   hosts; the privileged test did not establish minimum capabilities.

### Owning Code to Update

| Current code | Integration responsibility |
| --- | --- |
| [container/Containerfile](../../../container/Containerfile) | Package NFS userspace in the chosen production image; account for dependency/version behavior |
| [container/entrypoint.sh](../../../container/entrypoint.sh) | If integrating into the engine, add startup/readiness/supervision/cleanup; current `wait -n` is not sufficient evidence of kernel NFS health |
| [shared-functions/run-container.sh](../../../shared-functions/run-container.sh) | Centralize mount layout, persistent state and runtime flags; preserve existing data and writable mounts |
| [setup/generate-service-configs.sh](../../../setup/generate-service-configs.sh) | Generate explicit pseudoroot/data exports and bind configuration from lab settings |
| [shared-functions/host-nfs.sh](../../../shared-functions/host-nfs.sh) | Transition ownership and rollback; correct its disproved blanket mount-namespace explanation as part of the migration |
| [setup/setup-host.sh](../../../setup/setup-host.sh) | Separate kernel/module prerequisites from host userspace requirements; do not remove packages until all callers and rollback needs are handled |
| [setup/deploy-lab.sh](../../../setup/deploy-lab.sh) | Update both deployment paths that currently start host NFS |
| [start.sh](../../../qemu-kvm-manage/scripts-to-manage-vms/start.sh), [stop.sh](../../../qemu-kvm-manage/scripts-to-manage-vms/stop.sh), [rebuild.sh](../../../qemu-kvm-manage/scripts-to-manage-vms/rebuild.sh), [destroy.sh](../../../qemu-kvm-manage/scripts-to-manage-vms/destroy.sh) | Coordinate ISO mounts, NFS ownership, container lifecycle and rollback in every lifecycle command |
| [common-utils/tux2lab-iso-mounts.sh](../../../common-utils/tux2lab-iso-mounts.sh) | Preserve runtime ISO mount propagation and stop-before-unmount ordering |
| [ksmanager/prepare-distro-for-ksmanager.sh](../../../ksmanager/prepare-distro-for-ksmanager.sh) | Route the current host `exportfs -f` unmount retry through the chosen NFS owner |
| [health.sh](../../../qemu-kvm-manage/scripts-to-manage-vms/health.sh) | Replace host-only export inspection with checks of the actual owner, listeners, exports and usable reads |
| [Red Hat PXE template](../../../ksmanager/ipxe-templates/ipxe-template-redhat-based.ipxe), [Ubuntu PXE template](../../../ksmanager/ipxe-templates/ipxe-template-ubuntu-lts.ipxe) | Preserve client URLs and test effective protocol behavior; neither was changed during this experiment |

These are verified integration touchpoints, not permission to remove unrelated
host NFS configuration or an exhaustive cross-repository dependency audit.

### Suggested Implementation Sequence and Acceptance Gates

1. Add host/kernel/filesystem preflight and generated export layout without
   changing the default NFS owner. Unit-test configuration and conflict rejection.
2. Add container NFS with persistent state and deterministic supervision. Validate
   fresh-state startup, absent optional IPv6 and required listener binding.
3. Implement explicit handover/rollback in the common lifecycle layer. Test partial
   failures and concurrent operations before switching the deployment default.
4. Update deploy/start/stop/rebuild/destroy, ISO removal and health together. Confirm
   normal boot paths do not require a manually started host NFS daemon.
5. Repeat IPv4/v4, IPv6/v4 and IPv4/v3 full-file reads, original-path compatibility,
   dynamic mounts and both completed 2 GiB PXE installations on the final code.
6. Broaden guests to supported Red Hat-family versions and Ubuntu releases. Test
   representative Debian/Ubuntu, RHEL-family and openSUSE hosts with their actual
   kernel packages, filesystems and security policy. Do not claim universal support.
7. Test cold boot with the module initially unloaded and no running host NFS/RPC
   daemons, clean-state startup, container recreation and a reboot. Separately test
   active-client recovery before making continuity claims. Writable distributed
   storage, locks and reclaim need their own acceptance plan.
8. Run the repository's relevant tests and ShellCheck on production changes, then
   document supported hosts, prerequisites, failure handling and migration rollback.
   Remove host userspace dependencies only after this audit and validation pass.

## Archive Validation

At archive creation, all seven files matched their temporary originals byte for
byte. `bash -n` passed for all five scripts, and editor diagnostics reported no
errors. ShellCheck was not installed on the host, so that required lint check was
not completed; it remains a gate before promoting these patterns into production.
The documentation's Bash snippets passed syntax validation and all 24 local links
resolved. Syntax validation does not execute privileged test actions.