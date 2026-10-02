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
| [shared-functions/engine-rootfs.sh](../shared-functions/engine-rootfs.sh) | Exportable per-instance roots, image identity and guarded cleanup/rollback |
| [shared-functions/run-container.sh](../shared-functions/run-container.sh) | Mount layout, launch and replacement with retained previous engine |
| [setup/migrate-nfs-to-container.sh](../setup/migrate-nfs-to-container.sh) | Explicit host-service handover and rollback |
| [container/run-nfs-tests.sh](../container/run-nfs-tests.sh) | Rootless regression tests and isolated integration tests |
| [container/run-engine-tests.sh](../container/run-engine-tests.sh) | Complete-engine client protocols, ISO propagation and shutdown/failure checks |

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
- The original layout is preserved: the host data tree is mounted directly at
  `/tux2lab-data:ro,rslave` inside the engine. It is not a symlink. Only
  `/tux2lab-data` is configured/advertised as an export, with `fsid=1`; both
  NFSv3 and NFSv4 clients continue using `:/tux2lab-data`. No `/export` tree or
  explicit `fsid=0` export is configured.
- NFSv4's implicit root requires an exportable container filesystem; the normal
  overlay root cannot provide it. The launcher resolves the image to its ID,
  exports a stopped temporary image container, and extracts it into a fresh
  root-owned instance under `/var/lib/tux2lab/engine-rootfs/engine.XXXXXXXX/rootfs`.
  Podman runs that directory with `--rootfs` and the image's `/entrypoint.sh`.
  The root store is outside exported lab data and must be on ext4, XFS or Btrfs.
  Ext4 and XFS are tested; Btrfs and enforcing security policies remain unverified.
  No host-wide Podman storage-driver setting is changed.
- Each engine gets its own writable root. Stop/start and reboot retain it;
  successful replacement removes only the superseded instance. Failed
  replacement restores the previous engine/root and its exports. Destroy and
  host-migration rollback use the same cleanup helper. Cleanup requires a
  canonical marked path, no container references and no mounts below it;
  inspection failures retain the directory. Do not manually delete or share
  instance roots, including ones held by a rebuild backup.
- Rootfs containers have empty native image fields. Labels
  `io.tux2lab.image.name`, `io.tux2lab.image.id` and `io.tux2lab.rootfs` retain
  provenance; `tux2lab info` and rebuild use the recorded image name. New images
  require both `io.tux2lab.nfs=container-v1` and
  `io.tux2lab.nfs.layout=direct-v1`; obsolete `/export` images are rejected.
- Exports remain read-only, with the existing wildcard lab-domain authorization
  and explicit IPv4/IPv6 client networks. Existing `no_root_squash` semantics are
  retained: this is a trusted lab export, not an authorization boundary for
  hostile lab clients. The NFSv4 root exposes only `tux2lab-data`.
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

Development images stay local throughout implementation and acceptance testing.
Publishing a development image to a registry is not a required migration step.
After acceptance, build and validate the final release image, then publish it
before release using the normal release workflow.

From `/tux2lab`:

```bash
sudo podman build --network=host -t localhost/tux2lab-engine:nfs-migration \
  -f container/Containerfile .
bash container/run-nfs-tests.sh
bash container/run-nfs-tests.sh --firewall localhost/tux2lab-engine:nfs-migration
bash container/run-nfs-tests.sh --service localhost/tux2lab-engine:nfs-migration
bash container/run-engine-tests.sh --startup localhost/tux2lab-engine:nfs-migration
bash container/run-engine-tests.sh --run localhost/tux2lab-engine:nfs-migration \
  /tux2lab-data/os-repos/almalinux/9
bash container/run-engine-tests.sh --failure localhost/tux2lab-engine:nfs-migration
```

The default suite needs Bash and jq and uses temporary files and command mocks.
The two integration modes need rootful Podman, the built image and host kernel
support. They create disposable private network namespaces, never share the
host network, and never stop host services. The service test uses dedicated
scratch directories on `/tux2lab-data`, prepares a managed exportable root, and deliberately skips host-wide lockd
sysctl writes. It does not prove fixed lockd port allocation on the production
network namespace. These two modes do not start the full engine or install guests.

The separate engine runner needs rootful Podman, sudo, tar, jq, exportable backing
filesystems for `/tux2lab-data` and the managed root store, and IPv4/IPv6 kernel
support. Its `--startup`
mode runs client protocol checks and graceful shutdown; `--run` also tests ISO
propagation. Supply an existing read-only ISO9660 loop mount containing
`images/install.img`. The runner mounts that loop device at a separate scratch
mountpoint and never unmounts the supplied original. `--failure` kills only the
disposable engine's mountd and verifies engine-wide shutdown.

Service and observer containers use private networking. A nonprivileged fixture
container uses host networking only to fetch `jq` and `openssl`; neither package
is added to the production image or host. Fixtures are synthetic, generated by
the real service-config generator, with a minimal authoritative BIND zone and
local-only chrony configuration. The runner executes the image's actual
entrypoint with the production bind layout, intercepting only host-wide lockd
writes. It does not exercise the host launcher or perform a live handover.

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
test deliberately skips those host-wide sysctl writes. No host handover or
registry image publication was performed for this review.

## September 28 Complete-Engine Tests

The maintained engine runner passed on the Mariner 2.0 host, kernel
`5.15.202.1-1.cm2`, with ext4 scratch data and a separate read-only mount of the
existing AlmaLinux ISO:

- Actual DNS UDP/TCP, HTTP/HTTPS with certificate verification, complete iPXE
  TFTP transfer and local NTP responses over IPv4 and IPv6.
- DHCPv4 discover/request and DHCPv6 solicit/request lease allocation, PXE
  settings, IPv6 DNS/boot URL, router solicitation/advertisement flags and prefix,
  and authenticated Kea control-agent access to both DHCP daemons.
- Two host ISO mount/unmount rounds per engine, with no engine restart. Full
  installer SHA-256 checks matched over NFSv4 IPv4/IPv6, NFSv3 IPv4, and HTTP/HTTPS
  IPv4/IPv6. Unmounts removed ISO content from the running engine. Cache flushing
  was confined to the private server namespace.
- SIGTERM exit 143 without forced termination and injected mountd failure exit 1.
  A separate observer retained the test network namespace after engine exit and
  verified zero NFS threads, no exports, no service listeners and no nftables
  tables, before removing all test containers, mounts and scratch data.

Repeated testing exposed a real startup race: nfsd could start before nfsdcld
finished its database initialization and installed its pipe watch. The kernel
then failed client tracking initialization and entered a 90-second grace period,
causing the first NFSv4 read to exceed the test timeout. Startup now waits for
the daemon's inotify watch, and readiness requires the kernel recovery pipe.
Rootless regressions cover immediate/delayed readiness, daemon death, timeout and
unreadable state. Three consecutive full-engine runs after rebuilding passed all
checks and six ISO propagation rounds; the failure test also passed again.
Kernel logs confirmed nfsdcld tracking selection on all post-fix starts.

Validated local image ID:
`648a4a32830a5b557dc5f12dd63e38586d8178b2134b06dbb2eba616e3399ce5`.
Rootless regressions, isolated NFS reads/write rejection/restart/failure, Bash
syntax and ShellCheck passed. Engine-runner lint excludes only `SC2317` for
indirect EXIT traps; the existing mock suite uses warning severity and the
project source search path.

These results do not establish external NTP synchronization, full dnsbinder
configuration generation, active-client reclaim, fixed host-network lockd port
allocation, host launcher lifecycle behavior or actual guest installation.
The released live engine retained its original uptime, all seven guests and
host NFS units remained active, and host exports, eight NFS threads and zero
lockd sysctl values were unchanged. No development image was published.

## Planned Handover

Do not execute this section until an integrated acceptance window is authorized.
For full end-to-end acceptance, the target is the current CBL-Mariner KVM host.
Dedicated test-host VMs also exercise this procedure against their own released
lab baseline, without changing the parent's NFS owner. On either target, require
no unrelated NFS exports or clients. Shut down
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

An image must carry `io.tux2lab.nfs=container-v1` and
`io.tux2lab.nfs.layout=direct-v1`. Released v2.1.1 and earlier migration images
are rejected for new launches.
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

## Remaining Acceptance Plan

The implementation now preserves the original `/tux2lab-data` layout, including
export discovery. The compatibility finding and integration results below
supersede the earlier `/export` design. Existing tests do not replace the
remaining actual lab setup, deployment or integrated PXE acceptance checks.
The remaining work is split into three stages:

1. **Dedicated test-VM deployment and compatibility.** Create test hosts through
  the existing tux2lab tool, then run the real host setup and lab deployment
  inside each distribution. Verify the deployed lab, lifecycle and recovery,
  plus migration/rollback from a separate released baseline. The host matrix
  and required checks are below. Do not create deeper-nested PXE guests.
2. **Current KVM-host end-to-end acceptance.** In a separately approved maintenance
  window on the current CBL-Mariner host, test actual NFS handover, normal
  tux2lab VM creation and unchanged 2 GiB AlmaLinux/Ubuntu NFS-backed PXE
  installations through installed-disk boot. Verify all deployed services, ISO
  propagation, start/stop/rebuild, repeated container recreation, RPC ports and
  firewall behavior, recovery and rollback. Schedule host reboot and disruptive
  fault injection explicitly within that window. Historical standalone-server
  experiments and sibling-VM protocol tests do not replace this workflow.
3. **Release preparation.** Resolve findings and rerun affected checks, record
  results and unsupported/untested configurations, and finalize cleanup and
  documentation. Complete the host executable/upcall dependency audit before
  any separately approved host NFS package removal. Keep development images
  local; build and validate the final release image, then publish it through
  the normal release workflow. Publication and merge to main require approval.

This document update authorizes no VM provisioning, live handover, host reboot,
package removal, image publication or merge. Before execution, confirm the test
targets, resource budget and any maintenance window with the user.

### Export Discovery Compatibility (October 2, 2026)

The user requires the existing layout to remain unchanged: host and container
data at `/tux2lab-data`, only `/tux2lab-data` advertised by `showmount -e`, and
the existing `SERVER:/tux2lab-data` client path. Successful mounts through a
symlink do not establish export-discovery compatibility. The previous migration
implementation's `/export` and `/export/tux2lab-data` listing violated this
requirement; it is replaced by the managed-root direct layout described above.

A disposable private-network container inside the AlmaLinux 9.8 test VM compared
two root filesystems using the same engine image and NFS daemons. It directly
bound scratch data to `/tux2lab-data`, configured just that export with `fsid=1`,
and retained wildcard-domain authorization plus test IPv4/IPv6 client networks.
Local test-hostname resolution avoided unrelated wildcard lookup timeouts.

- With the normal overlay root, discovery and NFSv3 worked, but NFSv4 over both
  IP families failed. Mountd reported `Cannot export /, possibly unsupported
  filesystem or fsid= required` when constructing its implicit NFSv4 root.
- Unpacking the same image into a scratch XFS directory and running it with
  Podman `--rootfs` passed the single-export discovery check, original-path
  NFSv3/IPv4 and NFSv4.1/IPv4/IPv6 reads, and server-enforced read-only access.
  No explicit root export or `/export` directory was required.
- Two live scratch ISO mount/unmount cycles passed full installer SHA256 reads
  and absence checks across those three protocol variants without server restart.
  A graceful server stop/start with the ISO mounted before startup also passed.
  Mounting the NFSv4 root exposed only `tux2lab-data`, not container `etc`, `usr`
  or `var`; discovery continued to advertise only `/tux2lab-data`.

This initial experiment established feasibility, not production integration.
The user subsequently authorized implementing and pushing the layout-preserving
runtime. No production launcher, export generator, image, storage-driver setting
or deployed lab layout was changed during the initial experiment itself.
Other kernels/filesystems and active-client recovery were not tested here.
The disposable server and scratch mounts were removed. Probe source and logs
are retained in the VM at `/home/musubram/nfs-layout-test.yKeNnw9Z/`.
The parent retains its original engine uptime, NFS ownership and exact advertised
export `/tux2lab-data *.musubram.internal,10.28.28.0/22`.

### Direct-Layout Integration (October 2, 2026)

The maintained launcher, exports, entrypoint, lifecycle cleanup, image reporting,
host-migration rollback and both integration harnesses now use the direct layout.
Local image `localhost/tux2lab-engine:nfs-direct-layout` has ID
`ef259c909b57cb4fd05695b27d928c1c1a1c1fd0e19c824789997f0303ac4eb6`.
It was not published to a registry.

- Rootless regressions cover the single export, old-image rejection, cleanup
  refusal for unsafe/referenced/mounted roots and failed inspections, and export
  restoration for managed and legacy engine backups.
- On the Mariner parent with ext4, private-namespace service and complete-engine
  tests passed NFSv3/IPv4 and NFSv4/IPv4/IPv6, read-only enforcement, single-path
  discovery, NFSv4 root visibility, all engine client protocols, two live ISO
  propagation rounds, graceful shutdown and injected mountd failure cleanup.
  The parent's live server and host-wide lockd settings were not changed.
- On the actual AlmaLinux/XFS test host, normal rebuild switched the lab to the
  direct layout. Health passed 11/11 deep checks and 6/6 dual-stack services;
  `tux2lab info` reported the correct image. `showmount` advertised only
  `/tux2lab-data` with the wildcard domain and IPv4/IPv6 client networks.
  Full installer hashes matched over the three NFS variants; NFSv4 root listing
  exposed only `tux2lab-data`.
- A second actual rebuild removed its superseded managed root. A deliberately
  failed replacement exposed Podman's inability to copy the stopped rootfs
  container's exports via `podman cp`; rollback now copies from the verified
  managed root, retaining the legacy copy path for image-backed containers.
  Repeating that failure test removed the failed root and restored the exact
  previous engine ID, root directory, export listing and NFS readiness.
- Normal stop/start retained the root and restored the original export. An actual
  reboot changed the boot ID and retained the same managed root; the engine was
  running/healthy and `tux2lab.service` reported successful automatic startup.
  Its boot journal recorded 11/11 deep checks and 6/6 dual-stack services.
  A later attempt to repeat full NFS installer reads was blocked by rejection of
  the dedicated management SSH key. The cause is not established; guest-agent
  command execution is disabled and was not enabled. Management access recovery,
  post-reboot file reads and final guest-source synchronization remain pending.
- New/changed runtime helpers and harnesses pass ShellCheck at warning severity.
  The generator, destroy, setup and deployment scripts retain only their existing
  warnings, compared against the branch baseline. Bash syntax and rootless
  regressions pass. All three setup package lists explicitly include native
  `tar` for managed-root extraction.

Guest source/config checkpoint and lifecycle logs are retained at
`/home/musubram/nfs-direct-layout-integration.hTK4zJZQ/`. This is not validation
of active-client reclaim, enforcing SELinux/AppArmor, released-baseline host-NFS
migration/rollback or parent-host PXE acceptance. Those gates remain pending.

## Cross-Distribution Host Verification

Use dedicated VMs on the existing lab as test hosts before release. Each VM runs
its distribution's own kernel, systemd, Podman and actual tux2lab installation.
The required outcome is a successfully set up and deployed lab, not merely a
manually started container or a collection of passing component tests.
Installing a distribution only as a PXE guest does not verify it as a lab host;
running a different distribution's container still shares the parent kernel.

Planned host matrix (not verified support claims):

| Family | Test-host targets | Status |
| --- | --- | --- |
| Microsoft | CBL-Mariner 2.0, Azure Linux 3.0 | Dedicated-VM acceptance pending |
| Debian-based | Debian, Ubuntu LTS | Pending |
| Enterprise RPM | AlmaLinux, Rocky Linux, RHEL where available | AlmaLinux 9.8 setup, deployment and initial lifecycle checks passed with manual prerequisites; recovery and other targets pending |
| Fedora | Fedora | Pending |
| SUSE | openSUSE Leap | Pending |

Existing Mariner results remain the baseline, not a substitute for the matrix.
Select and record exact release versions before execution. Record unavailable
targets as untested, never infer a pass from another distribution in the family.

### AlmaLinux 9.8 Host Checkpoint (October 2, 2026)

The first dedicated host was provisioned through the existing golden-image CLI
on September 29. Actual `setup/setup-host.sh --yes` completed inside the VM.
Actual deployment and the initial lifecycle checks below passed on October 2,
after the explicitly approved manual preparation. Full host acceptance is not
yet complete.

- Target: `nfs-host-alma9.musubram.internal`, AlmaLinux 9.8 (Olive Jaguar),
  kernel `5.14.0-687.42.1.el9_8.x86_64`, 2 vCPUs, 4 GiB RAM and a 60 GiB root disk.
- CPU: host-passthrough with `check='none'`; `svm` and `/dev/kvm` verified inside.
  No deeper-nested guests were created.
- Installed host software: Podman 5.8.2, libvirt 11.10.0 and QEMU 10.1.0.
- Storage: local XFS, with shared propagation for the lab-data backing mount.
- Inner network: persistent/autostart libvirt NAT network `tux2lab`, bridge
  `labbr0` at `10.10.20.1/22` and `fd60:6060:2026:1::1/64`; no management NIC
  bridged into it and no libvirt-provided DNS or DHCP.
- Source: `07a7ce345e8dcd052cc9023372c9a1ac97fedd4d`, copied into guest `/tux2lab`.
  Local image `localhost/tux2lab-engine:nfs-migration` was transferred and its ID
  verified as `648a4a32830a5b557dc5f12dd63e38586d8178b2134b06dbb2eba616e3399ce5`.
- SELinux was already Disabled in the golden image. No enforcement change was
  made; enforcing-policy compatibility remains untested. Firewalld was inactive
  during deployment checks, so enforcing host-firewall/reload coverage is also
  unverified. The container's own nftables NFS guard was active and tested.

Two manual prerequisites were required and explicitly approved:

1. **Fresh-host RPC ownership gap.** `rpcbind.service` and `rpcbind.socket` were
   enabled and active before setup package operations and remained so afterward.
   Container NFS preflight correctly refused this competing owner, but its
   suggested migration command requires an existing released lab, which this
   fresh VM lacks. After verifying no engine, guests, NFS client mounts or
   configured/active exports, the two units were stopped and masked only in the
   test VM. Preflight then passed. No fresh-host policy fix was implemented;
   subsequent deployment cannot be reported as an out-of-the-box pass.
2. **Inherited guest credential sync.** Deployment intentionally removes the
   domain-tagged provisioning key from the host's `authorized_keys`; initially
   that was the VM's only authorized key. A separate private management key,
   stored outside the parent's served lab data, was authorized only on this VM.
   Its inherited `tux2lab-sync.timer` ran every five minutes and the sync script
   replaces `authorized_keys`, so both timer and service were disabled/stopped
   after saving their state. Key-only SSH access and NFS preflight passed again.
   Neither parent SSH configuration nor production sync code was changed.

Guest evidence: `/home/musubram/nfs-host-setup.log`, RPC snapshots under
`/home/musubram/nfs-fresh-host-preparation.vz8BNKoc/`, and sync-unit snapshots under
`/home/musubram/nfs-host-sync-preparation.hSHQVFVe/`. Runtime credentials and keys
are not source artifacts. The parent checkout remains on released main, its
released engine retains its original uptime, and its NFS ownership was not
changed.

#### Deployment and Initial Lifecycle Results

- Actual `TUX2LAB_ENGINE_IMAGE=localhost/tux2lab-engine:nfs-migration tux2lab deploy`
  generated the real configuration and launched the expected image through the
  production launcher. Health reported 11/11 deep checks and 6/6 dual-stack
  service checks. The user entered credentials directly in the terminal.
- Engine inspection confirmed privileged host networking, read-only export
  binds with `rslave` data propagation, and persistent writable NFS state.
  Host NFS/RPC services remained inactive. Eight kernel NFS threads were verified
  through the container's control mount; kernel logs selected `nfsdcld` tracking
  and skipped grace because there were no clients to reclaim.
- Actual RPC registrations matched NFS 2049, rpcbind 111, mountd 20048 and lockd
  TCP 32803/UDP 32769. External probes from the parent reached SSH but received
  no RPC replies/connections on either management address for the active
  wildcard-bound rpcbind, mountd and lockd listeners. NFS guard rules matched
  the intended lab-bridge/loopback restriction.
- NFSv4.1 over IPv4/IPv6 and NFSv3 over IPv4 read the full iPXE file through the
  unchanged `:/tux2lab-data` path. A client mounted read-write still received
  `EROFS` on attempted creation, proving server-side read-only enforcement.
  Full iPXE checksums also matched over IPv4/IPv6 HTTP, trusted HTTPS and TFTP.
- Normal `tux2lab distro setup almalinux -v 9` verified the copied local ISO
  against its existing checksum file and mounted it without restarting the
  engine. ISO SHA256:
  `445f99e24399bbe98aab86111d60751c142eda049d2444fd76da5eb03472e4ab`.
  Full `images/install.img` reads matched SHA256
  `539f423b5456aa36877b255b1fd2486d86fff9bfafc34ecb83282b72a93b70a2`
  over all three NFS variants and IPv4/IPv6 HTTP/HTTPS.
- Two live ISO-helper unmount/remount cycles passed after export-cache flush.
  The file disappeared inside the container and returned HTTP 404 over both
  families while unmounted; remount restored the ISO filesystem and full
  installer checksum. Engine startup time stayed unchanged throughout.
- Normal `tux2lab stop --yes` produced graceful engine exit 143, zero NFS threads,
  no reserved RPC listeners, no NFS guard and no mounted ISO. Normal
  `tux2lab start` restored infrastructure and media, passed all health checks,
  and initialized client tracking without a recovery warning.
- Two normal rebuilds with the explicit local-image override recreated the
  engine, retained the NFS state directory, passed health, and read the complete
  installer through all three NFS variants afterward. Independent management-key
  login still worked; the published provisioning key was no longer authorized.
  Logs are in `/home/musubram/nfs-deployment-validation.MpUP51as/`.
- Normal `tux2lab enable` created/enabled the boot service; unit validation and
  starting it against the running lab passed. An actual VM reboot changed the
  boot ID and automatically restored a healthy engine, all health checks and
  the ISO mount. Full installer reads passed again over all three NFS variants;
  RPC masks, disabled inherited-sync units and management-key access survived.
  Initial SSH attempts were refused while the VM restarted. No persistent
  journal was configured, so the previous shutdown's duration and cleanup could
  not be verified from its logs. Automatic startup/data recovery passed, but
  this is not evidence of clean host-shutdown ordering or active-client reclaim.

File-protocol clients ran inside the test VM, with temporary NFS mounts isolated
and cleaned up. Management-interface firewall probes originated on the parent.
These checks do not establish real DHCP lease/RA exchanges on this deployed lab,
active-client reclaim, abrupt engine termination recovery, or migration/rollback
from a separately released baseline. Retain persistent shutdown/failure evidence
before the next recovery tests. Those checks, clean host-shutdown ordering,
enforcing security-policy coverage, other distro hosts and the separately
approved parent PXE workflow remain pending. No deeper-nested guests were created.

### Environment and Isolation

- Provision each dedicated test-host VM using tux2lab itself. After installation,
  shut it down completely and update its persistent libvirt CPU XML to
  `mode='host-passthrough'` and `check='none'`, preserving any topology settings.
  Start it again and verify virtualization exposure and usable `/dev/kvm` inside.
  Do not change existing production guest definitions.
- Parent nesting was verified on September 28: `kvm_amd` nested setting `1`,
  CPU `svm` flag and `/dev/kvm` present. This does not prove the test VM's CPU
  configuration or KVM access; `check='none'` is not a nesting enable switch.
  Budget CPU, memory and storage for test-host deployment without exhausting the
  parent lab; run targets sequentially when needed.
- Give each test host separate virtual disks and lab data on a local exportable
  filesystem. Cover ext4, XFS and Btrfs across applicable targets; do not use the
  parent's exported data tree as the test host's NFS backing store.
- Allocate non-overlapping lab networks. Keep inner DHCP and IPv6 router
  advertisements confined to the test host's private lab bridge, with no bridge
  connection to the parent lab network.
- During this stage, perform migration, reboot, fault injection and rollback
  only inside dedicated test-host VMs. Keep the parent engine, existing guests,
  NFS ownership, exports and settings unchanged, apart from adding/removing the
  explicitly approved dedicated test VMs through normal tux2lab workflows.
  Parent-host acceptance is a separate maintenance stage, not part of this setup.

### Acceptance Per Host

- On a fresh distro VM, run the normal documented host setup using
  [setup/setup-host.sh](../setup/setup-host.sh), then actual lab deployment using
  [setup/deploy-lab.sh](../setup/deploy-lab.sh). Test the migration branch and
  explicitly selected local development image, and record their exact versions.
  Do not substitute fixture configs or manually launched services for deployment.
- Verify setup installs the required packages and configures working KVM/libvirt,
  the lab bridge and networks, storage and CLI. Verify deployment generates real
  lab/service configuration and starts the engine through the normal launcher.
  Confirm operational DNS, DHCP, HTTP/HTTPS, TFTP, NTP and IPv6 RA services, health
  reporting, NFS exports and host-mounted ISO visibility.
- Exercise migration and rollback separately from fresh deployment, starting
  from a recorded released host-NFS lab installation. Check package availability,
  executable paths, systemd unit differences and restoration of the old owner.
- Exercise kernel NFS support and tracking initialization, Podman privileges,
  ISO mount propagation, persistent state and actual fixed RPC port allocation.
  Here the container uses the test VM's host network namespace, so inspect its
  real listener allocation and lockd settings, not only generated configuration.
- Check the distribution's enabled SELinux/AppArmor and firewall policies,
  including firewall reloads and dual-stack/IPv4-only configurations. Do not
  disable security enforcement to obtain a pass.
- Run normal lab start/stop/rebuild, repeated container recreation, host-VM reboot,
  interrupted migration and failure recovery, including abrupt engine PID 1
  termination. Verify durable handles and active-client reclaim using controlled
  NFS clients without creating another nested guest; retain explicit blocked
  status for checks that cannot be performed.
- Do not create or PXE-install further nested guests inside these test-host VMs:
  the user reports that this extra virtualization layer hangs in this environment.
  This exclusion does not remove any actual lab setup or deployment requirement.
  Run the full 2 GiB AlmaLinux/Ubuntu PXE workflows on the current KVM host during
  its approved acceptance window. A sibling PXE-client VM is not a required gate
  and would not establish the complete test host's KVM/provisioning workflow.
- Record distro release, kernel, Podman version, local image ID, filesystem,
  security policy, results and any blocked checks for each target.

### Coverage Boundary

After the required checks pass, claim actual lab setup/deployment, host-software
compatibility and the recorded lifecycle/recovery results on the tested distro
VMs. Claim complete KVM/PXE workflow acceptance only on the current CBL-Mariner
host after its end-to-end tests pass. Full KVM/PXE installation workflows on
other host distributions remain unverified, even when deployment succeeds.

Bare-metal hardware validation is unavailable and is not a required gate for
this matrix. Physical drivers, firmware, storage controllers and bare-metal
performance remain unverified; VM-based results are not hardware certification.
Read-only installation success does not establish writable shared storage.
These boundaries do not waive the setup, deployment, software compatibility or
recovery checks above. Setup alone and manual preparation do not satisfy the
remaining acceptance checks.

Push tested checkpoints to `origin/migration/nfs-host-to-container` and verify the
remote tip. Runtime data, VM disks, generated credentials and local image binaries
are not part of a Git backup.