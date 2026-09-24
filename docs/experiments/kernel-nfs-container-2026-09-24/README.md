# Container NFS Independence and Cold-Start Tests

Date: 2026-09-24. Follow-up to the
[September 17 experiment](../kernel-nfs-container-2026-09-17/README.md).

Status: completed on the same CBL-Mariner host and kernel
`5.15.202.1-1.cm2`. Host NFS/RPC services, control mount and exports were restored
and independently checked. Both disposable guests were removed. The original
seven VMs and `tux2lab-engine` remained running; no production integration or host
package removal was performed.

Later implementation work is tracked in the
[migration runbook](../../nfs-container-migration.md). This directory records the
standalone experiment, not acceptance of the integrated engine.

## What This Establishes

The read-only installer workload does not need a running host NFS/RPC daemon,
including host `rpc.idmapd`, on this tested setup. Container startup also succeeded
after the host's `nfsd` module was completely unloaded. Both real PXE installs
completed under those conditions with 2 GiB RAM and two CPUs each.

This is not a package-free host test. The matching kernel module and host kernel
module loader remained installed; host NFS packages were retained for rollback
and client-side checks. Kernel userspace upcalls for recovery or identity handling
were not traced, so do not infer independence from every host executable merely
from the absence of running host daemons. No host reboot was performed.

## Results

| Check | Result |
| --- | --- |
| All host NFS/RPC daemons stopped | Passed; checked each unit, service MainPID and process absence |
| Empty container state, original server script | Server and reads passed; missing-rmtab warnings reproduced |
| Fresh-state initialization | Touching the packaged `etab`, `rmtab` and `state` files before startup eliminated those warnings in the cold-start run |
| Cold `nfsd` start | Passed; normal `rmmod nfsd` succeeded and `/sys/module/nfsd` was absent before container launch |
| Host control filesystem independence | Host `proc-fs-nfsd.mount` stayed inactive; the container mounted its own nfsd control filesystem |
| IPv4 NFSv4.2, IPv6 NFSv4.2, IPv4 NFSv3 | Full-file comparisons passed in both the daemon-independence and cold-start runs |
| Live ISO lifecycle after cold start | Two mount/read/unmount rounds passed without server restart |
| AlmaLinux 9 PXE | Installed AlmaLinux 9.8 and booted disk root on `/dev/vda3` |
| Ubuntu 24.04 PXE | Installed Ubuntu 24.04.4 and booted with a disk-root UUID |
| Normal container stop | Initial independence run restored all six host services and original exports |
| Injected mountd failure | Killing only container mountd caused server cleanup and wrapper rollback; exit 137 was expected |
| Final rollback verification | Seven units including the control mount active, original exports, eight threads, full-file host NFS reads passed |
| ShellCheck | Version 0.10.0 passed for all September 17 scripts and the three follow-up scripts |

Read comparisons covered the ordinary lab environment JSON, Alma stage2
`images/install.img` and Ubuntu `casper/ubuntu-server-minimal.squashfs`. File
contents were not printed or archived. The lifecycle test reuses an existing
Alma loop device at a temporary additional mountpoint; it is not coverage of all
new ISO identities or replacement-image cases.

The six host units were `nfs-server.service`, `nfs-mountd.service`,
`rpcbind.service`, `rpcbind.socket`, `rpc-statd.service` and `nfs-idmapd.service`.
They remained stopped during client checks and both installations. The container
process list contained Bash, rpcbind and mountd, with no container idmapd or statd.

The host idmapd unit becomes `failed` on SIGTERM because this binary exits with
status 1. Journal entries confirmed termination; MainPID was zero. Two initial
wrapper attempts rejected that state and restored the baseline before starting a
container. The corrected wrapper accepts `inactive` or `failed` only with zero
service MainPID and no matching running RPC daemon. Socket units do not expose
MainPID and are checked by state. Rollback checks every service individually.

## Cold-Start Evidence

The retained image matched the original image ID:
`7874e0cdadcd2a7699634a69f338c2a19d28804780932efca4b659a741df8103`.
It contains Alpine 3.21 and `nfs-utils 2.6.4-r3`.

The host module file is
`/lib/modules/5.15.202.1-1.cm2/kernel/fs/nfsd/nfsd.ko.xz`.
`/proc/sys/kernel/modprobe` was `/sbin/modprobe`, and modules were not disabled.
The wrapper stopped the host control mount and used `rmmod nfsd`, without force
and without unloading shared dependencies. No host `modprobe nfsd` was invoked
between proving module absence and starting the container. Its filesystem mount
request triggered loading through the host kernel/module-loader mechanism.

```text
STOPPED: all six host services; no host NFS/RPC daemons
FRESH STATE: /tmp/tux2lab-kernel-nfs-test-20260924/state.O8U06L
COLD: nfsd module absent before container startup
+ mount -t nfsd nfsd /proc/fs/nfsd
READY: container NFSv3/v4 server
-2 +3 +4 +4.1 +4.2
8
```

The data/export layout and read-only options are unchanged from September 17.
The only server-script change is creation of the three state files before the
control filesystem mount. This preserves contents if files already exist, but
does not establish a statd state format, lock recovery or durable NFSv4 recovery.
The test state directory is on `/tmp` tmpfs, not production persistent storage.

## PXE Evidence

Both guests used two CPUs, `2097152 KiB` configured memory and 30 GiB root disks.
Peak RAM was not measured. Existing PXE templates were unchanged.

| Guest | Address / MAC | Evidence |
| --- | --- | --- |
| `nfs-cold-alma9.musubram.internal` | `10.28.28.11`, `52:54:00:14:35:5f` | NFSv4 export access; reboot at `11:07:07.222+0000`; guest agent reported AlmaLinux 9.8, kernel `5.14.0-687.49.1.el9_8.x86_64`, root XFS on `/dev/vda3` |
| `nfs-cold-ubuntu24.musubram.internal` | `10.28.28.15`, `52:54:00:06:61:db` | NFSv3 mount authenticated; Subiquity completion; reboot at `11:11:25.013+0000`; installed-hostname login and disk-root command line |

Ubuntu's guest agent was not connected. Its serial evidence was:

```text
finish: subiquity/Install/install:
Command line: BOOT_IMAGE=/vmlinuz-6.8.0-100-generic root=UUID=82ef722b-eae3-456b-b39c-31edf2b42345 ro console=ttyS0,115200n8 nomodeset
Ubuntu 24.04.4 LTS nfs-cold-ubuntu24.musubram.internal ttyS0
nfs-cold-ubuntu24 login:
```

## Failure and Restoration Evidence

After guest completion, the normal VM removal command removed only today's two
test domains, disks, pools, hosts entries and provisioning records. Established
server-side TCP entries remained for their two old addresses even after deletion.
The initial no-connections guard correctly refused fault injection. After verifying
that both domains were absent and no other NFS peer was present, those known stale
entries were allowed for this one manual fault test.

Only `rpc.mountd` inside `tux2lab-kernel-nfs-independence-test` was sent SIGKILL.
The Bash parent observed its exit and ran cleanup. It reported `No such process`
when attempting to terminate the already-killed child, then completed cleanup.
The wrapper retained the nonzero exit status and restored host services and exports.

```text
Killed rpc.mountd --foreground --no-nfs-version 2 --port 20048 --log-auth
RESTORED: all six host services and original exports
-2 +3 +4 +4.1 +4.2
8
```

Independent checks confirmed every baseline service and `proc-fs-nfsd.mount`
active, original exports and matching installer file reads through host NFS.
Only the original seven VMs and engine remained running; no scratch pseudoroot,
ISO test directory or client mount directory remained. This tests controlled
child-process failure with the parent and host wrapper alive, not PID 1 SIGKILL,
host failure, automatic in-container recovery or active-client continuity.

## Listener Audit: Still a Production Gate

Observed with `ss` and container `rpcinfo -p`:

| Listener | Observed binding |
| --- | --- |
| NFS TCP/UDP 2049 | Lab bridge IPv4 and IPv6 addresses |
| rpcbind UDP 111 | Bridge and loopback IPv4/IPv6 addresses |
| rpcbind TCP 111 | Wildcard IPv4/IPv6 despite the `-h` arguments |
| mountd TCP/UDP 20048 | Wildcard IPv4/IPv6 |
| Kernel lockd | Registered dynamic ports, UDP 33818 and TCP 43717 in this run |

No firewall or listener changes were made during the installations. Do not claim
all NFS/RPC traffic is bridge-bound based solely on `[nfsd] host` or rpcbind `-h`.
Production design must explicitly constrain ancillary RPC exposure and handle
dynamic ports. The registered lockd programs do not prove working lock recovery;
statd and writable/locking clients were not tested.

## Script Inventory and Replay

- [independence.sh](independence.sh): host-specific guarded handover, optional cold
  unload, fresh state, retained container logs and verified rollback.
- [server.sh](server.sh): original server plus the three state-file initializations.
- [mount-lifecycle-test.sh](mount-lifecycle-test.sh): original lifecycle test with
  the follow-up container name.

The three files match the temporary test scripts byte for byte. Reuse the prior
[Containerfile](../kernel-nfs-container-2026-09-17/Containerfile),
[exports](../kernel-nfs-container-2026-09-17/exports) and
[read-test.sh](../kernel-nfs-container-2026-09-17/read-test.sh); do not duplicate or
modify the older archive. Raw state, complete console logs and credentials are
not copied into the repository. Local baseline files and container logs remain
under `/tmp/tux2lab-kernel-nfs-test-20260924`.

**Replay is disruptive and host-specific.** Read the prior runbook's maintenance,
client detection and rollback requirements first. Do not run on a host with other
exports or clients. The lock only serializes these experiment wrappers, not the
normal VM CLI; client/process checks cannot eliminate every race or detect all
UDP clients. The wrapper assumes all six units were active initially and refuses
otherwise. It is not a general-purpose production lifecycle implementation.

On the recorded host, stage the three files in the working directory without
overwriting differing files. Retain the original image and archive paths. Invoke
the wrapper in a terminal that stays open until rollback completes:

```bash
sudo -n env COLD_START=1 SERVER_SCRIPT=/followup/server.sh \
    bash /tmp/tux2lab-kernel-nfs-test-20260924/independence.sh
```

Without those environment variables it performs the daemon-independence test
using the original server script and no module unload. Both modes create a fresh
state directory. The cold mode restores the host control mount during rollback.

In a separate terminal after readiness:

```bash
ARCHIVE=/tux2lab/docs/experiments/kernel-nfs-container-2026-09-17
sudo -n bash "$ARCHIVE/read-test.sh" 10.28.28.1
sudo -n bash "$ARCHIVE/read-test.sh" '[fd28:2808:2020:3000::1]'
sudo -n env NFS_TEST_VERSION=3 bash "$ARCHIVE/read-test.sh" 10.28.28.1
sudo -n bash /tmp/tux2lab-kernel-nfs-test-20260924/mount-lifecycle-test.sh
```

Run mount lifecycle checks before guests; they flush the export cache. Create the
two disposable guests with the prior runbook's PXE commands, substituting today's
`nfs-cold-alma9` and `nfs-cold-ubuntu24` names only after confirming they are unused.
Do not stop NFS while either guest needs its live root. After collecting completed
disk-boot evidence, remove only the guests created for this replay and normally
stop the test container to trigger rollback:

```bash
tux2lab vm remove -f -H nfs-cold-alma9,nfs-cold-ubuntu24
sudo -n podman stop --time 15 tux2lab-kernel-nfs-independence-test
```

The fault-injection variant is deliberately not included as an automatic replay
step. It requires independent verification that no live guest or unrelated client
depends on the server. After either stop method, verify each service, the host
control mount, exports, eight threads, full-file reads and original guests as in
the prior runbook. Do not treat a wrapper exit code or message alone as acceptance.

## Integration Branch and Remote Backup

The agreed `migration/nfs-host-to-container` branch was created from main at
`0d0c7dc01395a484a98f2ef3a72f6aea0b465bf9`. Both experiment archives were committed
as `a3cf462a6445780c0024ec741ce22c88b160eef1`, pushed to
`origin/migration/nfs-host-to-container`, and the matching remote tip verified.
That is a preservation milestone, not a live handover.

Maintained service code, lifecycle integration, tests and current acceptance gaps
are documented in the [migration runbook](../../nfs-container-migration.md).
The experiment scripts remain unchanged reference snapshots. Runtime state,
credentials, raw sensitive logs, ISO contents and guest disks are not in Git.

## Gates Recorded After the Experiment

1. Select engine integration versus a companion container, then implement durable
   state and deterministic startup/shutdown without copying this diagnostic
   wrapper wholesale. Runtime services have not been migrated.
2. Constrain all NFS/RPC listeners and test IPv4-only labs and host security policy.
3. Test a clean host without NFS utility packages, including kernel helper/upcall
   behavior, and an actual host reboot. Today's unloaded-module test is not a
   cold-boot or package-removal test.
4. Verify durable handles, recovery state, repeated recreation and active-client
   reclaim. Writable shared storage and locks need separate acceptance tests.
5. Extend supported guest versions and representative host distributions. Today's
   result is for the same Mariner kernel, ext4/ISO9660 layout and two guest images.
6. Update deploy/start/stop/rebuild/destroy, ISO removal and health as one coherent
   integration, preserving conflict rejection and rollback.

ShellCheck 0.10.0 was installed and run in a disposable container only, with both
script directories mounted read-only. Host packages and the retained test image
were not changed. Bash syntax, archive equality and documentation links are also
validated as part of this handoff.