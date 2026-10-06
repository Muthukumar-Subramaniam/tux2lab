# Container NFS Migration

## Status

Development implementation on `migration/nfs-host-to-container`, branched from
`main` at `0d0c7dc01395a484a98f2ef3a72f6aea0b465bf9`. The original experiment
scripts and results are backed up on origin in commit
`a3cf462a6445780c0024ec741ce22c88b160eef1`.

The live lab still uses its released engine and host NFS. Implementation and
isolated tests do not authorize a live handover, host package removal or a merge
to main. This is not yet a release-ready replacement for host NFS.
The October 3 device-bind checkpoint fixes hot-added ISO filehandle identity on
the Alma test host. October 5 adds actual deployed DHCPv4/DHCPv6 and RA acceptance
and a host dependency inventory, followed by released-baseline migration and
rollback acceptance on Alma. Current-host handover/PXE and final release gates
remain. Scoped kernel-helper tracing is complete with host packages
retained. The libvirt bridge-zone conflict is corrected on Alma with firewalld
enabled; reload/restart and real client reads pass. Permissive relabel/automatic
startup and controlled runtime SELinux enforcing tests also pass. Alma is left
permissive, not configured for enforcing boot. Shared setup/start now select the
bridge zone according to firewalld state, with Alma transition/reload/restart
acceptance complete. The bounded Alma checks are complete with the limitations
below. Ubuntu 24.04 setup/deployment, live ISO propagation, actual DHCP/RA and
full NFS reads pass with explicit native-owner preparation. Graceful active-client
recovery passes. PID1 SIGKILL leaves kernel NFS listeners on Ubuntu, but the
ownership-checked startup recovery below now passes, including missing-evidence
refusal and active-client reclaim. Ubuntu stop/start, rebuilds, verified reboot,
released-baseline migration and both rollback paths now pass. AppArmor stayed
enabled, read-only and RPC confinement checks pass, and the bounded Ubuntu stage
is complete with the limitations recorded below. No parent handover is implied.

On October 6 the user added one openSUSE Leap 16.0 representative host before
the parent handover. Its bounded setup/deployment, functional, lifecycle/reboot,
migration/rollback and default-policy checks are now complete. Only acceptance
harness changes were needed; the production runtime and image are unchanged.
This is an explicit bounded scope extension, not SUSE-family certification or
an exhaustive distribution matrix. Detailed results and limits are below.

## Maintained Code

| Owner | Responsibility |
| --- | --- |
| [container/nfs-service.sh](../container/nfs-service.sh) | Daemon supervision, readiness, persistent state, export registration and cleanup |
| [container/entrypoint.sh](../container/entrypoint.sh) | Engine-wide failure supervision and shutdown trap |
| [shared-functions/nfs-config.sh](../shared-functions/nfs-config.sh) | Export, daemon and firewall configuration |
| [shared-functions/container-nfs.sh](../shared-functions/container-nfs.sh) | Host preflight, shared data mount preparation, image compatibility, readiness and shutdown verification |
| [shared-functions/nfs-recovery.py](../shared-functions/nfs-recovery.py) | Private healthy-owner snapshots and guarded pre-start cleanup of matching orphaned kernel workers |
| [shared-functions/engine-rootfs.sh](../shared-functions/engine-rootfs.sh) | Exportable per-instance roots, image identity and guarded cleanup/rollback |
| [shared-functions/bridge-firewall.sh](../shared-functions/bridge-firewall.sh) | Conditional libvirt bridge zone, identity-preserving network preparation and bridge firewall access |
| [shared-functions/run-container.sh](../shared-functions/run-container.sh) | Mount layout, launch and replacement with retained previous engine |
| [setup/migrate-nfs-to-container.sh](../setup/migrate-nfs-to-container.sh) | Explicit host-service handover and rollback |
| [container/run-nfs-tests.sh](../container/run-nfs-tests.sh) | Rootless regression tests and isolated integration tests |
| [container/run-engine-tests.sh](../container/run-engine-tests.sh) | Complete-engine client protocols, ISO propagation and shutdown/failure checks |
| [container/run-migration-tests.sh](../container/run-migration-tests.sh) | Dedicated-host released-baseline handover, explicit/failed-handover rollback and original-engine restoration |

Deployment, start, stop, rebuild, destroy, health and busy-ISO cache flushing use
the container owner. Legacy engines are rejected before replacement or teardown.
The old host helper is retained only as migration reference; normal lifecycle
commands no longer invoke it. Host NFS packages remain installed for rollback and
native client/diagnostic helpers. The scoped helper audit below does not authorize
package removal or claim package-free operation.

The [September 17](experiments/kernel-nfs-container-2026-09-17/README.md) and
[September 24](experiments/kernel-nfs-container-2026-09-24/README.md) directories
are immutable experiment evidence, not alternate maintained implementations.
Their host-specific replay tools cover historical cold-start and PXE experiments
that have not yet been replaced by acceptance tests of the integrated engine.
Do not use those wrappers for deployment or mix them with the migration command.

## Design

- The host still supplies the kernel, NFS modules, ISO mounts and bridge.
- The privileged engine binds host `/dev` at `/dev:ro` so mountd can identify
  ISO loop devices created after engine startup. Read-only applies to the mount,
  not underlying device I/O; this is not an additional device-security boundary.
- Host networking means there can be only one kernel NFS owner in that network
  namespace. Active host daemons, RPC listeners and existing kernel exports cause
  startup to fail instead of being overwritten.
- The original layout is preserved: the host data tree is mounted directly at
  `/tux2lab-data:ro,rslave` inside the engine. It is not a symlink. Only
  `/tux2lab-data` is configured/advertised as an export, with `fsid=1`; both
  NFSv3 and NFSv4 clients continue using `:/tux2lab-data`. No `/export` tree or
  explicit `fsid=0` export is configured.
- Launch and restart prepare a dedicated shared mount at the host data path.
  If it is not already a mountpoint, a recursive self-bind preserves existing
  submounts; making that new bind recursively private before recursively shared
  gives it a separate propagation group. This avoids duplicate ISO mount events
  from aliasing a shared host root. Repeated preparation reuses an existing mount.
  Startup repeats this preparation after reboot, before starting the engine;
  no fstab entry or changed client path is required.
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
  During host shutdown, the CLI leaves libvirt service/socket teardown to systemd
  rather than waiting on later stop jobs from inside its own `ExecStop`. Normal
  interactive stop still waits for those units synchronously.
- Successful readiness records private ownership evidence beside the managed
  root, outside exported data. Before restarting a stopped engine, the host-side
  recovery helper can stop orphaned kernel workers only when the same boot,
  network namespace, engine/root/start generation, worker PIDs/start counters and
  stateless NFS firewall rules match. Native NFS/RPC ownership, unknown state,
  missing evidence or changed workers refuse recovery. The helper preserves the
  firewall and does not unmount ISOs, remove roots or change the client path.
  This is recovery at the next normal startup, not immediate SIGKILL cleanup.

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
The October 6 Ubuntu tests below reproduce this failure with native NFS tracking
and control mounts both active and inactive. The subsequent ownership-checked
startup recovery is tested on Ubuntu. A crashed engine without a matching private
ownership snapshot still requires guarded manual recovery, never automatic
adoption of whichever kernel server happens to be running.

## Remaining Acceptance Plan

The implementation now preserves the original `/tux2lab-data` layout, including
export discovery. The compatibility finding and integration results below
supersede the earlier `/export` design. Existing tests do not replace the
remaining actual lab setup, deployment or integrated PXE acceptance checks.
The release scope is bounded to AlmaLinux, Ubuntu 24.04 LTS, the explicitly
added openSUSE Leap 16.0 host, and the current CBL-Mariner KVM host, followed by
release preparation. This supersedes the
earlier expectation of completing the wider host matrix before publication.
Other host families and additional distro/version combinations move to
follow-up work, with their unverified status documented.

The remaining work follows this sequence:

1. **Finish Alma, then validate Ubuntu 24.04 LTS.** Complete the remaining
  Alma checks below. Then provision the Ubuntu test host through the existing
  tux2lab tool and run real host setup and lab deployment. Verify deployed
  services, NFS/ISO behavior, lifecycle and recovery, migration/rollback from
  a released baseline, and applicable security policies. Reuse the shared
  implementation; do not create deeper-nested guests. Alma provides
  representative RHEL-family evidence, not certification of every listed
  distro/version. Check material known differences without making an
  exhaustive Red Hat matrix a release gate.
2. **Validate openSUSE Leap 16.0.** Added with user approval on October 6 after
  Alma and Ubuntu completion. Use one dedicated test host and the same bounded
  setup/deployment, original-layout NFS/ISO, lifecycle/recovery,
  released-baseline migration/rollback and applicable security-policy checks.
  Do not create guests inside it. Other SUSE versions and SLES remain unverified.
3. **Current KVM-host end-to-end acceptance.** In a separately approved maintenance
  window on the current CBL-Mariner host, test actual NFS handover, normal
  tux2lab VM creation and unchanged 2 GiB AlmaLinux/Ubuntu NFS-backed PXE
  installations through installed-disk boot. Verify all deployed services, ISO
  propagation, start/stop/rebuild, repeated container recreation, RPC ports and
  firewall behavior, recovery and rollback. Schedule host reboot and disruptive
  fault injection explicitly within that window. Historical standalone-server
  experiments and sibling-VM protocol tests do not replace this workflow.
4. **Release preparation.** Resolve findings and rerun affected checks, record
  results and unsupported/untested configurations, and finalize cleanup and
  documentation. Complete the host executable/upcall dependency audit before
  any separately approved host NFS package removal. Keep development images
  local; build and validate the final release image, then publish it through
  the normal release workflow. Publication and merge to main require approval.

### Effort and Scope Boundaries

The following estimates are the original plan, before completed Alma/Ubuntu work
and the October 6 Leap extension. They are not a current remaining-work total;
no new completion date or Leap estimate has been committed.

| Remaining Stage | Rough Active Work |
| --- | --- |
| Finish Alma acceptance | 6-10 hours |
| Ubuntu 24.04 representative host validation | 5-8 hours |
| Approved Mariner handover, real PXE installs and rollback | 6-10 hours |
| Final review, release image, packaging and publication checks | 3-4 hours |
| **Total** | **20-32 hours** |

These are planning estimates, not a calendar schedule or guaranteed completion
time. Work proceeds as the user is available; other commitments, maintenance
windows, approvals and newly discovered defects can change elapsed time and
effort. No publication date or daily work commitment is set.

Keep the release focused on its acceptance gates and release-blocking fixes.
Rerun affected checks after fixes, but do not add unrelated improvements or
expand the test matrix without agreement. Deferred coverage is not a pass:
distinguish tested hosts from expected compatibility, and record known
limitations. The independent-client Alma reboot check remains unverified
unless an external-client setup is agreed; it must not lead to an inner VM.
Deferral does not waive the selected hosts' functional/security checks or the
current host's real provisioning and rollback acceptance.

Use [RELEASE_PROCESS.md](../RELEASE_PROCESS.md) for final validation, version
approval, publication of the tested image, clean-source tarball verification
and release notes. The user creates the GitHub release and tag after the
verified handoff. Keep development images local until the approved release
publication step.

This document update authorizes no VM provisioning, live handover, host reboot,
security-policy changes, package removal, image publication or merge. Before
execution, confirm the relevant resource budget and maintenance window with
the user. Recording the release plan does not start its next test stage.

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
  the dedicated management SSH key. The inherited golden-boot hook was later
  confirmed to have replaced authorization; management access is now repaired
  as recorded below. Guest-agent command execution remains disabled.
  Post-reboot file reads and final guest-source synchronization were completed
  in the October 3 follow-up below.
- New/changed runtime helpers and harnesses pass ShellCheck at warning severity.
  The generator, destroy, setup and deployment scripts retain only their existing
  warnings, compared against the branch baseline. Bash syntax and rootless
  regressions pass. All three setup package lists explicitly include native
  `tar` for managed-root extraction.

Guest source/config checkpoint and lifecycle logs are retained at
`/home/musubram/nfs-direct-layout-integration.hTK4zJZQ/`. This is not validation
of active-client reclaim, enforcing SELinux/AppArmor, released-baseline host-NFS
migration/rollback or parent-host PXE acceptance. Those gates remain pending.

#### Management SSH Recovery (October 2, 2026)

The golden-boot journal confirmed that `tux2lab-golden-boot.service` called
`/usr/local/bin/tux2lab-sync` directly on the subsequent boot. It started the sync
at 13:12:33 and logged `SSH authorized_keys updated` at 13:14:42, after successful
management-key logins at 13:13:03 and 13:13:31. Disabling the sync timer and service
was insufficient because this separate boot hook bypassed them. File ownership
and permissions were correct; the management key had been replaced by the
domain-tagged provisioning key.

The user restored the existing management public key through a password login.
Independent key-only login then passed. The completed golden-boot service was
disabled/stopped only on this dedicated test host, and the reintroduced
domain-tagged provisioning authorization was removed from the user's account.
Fresh key-only login verified management-only authorization, mode 600 with the
correct ownership, all three inherited sync units disabled/inactive, and engine
NFS readiness. The parent and production sync code were not changed.

Unit state, boot journal, unit definition and pre-cleanup authorization are saved
privately in `/home/musubram/nfs-ssh-repair.MU8X36Mr/` on the VM. No additional
reboot was performed during the repair; persistence across another actual reboot
and the remaining NFS acceptance checks are not claimed here.

#### Reboot and ISO Recovery (October 3, 2026)

Tracked source was synchronized to the actual AlmaLinux 9.8 host, preserving its
custom `labbr0.xml`; the rootless suite passed locally and on the VM. Persistent
journal storage was enabled on this VM using its existing `Storage=auto` setting,
so the previous boot's shutdown could be checked instead of inferred.

Two real lifecycle defects were reproduced and corrected:

- The lab `ExecStop` waited on `systemctl stop` for libvirt sockets that systemd
  orders after the lab service during shutdown. The first reboot hit the
  120-second stop timeout before ISO cleanup. The shutdown-state guard now leaves
  these later jobs to systemd. Repeated actual reboots completed lab cleanup in
  about one second or less, including ISO unmount, with successful unit
  deactivation and no timeout. This was a no-guest test host, not guest-shutdown
  or active-client recovery validation.
- A post-reboot health check passed while a full NFS installer read failed: the
  host ISO was mounted, but the container data bind was private and did not see
  it. A dedicated shared data mount restored propagation. An intermediate
  self-bind inherited the host root's shared group and duplicated ISO events;
  isolating the new bind before making it shared corrected that. The final
  reboot established different root/data shared groups, a slave container bind,
  and exactly one host ISO mount without manual mount preparation.

Final boot ID: `5f217af5-801c-49ac-ab06-4055e5745005`. Automatic startup retained
the same container ID and managed root. The management authorization and custom
network XML checksums remained unchanged; all three inherited credential-sync
units stayed disabled/inactive. The existing local image `ef259c909b57...` was
unchanged; fixes affect host lifecycle scripts, not image contents.

Full 1,264,664,576-byte installer reads matched the recorded SHA256 over
NFSv3/IPv4 and NFSv4.1/IPv4/IPv6. Read-write client mounts received read-only
filesystem errors on attempted creation. Discovery advertised only
`/tux2lab-data`, and the NFSv4 root exposed only that directory. Health passed
11/11 deep checks and 6/6 dual-stack services. A live ISO unmount/remount then
disappeared/reappeared inside the engine, preserved its PID, restored the complete
installer checksum, and left exactly one ISO mount. Isolated client mounts were
removed after testing.

New regressions cover shutdown versus ordinary CLI stop, failed system-state
queries, mount preparation failure, unsafe paths and repeated preparation.
ShellCheck, Bash syntax, editor diagnostics and whitespace checks passed for
the changed code. Evidence and pre-change backups are retained privately in
`/home/musubram/nfs-resume-20261003.8QWjGHh4/` on the VM, including failed and
successful shutdown/read logs. Parent main, released-engine uptime, NFS export,
eight threads, lockd settings and original guests remained unchanged.

Remaining gates: active-client recovery, abrupt engine PID1 failure/recovery,
actual deployed DHCPv4/DHCPv6 and RA transactions, released-host migration/rollback,
enforcing security policies, other distro hosts, and separately approved
parent-host PXE acceptance. No deeper-nested guests, parent handover, host package
removal, registry publication or merge to main occurred.

#### Active-Client and PID1 Recovery (October 3, 2026)

The deployed Alma host now has a guarded recovery harness:

```bash
bash container/run-engine-tests.sh --deployed-restart EXPECTED_HOST RELATIVE_FILE EVIDENCE_DIR
bash container/run-engine-tests.sh --deployed-crash EXPECTED_HOST RELATIVE_FILE EVIDENCE_DIR
```

These are disruptive tests for a dedicated host, not live-lab commands. They
require the exact host name, a ready direct-layout engine, no running guests,
no existing NFSv4 clients, and an existing canonical evidence directory outside
the served tree. The client uses a private mount namespace on the server host,
NFSv4.1/IPv4, a hard mount and one open read-only descriptor with direct I/O.
It verifies a one-MiB read blocks during the outage, then resumes with the same
checksum and server-side OPEN state after ordinary `tux2lab start`. This is not
a full-file checksum test, an independent-host client, or host-reboot recovery.

Observed results:

- A base-XFS ISO file recovered after graceful engine shutdown.
- An installer on an ISO device visible at engine startup recovered after both
  graceful shutdown and PID1 SIGKILL. Container identity and managed root were
  unchanged. The crash returned 137, retained the NFS firewall rules and left no
  reserved RPC listeners. A separate no-client SIGKILL probe independently
  measured zero NFS threads through a temporary private control mount. Normal
  startup recovered without manual kernel cleanup or host NFS takeover.
- The first installer restart failed with client EIO and kernel NFSv4 `ESTALE`
  (`-116`). Warm-device repeats, including a live remount, passed. Those passes
  did not resolve the original failure.
- A new loop device allocated after engine startup was absent from its private
  `/dev`, although the ISO mount and file contents propagated correctly. The
  new-device probe reproduced the failure. Before restart mountd used the
  device-derived UUID `00000701:00000000:00000000:00000000`; after restart that
  filehandle mapping was negative. The already-open file could not reclaim.
- Positive control: exposing only another new loop device node inside the
  running engine before its first NFS read made the identical test pass. Both
  cache snapshots used the ISO UUID `20260524:07153000:00000000:00000000`.
  This isolates missing hot-added block-device visibility as the cause.

**Blocker at this checkpoint (resolved below):** choose a device-visibility policy that gives
mountd stable ISO identity before any client can receive a fallback handle.
No permanent device bind, watcher, explicit child export or layout change was
introduced. Merely ordering startup ISOs earlier does not cover later distro
additions. The single `/tux2lab-data` export contract remains unchanged.

Private evidence under `/home/musubram/` on the Alma VM:
`nfs-active-recovery.sMe1s7mS` (initial failure),
`nfs-active-base-control.Wu5gh38i` (base-file pass),
`nfs-iso-handle-probe.0SGgCJpq` and `nfs-live-iso-recovery.QGX9hMNC`
(warm-device passes), `nfs-pid1-failure.wAGx6L9g` (no-client crash),
`nfs-active-pid1-recovery.TapDrMuI` (active ISO crash),
`nfs-new-loop-recovery.1CGQFEBS` (reproduced failure), and
`nfs-loop-visible-control.CMtuouk0` (positive control). The harness retains
before/after export caches, OPEN states, client errors, restart and kernel logs.
Test loop attachments and private client mounts were removed; the normal ISO
helper restored the original mount and the engine is ready. Runtime source and
image are unchanged in this checkpoint.

At this checkpoint, active ISO recovery was not accepted until the hot-add defect was fixed and
retested. Independent-client/host-reboot recovery, deployed DHCP/RA transactions,
migration/rollback, enforcing security policies and other distro hosts remain
unverified. Parent handover/PXE still requires separate approval.

#### Hot-Added Device Visibility Fix (October 3, 2026)

With user approval, the launcher now includes `-v /dev:/dev:ro`. A disposable
container first verified startup, host/device inode identity and directory-write
rejection with `EROFS`, without changing the host device mounts or live engine.
The actual Alma engine was then rebuilt through normal `tux2lab rebuild --yes`
using the existing local image. Its inspected mount is read-only and host device
mounts remained unchanged. The source image did not require rebuilding.

The missing-device failure was retested with genuinely new loop devices created
after this engine started, not reused warm devices. `/dev/loop3` became visible
automatically before the first client read, without `mknod` or engine restart.
The same open NFSv4.1 installer descriptor blocked during graceful shutdown and
recovered after normal startup. A separate new `/dev/loop4` passed the same
test with PID1 SIGKILL, including retained firewall protection and no residual
reserved RPC listeners. Before/after caches in both cases retained the real ISO
UUID `20260524:07153000:00000000:00000000`. This resolves the reproduced
hot-added-device identity failure on this host.

The existing complete-engine harness now uses the same device bind. On Alma,
its isolated fixture suite passed dual-stack DNS, HTTP/HTTPS, TFTP and NTP;
DHCPv4/v6 and RA exchanges; Kea API access; two live ISO propagation cycles with
full installer checksums; graceful exit; and retained-namespace cleanup. These
fixture exchanges do not complete the separate deployed DHCP/RA acceptance gate.

Actual deployed NFSv3/IPv4 and NFSv4.1/IPv4/IPv6 full installer reads matched
SHA256 `539f423b5456aa36877b255b1fd2486d86fff9bfafc34ecb83282b72a93b70a2`.
Read-write client mounts received server-enforced `EROFS`. Discovery advertised
only `/tux2lab-data`, and the NFSv4 root contained only that directory. Temporary
loop attachments were removed and the normal ISO helper restored `/dev/loop0`.
Evidence, pre-change launcher backup and rebuild/recovery/protocol logs are in
`/home/musubram/nfs-device-bind-validation.WH1UWipv/` on the Alma VM.

Existing development engines need a rebuild to acquire the new mount; restarting
an old container does not change its mount configuration. No explicit child
exports, alternative export paths, device-node watcher or ISO ordering workaround
was added. The engine remains privileged: a read-only `/dev` mount is not a claim
of read-only device I/O or recursively read-only child mounts. Enforcing-policy,
other-kernel/distro and independent-client host-reboot coverage remain pending.

#### Deployed DHCP and RA (October 5, 2026)

The maintained runner now shares a configuration-driven DHCP/RA client between
fixture tests and the actual deployed engine. On the dedicated Alma host:

```bash
evidence=$(mktemp -d "$HOME/nfs-deployed-dhcp.XXXXXXXX")
bash /tux2lab/container/run-engine-tests.sh \
  --deployed-dhcp nfs-host-alma9.musubram.internal "$evidence"
```

The wrapper requires the exact host name, a ready container-NFS engine, no
running guests, a canonical evidence directory outside served data, and a bridge
whose existing members are dummy interfaces only. It creates an owned network
namespace and veth pair on that bridge, waits for forwarding, and runs the client
under a timeout. It neither starts another VM nor changes engine configuration,
host firewall policy or management networking. Evidence contains only the
network/domain configuration subset and client/bridge logs, not admin secrets.

Actual deployed checks passed:

- DHCPv4 Discover/Offer/Request/ACK with an address inside the configured pool,
  subnet mask, gateway, DNS, domain/search, next-server and `ipxe.efi` boot file.
- DHCPv6 Solicit/Advertise/Request/Reply with an address inside the generated
  pool, matching client/server identities, DNS, domain and IPv6 TFTP boot URL.
- Solicited RA with managed/other-configuration flags, the configured prefix,
  on-link enabled, autonomous addressing disabled, RDNSS and DNSSL.

Both leases were released. Independent inspection of the latest Kea CSV records
confirmed `valid_lifetime=0`; server logs also confirmed successful releases.
Records later reached state `2`, but requiring that later state immediately
after the client exits produced an overly strict verification failure. Release
verification must not depend on that subsequent state transition.
Temporary namespaces, veths
and scratch directories were removed. The deployed engine ID/PID remained
unchanged and NFS readiness passed. This is a same-kernel protocol client, not an
independent machine or a host-reboot recovery test.

Initial failures were in the harness, not evidence of a Kea defect. The real
bridge uses STP, so a new port must reach forwarding before sending requests.
Waiting for that transition alone did not fix DHCPv4: a bounded packet capture
then showed a valid Offer on the bridge which the unconfigured-interface UDP
receiver missed. DHCPv4 reception now uses an interface-bound packet socket and
validates UDP ports, transaction ID, MAC and DHCP cookie. No server or firewall
change was needed. The shared client also passed the final isolated full-engine
startup/protocol/shutdown suite with the direct-layout image.

Rootless regressions cover failed and occupied guest/process inspections: neither
may be mistaken for an empty list authorizing setup or cleanup. If client process
inspection fails or processes remain, cleanup fails and retains the owned
namespace for inspection. Bash syntax and warning-level ShellCheck passed.

Evidence is retained on Alma under
`/home/musubram/nfs-dhcp-validation.oCj1clnD/`: initial attempts, packet capture,
successful `deployed-packet-client/` and `deployed-final/` runs, final fixture log,
health and lease cleanup logs.
Raw logs are local evidence; the maintained harness and this runbook are the
Git-backed recovery material. No image was built or published for this change.

#### Host Dependency Inventory (October 5, 2026)

Alma still has `nfs-utils-2.5.4-42.el9_8` and `rpcbind-1.2.6-7.el9` installed.
Native NFS server/mountd units are inactive; rpcbind service/socket are inactive
and masked. SELinux remains disabled and firewalld inactive. No package or
security-policy changes were made.

The owning code and installed executable inventory establish these boundaries:

- The engine runs its own `rpcbind`, `rpc.mountd`, `rpc.nfsd`, `exportfs` and
  `nfsdcld`. The host still supplies the kernel/modules, systemd, Podman, tar and
  mount/network namespace tooling.
- Native host `exportfs` remains required by released-host migration snapshots
  and rollback. Native `mount.nfs`, `showmount` and `rpcinfo` are used by host-side
  client validation and diagnostics, not proof of host-owned serving daemons.
- Host `request-key` and `nfsidmap` are present. This inventory does not trace
  kernel upcalls or prove those helpers unused. Package-free serving and host
  NFS package removal remain unverified and unapproved.

Retain the host packages. The fresh-host RPC conflict and its explicitly approved
manual preparation remain documented below; no automatic policy fix was added.
Inventory evidence is in `host-dependencies.log` in the same evidence directory.

#### Released-Baseline Migration and Rollback (October 5, 2026)

With explicit approval for the dedicated Alma VM only, the acceptance runner
preserved the existing container and its managed root, stopped it cleanly, and
renamed it to `tux2lab-engine-acceptance-original`. It saved host NFS configuration,
unit states, lockd settings, native NFS state files and the stopped engine's
persistent NFS directory outside served data. No host packages or security policy
were changed, and no additional VM was created.

The temporary baseline used the released source at
`0d0c7dc01395a484a98f2ef3a72f6aea0b465bf9`, its actual container launcher and native
host-NFS helper, and the released 2.1.1 image with ID
`555c91f1cb895749bb28f88eec3ade896fc7debe165b7e3bfb8bdc6f01d5f3da`.
The image was transferred from the parent's existing local image store, not
rebuilt or published. The migration checkout and CLI link remained in place;
the archived released helpers were sourced only for baseline preparation.

The following real operations passed:

1. Verify the released engine and host-NFS baseline, sole `/tux2lab-data` export,
  and full installer checksums over NFSv3/IPv4 and NFSv4.1/IPv4/IPv6.
2. Run the maintained migration script's `--check` and `--apply`, then verify
  container NFS readiness and the same three full installer reads.
3. Run `--rollback`; verify the same released engine ID, exact host export and
  unit-state snapshots, lockd settings, and full installer reads.
4. Inject a handover failure immediately after the real candidate engine becomes
  ready. The migration EXIT trap removed that candidate and restored the released
  baseline; identity, unit/export/settings comparisons and all three reads passed.
5. Remove only the temporary released engine, restore original host settings and
  saved NFS files, and restart the original container-NFS engine. Its original ID
  and managed root were retained; all three full installer reads passed again.

The runner does not replace production migration logic with a mock. Fault
injection wraps the real launcher and returns failure after successful readiness.
This establishes rollback from that specific post-launch failure, not arbitrary
power loss, every partial snapshot failure, active-client reclaim or host reboot.
Earlier rootless tests retain coverage of other guarded failure paths.

For a separately approved dedicated-host replay, first stage a released source
archive under `EVIDENCE/released-source` and both local images, then run:

```bash
sudo bash /tux2lab/container/run-migration-tests.sh --run \
  nfs-host-alma9.musubram.internal "$evidence" \
  ghcr.io/muthukumar-subramaniam/tux2lab-engine:2.1.1 \
  localhost/tux2lab-engine:nfs-direct-layout
```

`$evidence` must be an existing canonical private directory matching
`/home/*/nfs-migration-validation.*`, outside served data. The runner refuses
existing checkpoints, guests, additional containers or NFS clients, and retains
the saved original engine until restoration. EXIT/signal cleanup attempts
restoration and fails closed on unknown ownership. Recovery can be retried with
`--restore EXPECTED_HOST EVIDENCE`; do not delete the saved engine or evidence
after an incomplete restoration. A rootless regression verifies rejection of an
unexpected saved engine ID before mutation.

Observed limitations: the unmodified released 2.1.1 entrypoint has no SIGTERM
shutdown trap, so Podman used its 30-second timeout and SIGKILL fallback when
stopping that temporary baseline. Migration and rollback still succeeded. This
is not a graceful-stop claim for the released engine. Systemd also emitted a
reload warning after masking the native NFS unit; subsequent owner, unit-state
and protocol checks passed. These warnings remain in the evidence.

Final Alma health passed 11/11 checks and 6/6 dual-stack services. Only the
original engine and `engine.YFAhvSFQ` root remain; there is no active migration
checkpoint or temporary client mount directory. Custom network XML and disabled
management-sync hooks are unchanged. SELinux remains disabled and firewalld
inactive. Kernel logs selected `nfsdcld` tracking on each native/container start,
but do not establish package-free or kernel-helper independence.

Evidence and recovery archives remain in
`/home/musubram/nfs-migration-validation.J81WMsMw/` on Alma, including stage read
logs, `apply.log`, `rollback.log`, `injected-failure.log`, `final-health.log` and
`kernel-tracking.log`. Completed migration snapshots remain archived under
`/var/lib/tux2lab/nfs-migration-restored-*`. No parent NFS handover, image publication
or main merge was performed.

#### Firewalld Reload Finding (October 5, 2026)

The engine runner now provides guarded `--deployed-firewall EXPECTED_HOST
EVIDENCE_DIR start|reload|restart|restore` phases. Tests require root, the exact
dedicated host, no running guests, and a bridge with only dummy members. Start
requires firewalld inactive/disabled, public as the default zone, and SSH already
allowed there. Original configuration is archived outside served data; a local
15-minute systemd timer can restore it even if management SSH is lost. Failure
cleanup restores the configuration, verifies engine readiness and cancels the
timer. The separate `--restore-deployed-firewall EVIDENCE_DIR` mode supports retry.

`--deployed-network EXPECTED_HOST EVIDENCE_DIR` extends the existing temporary
bridge client with full installer reads over NFSv3/IPv4 and NFSv4.1/IPv4/IPv6.
It retains the test IPv4 address after releasing the lease and uses the reserved
IPv6 prefix address `::2` for NFS; it does not claim DHCPv6 address configuration.
Its no-guests/dummy-only-bridge guard excludes competing attached lab clients.
Client mounts use a private mount namespace and all temporary links/namespaces
are removed. No further VM or nested virtualization is involved.

Both the firewall-off baseline and firewalld-start stage passed real bridge
DHCPv4/v6, RA and all three full NFS checksums. Start used the existing
`open_bridge_firewall` helper, which assigned `labbr0` to `trusted` in permanent
and runtime configuration. A fresh management SSH connection also succeeded.

**Reload failed acceptance.** `firewall-cmd --reload` succeeded, but libvirt moved
`labbr0` from `trusted` to `libvirt`; `eth0` remained in `public`. The saved
permanent trusted-zone XML still contained `labbr0`, so this was not a missing
permanent setting. A second guarded run reproduced the runtime reassignment.
The NFS rules/readiness remained intact, but the required bridge policy did not.
Restart acceptance was not reached. Both failures restored firewalld to its
original inactive/disabled state and retained the original engine.

The libvirt network has `<bridge name='labbr0'/>` without a zone attribute.
[Libvirt's network format](https://libvirt.org/formatnetwork.html#connectivity)
documents `libvirt` as the default zone for NAT networks and an explicit bridge
`zone` attribute since 5.1.0. The proposed correction is `zone='trusted'` in the
owning network definition, consistent with the project's existing bridge policy.
At that checkpoint it had not been applied or validated: changing the preserved
custom XML and possibly restarting the inner lab network required explicit
approval. The subsequent approved results below preserve addresses, UUID, MAC
and the original NFS data layout.

Evidence on Alma: `/home/musubram/nfs-firewall-validation.qmpHJZpb/` contains the
baseline, start-client results and first reload failure; the diagnostic repeat is
in `/home/musubram/nfs-firewall-validation.QQHWEtmA/`. Archives and
`firewalld-tested/` preserve original/tested configuration. No recovery timers
remain active. No production firewall helper or network XML was edited.

SELinux inspection found both `SELINUX=disabled` and kernel argument `selinux=0`.
Policies/tools are installed, but `setenforce` alone cannot enable this boot.
Enforcing acceptance requires backed-up boot/config changes, a permissive
relabel boot and then controlled enforcing tests. None of those changes or a
host reboot was performed in this checkpoint.

#### Approved Zone Correction and Relabel Preparation (October 5, 2026)

The user approved changing Alma's custom bridge zone and preparing SELinux through
a permissive relabel boot. Only `zone='trusted'` was added to both the custom
source XML and existing libvirt definition. Structural comparison verified that
all other XML content, including UUID, MAC and addresses, was preserved.

The first network restart exposed an additional requirement: libvirt rejects an
explicit zone when firewalld is inactive (`zone trusted requested ... but
firewalld is not active`). The guarded procedure restored the original definition
and healthy lab. The attempted unconditional change to the general template was
therefore discarded. The shared template remains zone-free for hosts that do not
run firewalld; an explicit zone is a documented prerequisite for a firewalld-managed
lab network, not a new mandatory firewalld dependency on every host.

With firewalld active, the corrected Alma network started normally. Fresh SSH,
DHCPv4/v6, RA and full NFSv3/IPv4 and NFSv4.1/IPv4/IPv6 installer reads passed
before reload, after reload and after firewalld restart. `labbr0` remained trusted,
`eth0` remained public, and exact NFS rule readiness passed throughout. No runtime
zone reapplication was needed after reload/restart.

Firewalld is now enabled on Alma so the explicit-zone network can start after
reboot. Its test recovery timer was cancelled. When returning this host to a
firewalld-disabled configuration, restore the original zone-free network
definition/source before the next network start; stopping firewalld alone is
not sufficient. Network rollback files are in
`/home/musubram/nfs-zone-validation.pVYxYMWk/`; successful firewall results are in
`/home/musubram/nfs-firewall-validation.j71XJThp/`.

SELinux recovery files are in
`/home/musubram/nfs-selinux-validation.YcdsXLVV/`: original configuration, default
GRUB settings, BLS entries, grubenv, kernel cmdline, boot/engine IDs and the inherited
empty `/.autorelabel` marker. Only the default kernel entry was changed from
`selinux=0` to `enforcing=0`; the rescue entry is unchanged. `/etc/selinux/config`
is now permissive, root-owned mode 644. `fixfiles -F onboot` scheduled the forced
relabel. The running kernel is still SELinux-disabled until reboot. GRUB defaults
and `/etc/kernel/cmdline` retain their original values pending final policy setup.
This is a recovery checkpoint before the approved reboot, not an enforcing pass.

#### Permissive Boot and Enforcing Acceptance (October 5, 2026)

The approved reboot completed the forced relabel, followed by the distribution's
automatic second reboot. The final boot ID is
`d13ff33f-2dea-43bf-973e-c9f0d6513401`. SELinux loaded in permissive mode,
`/.autorelabel` was consumed, management-key labels matched policy, and all three
inherited credential-sync hooks stayed disabled/inactive. No units were failed.
Firewalld started before libvirtd in this boot; the explicit-zone network and
original engine started automatically. This observes successful ordering on this
host, not a new explicit systemd ordering dependency or a guarantee on all hosts.

The relabel log reports skipped read-only systemd credential mounts, no default
label for `/dev/mqueue`, and a bus warning plus service termination during its
own reboot. The installed autorelabel script invokes `systemctl reboot` after
removing the marker. Subsequent boot, label checks and the enforcing workload
passed; the warnings remain in the evidence rather than being treated as absent.

A local 15-minute systemd timer was armed to run `/usr/sbin/setenforce 0` before
entering runtime enforcing mode. With host enforcement continuously active for
each workload, the following passed:

- Fresh key-only management SSH, actual bridge DHCPv4/v6 and RA, and full installer
  checksums over NFSv3/IPv4 and NFSv4.1/IPv4/IPv6.
- A freshly created isolated engine using the maintained `--run` test, all
  protocol/control-agent checks, two live ISO mount/unmount cycles with full NFS
  and HTTP/HTTPS reads, graceful shutdown and retained-namespace cleanup.
- Deployed-engine restart with the same open NFSv4.1 file descriptor: its uncached
  1 MiB read blocked while stopped, then resumed with the expected checksum and
  recovered server OPEN state. Original container ID and managed root remained.
- Firewalld restart, trusted bridge and exact NFS rules, another full deployed
  DHCP/RA/NFS client pass, and a fresh management SSH connection afterward.

Two test-harness issues were addressed without production policy changes. The
nonprivileged fixture generator initially ran as `container_t` and could not read
the host checkout's `default_t` script. Only that disposable generator now uses
`--security-opt label=disable`, consistent with the existing privileged engine's
labeling policy; the checkout is not relabeled and host enforcement stays on.
This tests compatibility of the existing privileged design, not strong container
confinement. The deployed engine's user-space NFS daemons ran as
`container_runtime_t`, with kernel threads as `kernel_t`.

The deployed recovery test was initially invoked as root, but its normal startup
CLI rejects root. The engine was restored through the normal user CLI. The runner
now rejects root before mutation; an actual rejection check preserved its ID/PID,
and the full recovery test then passed as the sudo-capable `musubram` user. Run
`--deployed-restart` and `--deployed-crash` without prefixing the runner with sudo.

Audit collection uses `ausearch --input-logs` with stdin detached; otherwise an
SSH-stdin script can be consumed as audit input. The final boot-wide audit contains
one enforcing denial, from the original fixture-generator attempt, and none from
the production workloads or corrected fixture. No custom allow rules, booleans,
package removals or production container security options were introduced.

Final Alma state: runtime and `/etc/selinux/config` are permissive. The default
kernel entry, `/etc/default/grub` and `/etc/kernel/cmdline` use `enforcing=0`
instead of `selinux=0`; the rescue BLS entry is byte-identical to its backup.
Firewalld remains enabled/active and the bridge explicitly trusted. The SELinux
recovery timer was cancelled. Only the original engine/root remains, no test
namespaces or recovery-client directories remain, and health passes 11/11 plus
6/6. This does not claim enforcing-mode host boot, independent-client host-reboot
recovery, package-free operation or confined-container security.

All boot/config backups and test logs remain under
`/home/musubram/nfs-selinux-validation.YcdsXLVV/`, including `relabel.log`,
`permissive-boot.log`, `enforcing-fixture-fixed.log`, `enforcing-restart-user/`,
`enforcing-firewall-client/`, `enforcing-final-audit.log` and `final-health.log`.
The parent lab was not rebooted or migrated; no nested VM or image publication
was involved. Shared network integration was still pending at this checkpoint;
the following approved implementation closes that gap.

#### Conditional Network Integration (October 5, 2026)

With approval to change shared setup, `ensure_bridge_network` in
`shared-functions/bridge-firewall.sh` now owns lab network preparation for both
`setup/setup-host.sh` and normal `tux2lab start`:

- Active firewalld selects `zone='trusted'`. Inactive, absent or failed firewalld
  selects no explicit zone, avoiding libvirt's active-firewalld requirement.
  Failed state queries and transitional/unknown service states stop preparation.
- Existing persistent libvirt XML is authoritative. The helper changes only the
  managed bridge-zone attribute, preserving UUID, MAC, addresses and other network
  settings. The source XML is used only for a missing network and is never edited.
  Rerunning setup no longer destroys/undefines the lab network to replace it from
  the template. Intentional address/topology changes require a separate controlled
  libvirt configuration change, not just a source-template edit.
- An active zone-free network cannot safely receive the zone change live. The
  helper prepares its persistent trusted zone, returns failure with a maintenance
  message, and leaves live XML and the running engine unchanged. After draining
  clients/stopping guests as appropriate, normal `tux2lab stop` and `tux2lab start`
  apply the saved change. Merely retrying start still reports restart required.
- No live network is automatically destroyed or restarted. Transient networks,
  custom non-trusted zones, mismatched names/bridges and invalid XML are rejected.
  Libvirt query/define/start/autostart failures propagate instead of being hidden.
  Persistent lookup uses `net-list --all --persistent` so stopped networks retain
  their identity. Python's standard-library XML parser adds no package dependency.

Actual Alma validation used the same original engine and custom source XML:

1. Already-correct active startup preserved live/persistent XML byte-for-byte and
   left engine ID/PID unchanged.
2. Normal lab stop, firewalld stop, and normal start removed only the zone from
   persistent and live definitions. DHCPv4/v6, RA and full installer checksums over
   NFSv3/IPv4 and NFSv4.1/IPv4/IPv6 passed with firewalld inactive.
3. Starting firewalld and invoking normal lab startup staged the persistent zone
   and returned the expected maintenance error, without altering live XML or
   engine ID/PID. Normal stop/start then adopted the trusted zone; both XML forms
   matched their original saved versions and the source file stayed unchanged.
4. The original firewall configuration was restored, then reload and restart each
   passed bridge-zone/SSH allowance/exact NFS rules and real DHCP/RA/full NFS reads.
   Fresh management SSH was also checked after the final restart.

An initial identity assertion incorrectly compared live XML against persistent
XML. Libvirt synthesizes a NAT port range in the live form; comparing each form
against its own saved baseline confirmed that only the zone changed. That test's
direct network recovery also detached the existing dummy interface; the verified
dummy was reattached and healthy startup restored. The successful repeat used
normal lab shutdown for recovery. The production helper never destroys the bridge
and does not require this manual attachment step.

Rootless tests cover fresh/absent-firewall paths, existing/staged networks,
identity preservation, custom/invalid input, state-query failures and libvirt
failure propagation. An actually package-absent host was not provisioned or tested;
its systemd inactive response is covered without removing packages. The full host
setup script was not rerun, avoiding unrelated package/host changes; its shared
network helper was exercised through real startup and the rootless tests. Syntax,
editor and regression checks passed. ShellCheck has no new diagnostics; setup's
two existing package-log redirection warnings match its committed baseline.

Evidence and backups are under `/home/musubram/nfs-zone-integration.yfw6UyNa/`,
including original source scripts/network/firewall, idempotent startup,
`inactive-client-final/`, `live-transition-final.log`, final active network XML,
and `reload-client/`/`restart-client/`. No image, source template, package, parent
runtime or SELinux boot policy changed. Alma remains permissive with firewalld
active/enabled; NFS serving ownership remains in the original candidate engine.

#### Scoped Kernel-Helper Audit (October 5, 2026)

`sudo bash container/run-engine-tests.sh --deployed-helpers EXPECTED_HOST
EVIDENCE_DIR` uses an owned tracefs instance to observe
`call_usermodehelper_setup`, `call_usermodehelper_exec`, module requests and
selected executable filenames. It records no command arguments or environment.
An isolated session-keyring request using the existing `debug:*` negate rule
provided a positive control: both kernel helper calls and execution of native
`/sbin/request-key` were captured. No key configuration was modified.

The subsequent workload restarted the actual Alma engine, then ran DHCP/RA and
full installer reads from the bridge client. All checks passed. The 18-event
workload trace had no buffer overruns and showed:

- NFS startup/shutdown executables, with `nfsdcld` and `rpc.mountd` PIDs matched
  to the running engine's host-PID listing.
- Native client `mount.nfs`, `umount.nfs` and `umount.nfs4` executions.
- Native `/usr/libexec/nfsrahead`, owned by host `nfs-utils`, invoked through
  the existing `99-nfs.rules` udev rule for client backing-device events.
- No kernel usermode-helper calls, module requests, `request-key` or `nfsidmap`
  execution during this workload, distinct from the successful positive control.

This completes the scoped executable/upcall observation with packages retained.
It is not proof that host helpers are never needed: NFS modules were already
loaded, AUTH_SYS name mapping was disabled (`nfs4_disable_idmapping=Y`), and
neither cold module loading nor Kerberos/named-idmapping workloads were tested.
Native utilities remain needed by migration/rollback and host-side diagnostics;
package removal is still unverified and unapproved.

Evidence: `/home/musubram/nfs-helper-validation.3zyyxeJC/`, including the positive
control, workload trace, buffer statistics, daemon PID mapping, bridge-client logs
and final health. The private trace instance was removed; global tracing stayed
at `nop` with its original enabled state. The same engine/root is running,
health passed 11/11 and 6/6, and custom network XML remained byte-identical.

## Cross-Distribution Host Verification

Use AlmaLinux, Ubuntu 24.04 LTS and openSUSE Leap 16.0 as dedicated representative
test hosts before release, followed by acceptance on the existing CBL-Mariner KVM host. Each test
VM runs its own kernel, systemd, Podman and actual tux2lab installation.
The required outcome is a successfully set up and deployed lab, not merely a
manually started container or a collection of passing component tests.
Installing a distribution only as a PXE guest does not verify it as a lab host;
running a different distribution's container still shares the parent kernel.

Release and follow-up host matrix (not verified support claims):

| Family | Test-host targets | Status |
| --- | --- | --- |
| Enterprise RPM | AlmaLinux 9.8 | Release gate: setup/deployment, lifecycle and same-host-client engine recovery passed with manual prerequisites; remaining Alma gates below |
| Debian-based | Ubuntu 24.04 LTS | Bounded representative stage complete: setup/deployment, ISO, DHCP/RA, reads, lifecycle/reboot, recorded-owner recovery, migration/rollback and default-policy checks; limitations below |
| Microsoft | Current CBL-Mariner 2.0 KVM host | Release gate: approved end-to-end handover/PXE/rollback acceptance pending |
| Enterprise RPM | Rocky Linux, Oracle Linux, CentOS Stream, RHEL and additional Alma versions | Expected compatibility through the shared implementation; individually unverified, no exhaustive matrix gate |
| Debian-based | Debian and additional Ubuntu releases | Follow-up validation; unverified |
| Microsoft | Azure Linux 3.0 | Follow-up validation; unverified |
| Fedora | Fedora | Follow-up validation; unverified |
| SUSE | openSUSE Leap 16.0 | Bounded representative stage complete: actual setup/deployment, ISO, DHCP/RA, reads, lifecycle/reboot, engine recovery, migration/rollback and default-policy checks; limitations below |
| SUSE | Other Leap releases and SLES | Follow-up validation; unverified |

Existing Mariner results remain the baseline, not a substitute for its release
acceptance. Record exact versions and environments when executing a test.
Representative coverage supports an expectation of compatibility, never a
claim that an untested distro/version passed. Follow-up rows are not additional
pre-publication gates unless a material finding changes the agreed scope.

### openSUSE Leap 16.0 Host Preparation (October 6, 2026)

The user approved adding the available Leap 16.0 image before the separately
approved live Mariner handover. Provisioned through the released parent CLI:

```bash
tux2lab vm install --via-golden -H nfs-host-suse16 \
  -d opensuse-leap -v 16.0 --dual-stack --cpu 2 --memory 4 --root-disk-size 60
```

- Host: `nfs-host-suse16.musubram.internal`, openSUSE Leap 16.0, kernel
  `6.12.0-160000.37-default`, XFS root `/dev/vda2`, 2 vCPU, 4 GiB RAM, 60 GiB disk.
  VM UUID `995707a7-521f-467b-ae96-7f3568ff46a1`, MAC `52:54:00:f3:6a:3c`.
  Management addresses: `10.28.28.16` and `fd28:2808:2020:3000::10`.
- Golden boot completed successfully. Backed up management authorization and
  hook state, then disabled/stopped `tux2lab-sync.timer`, `tux2lab-sync.service`
  and `tux2lab-golden-boot.service` only inside this test VM. Installed and
  independently verified a dedicated Ed25519 management key outside served data,
  with comment `tux2lab-nfs-validation-management-suse16`. Parent SSH config was
  not changed. The key and private backup contents are not committed.
- Gracefully shut down the VM, changed only CPU mode/check to
  `host-passthrough`/`none`, compared XML structurally and defined it with
  `virsh define --validate` only while fully off. Restart preserved dedicated
  SSH and disabled hooks. Verified `svm`, `/dev/kvm` and KVM API version 12;
  no nested guest was created. The inherited libosinfo metadata was left alone.
- Staged source `cf535cf8f9158ba7cdf5783c9d8164654032590f` without changing the
  parent checkout. The minimal guest lacked `tar`, so installed it with native
  zypper before extracting the source; zypper also selected `tar-rmt`.
- Guest-only network input keeps the existing `tux2lab`/`labbr0` NAT topology,
  no libvirt DNS/DHCP, no physical bridge member and no forced firewall zone.
  Separate inner networks are `10.10.28.0/22` (gateway `10.10.28.1`) and
  `fd60:6060:2026:3::/64` (gateway `::1`). Subnets were checked against the parent,
  Alma and Ubuntu networks. Generated network UUID is
  `7e7178c3-88bb-42f5-98d9-d2a7ce537b22`, bridge MAC `52:54:00:d8:5a:d4`.
- Actual `bash /tux2lab/setup/setup-host.sh --yes` passed unchanged, including
  packages, libvirt, bridge/dummy interface, CLI and completion. This is a real
  host setup pass, not yet a deployed-engine acceptance claim.
- Installed Podman `5.4.2-160000.5.1`, libvirt `11.4.0-160000.6.1`, QEMU
  `10.0.13-160000.1.1`, nfs-kernel-server `2.8.2-160000.4.1`, rpcbind
  `1.2.9-160000.1.1`, libosinfo `1.12.0-160000.3.2`, AppArmor parser
  `4.1.7-160000.2.1`. Zypper resolves `qemu-kvm` and `nfs-utils` to the QEMU and
  NFS server providers; `rpm -q` on those virtual names alone is not an install
  failure. The previously unverified `libosinfo` package resolves on this host.
- Unlike the other prepared hosts, native NFS/RPC services and socket remained
  inactive after setup, with server/rpcbind disabled and dependent units static.
  Host preflight passed without manually stopping or masking native units.
  No exports, NFS listeners, containers or running inner guests were present.
- AppArmor service is active/enabled and its kernel parameter reports `Y`.
  Firewalld is installed but inactive/disabled. No policy was disabled to pass
  setup; actual workload under applicable policy is still pending.
- Transferred the existing local image
  `localhost/tux2lab-engine:nfs-direct-layout`, exact ID
  `ef259c909b57cb4fd05695b27d928c1c1a1c1fd0e19c824789997f0303ac4eb6`.
  Both NFS layout labels and native preflight pass. No new image was built or
  published, and host packages remain installed.

Guest evidence is `/home/musubram/nfs-host-preparation.u9Dj8OfH/`, including
original authorization/hook state, before/after native units, security baseline,
setup log, private network definition and input hashes. Local original/staged
domain XML and guest-only network input live under untracked `.test-artifacts/`.
Do not commit these runtime artifacts, keys or VM disks.

After preparation, actual interactive deployment was run with the dedicated
management key:

```bash
ssh -tt -F /dev/null -i "$HOME/.ssh/tux2lab-nfs-host-suse16_ed25519" \
  -o IdentitiesOnly=yes -o IdentityAgent=none -o BatchMode=yes \
  -o StrictHostKeyChecking=yes musubram@nfs-host-suse16.musubram.internal \
  'TUX2LAB_ENGINE_IMAGE=localhost/tux2lab-engine:nfs-direct-layout tux2lab deploy'
```

The user entered the lab password directly in the terminal, never through chat
or model tools. Deployment completed successfully with health 11/11 and all six
dual-stack service checks passing. The parent continues to use released 2.1.1 and host NFS;
its seven Kubernetes guests remain running. At the final preparation check,
Alma and Ubuntu are both off; no Ubuntu lifecycle command was run during this
SUSE preparation. Leave those retained hosts in their observed states.

#### Leap Deployment and Acceptance Completion (October 6, 2026)

All workload ran on the dedicated Leap kernel/runtime. No further VM was
created inside it, no host policy was disabled, and no NFS packages were removed.
The existing direct-layout image remained unchanged throughout.

Deployed behavior and recovery:

- Dedicated key-only SSH survived deployment and reboot, with all three
  inherited credential hooks still disabled/inactive. Host/container
  `/tux2lab-data` remained real directories, not symlinks.
- Copied the same known-checksum AlmaLinux 9 boot ISO used on the other hosts
  and ran normal `tux2lab distro setup almalinux -v 9`. The new mount propagated
  into the already-running engine with unchanged ID/root/PID/start time. The
  complete installer checksum matched
  `539f423b5456aa36877b255b1fd2486d86fff9bfafc34ecb83282b72a93b70a2`.
  This is installer media served by SUSE, not a nested guest installation.
- Actual DHCPv4/v6 leases, pool/options/PXE/DNS/domain checks and RA managed
  flags/prefix/DNS passed. Full installer reads passed over NFSv3/IPv4 and
  NFSv4.1/IPv4/IPv6 without restarting the engine.
- The initial network harness could not execute `bridge`: Leap's non-root PATH
  omits `/usr/sbin`, where it is installed. The maintained test now reads bridge
  port forwarding state from the already-required `ip -d -j link` JSON.
  Immediate rerun passed listening/learning/forwarding and all real clients.
  Host PATH, privileges and production networking were not changed.
- Graceful engine restart and PID1 SIGKILL both passed same-open-descriptor
  NFSv4.1 recovery against `images/install.img`, including blocked uncached read
  during outage, matching first-MiB checksum and restored server OPEN state.
  SIGKILL exited 137 and retained firewall protection. The guarded recovery
  helper returned without needing worker cleanup on this run; this is not a new
  live-orphan-adoption test. Ubuntu's earlier recorded-owner tests remain the
  actual evidence for that branch.
- Full CLI stop/start verified exit 143, NFS/listener shutdown, ISO unmount and
  remount, with the same engine/root. Two actual rebuilds each replaced the
  engine/root, removed the previous managed instance after readiness, and
  preserved network/configuration/SSH hashes. Full installer reads passed again.
- Enabled the normal lab boot unit and persistent journal storage. Actual host
  reboot passed previous-boot ISO cleanup, successful lab shutdown/unit
  deactivation and automatic startup. Boot ID is
  `9a7de568-8c13-49d0-9d35-17ca9571e866`; system state is running. Engine/root and
  network/configuration/SSH identity were retained, and full DHCP/RA/NFS reads
  passed again after boot. No independent client was carried across host reboot.
- Unit validation succeeded but reported distribution-provided Plymouth
  warnings for deprecated `KillMode=none` and a non-absolute condition containing
  an unexpanded variable. No Plymouth files were changed. These warnings did
  not prevent the observed clean shutdown/startup.

Migration and rollback:

- Used exact released source `0d0c7dc01395a484a98f2ef3a72f6aea0b465bf9` and the
  local released 2.1.1 image, retaining the rebuilt candidate as the original
  restoration target. The parent checkout/runtime was not switched.
- Leap initially has `/usr/etc/nfs.conf`, not `/etc/nfs.conf`. Before mutation,
  the acceptance harness was extended to preserve that absence. It records the
  baseline-created local file and removes it during original restoration only
  if it is still a regular, non-symlinked, byte-identical file. Changed contents
  or a symlink block cleanup; focused regressions cover both refusal cases,
  matching-file cleanup and already-absent state.
- The actual cycle passed released host-NFS baseline, migration apply, explicit
  rollback, injected rejection after the real candidate became ready, automatic
  rollback and final original-engine restoration. All five service states passed
  full installer hashes over the three accepted protocol/address combinations,
  15 complete reads. Both rollback paths restored released engine identity,
  exports, native unit states and lockd settings.
- Final restoration retained the original candidate/root, restored native
  service/configuration state, removed the temporary local `/etc/nfs.conf`, and
  left both migration/acceptance locks available. No active migration checkpoint
  or temporary baseline engine remains. Host packages stay installed.

Policy and layout:

- AppArmor stayed active/enabled with kernel parameter `Y`, 155 loaded profiles
  and 75 enforcing profiles at final inspection. There were no
  `apparmor="DENIED"` records in the test boot. The privileged engine's AppArmor
  profile is empty; this is host-policy compatibility, not strong confinement.
- Firewalld remains installed but inactive/disabled, so no enabled-firewall
  reload/restart claim is made. The NFS nftables guard is present. External
  management IPv4/IPv6 TCP probes to 111/2049/20048/32803 and UDP NULL RPC probes
  to 111/20048/32769 were inaccessible while SSH positive controls succeeded.
- Server EROFS was verified using `rw` client mounts over NFSv3/IPv4 and
  NFSv4.1/IPv4/IPv6. Only `/tux2lab-data` was advertised, and only `tux2lab-data`
  appeared at the NFSv4 root. The existing data/export layout is unchanged.

Private guest evidence:

- `/home/musubram/nfs-suse-deployment.OyUzTlz1/`: original engine, deployment
  health, network/configuration hashes and normal ISO setup.
- `/home/musubram/nfs-suse-network.26xL9qg7/`: initial PATH-related harness failure.
- `/home/musubram/nfs-suse-network.JkFxcY22/`: corrected real DHCP/RA/NFS checks.
- `/home/musubram/nfs-suse-restart.Jm144WJg/` and
  `/home/musubram/nfs-suse-crash.uSQveLLV/`: same-descriptor engine recovery.
- `/home/musubram/nfs-suse-lifecycle.gDcPw34G/`: stop/start, both rebuilds,
  successful reboot journal and postboot network/full-read results.
- `/home/musubram/nfs-migration-validation.jnDnGquK/`: released source and private
  backups, actual apply/rollback/failure logs, all five read states, original
  restoration, final AppArmor/read-only/network/health evidence.

Final running engine is
`864bc315196c41019af0e8ed02402a2e5ee1a15236c496f847890b2ca1f94601`, using
`/var/lib/tux2lab/engine-rootfs/engine.rQhsxhdw/rootfs`. This replaces the initial
`b2ddd456...` engine through the two successful rebuilds. The lab boot unit stays
enabled. Production source and image needed no SUSE-specific changes; only the
acceptance harness and its safety tests were adjusted. Rootless regressions and
warning-level ShellCheck pass for the touched scripts.

The bounded Leap 16.0 stage is complete. This does not certify SLES/other Leap
versions, package-free hosts, confined containers, writable NFS locking, NFSv3
over IPv6, live ISO handles across full filesystem teardown, independent-client
host-reboot recovery or nested provisioning. The separately approved current
Mariner handover/real PXE/rollback and final release gates remain next.

### Ubuntu 24.04 Host Preparation (October 6, 2026)

The user resumed Ubuntu validation after the bounded Alma stage. Alma remains
powered off with its disks and evidence retained. The released parent engine and
seven existing Kubernetes guests remain running. Only the new dedicated Ubuntu
VM was added through the parent's normal released tux2lab golden-image workflow:

```bash
tux2lab vm install --via-golden -H nfs-host-ubuntu24 -d ubuntu-lts -v 24.04 \
    --dual-stack --cpu 2 --memory 4 --root-disk-size 60
```

- Guest: `nfs-host-ubuntu24.musubram.internal`, Ubuntu 24.04.4 LTS, kernel
  `6.8.0-100-generic`, 2 vCPUs, 4 GiB RAM, 60 GiB disk and XFS root.
- VM UUID: `b070b941-a56b-4d77-bd17-15e82063bba7`; management MAC
  `52:54:00:a1:43:1a`, IPv4 `10.28.28.15`, IPv6 `fd28:2808:2020:3000::f`.
- After first-boot completion, the VM was shut down gracefully through tux2lab.
  Only CPU `mode='host-model' check='partial'` changed to
  `mode='host-passthrough' check='none'`; complete parsed-XML comparison preserved
  every other field. Restart used tux2lab. Guest `svm`, opening `/dev/kvm` and
  KVM API version 12 passed without creating any inner VM.
- Dedicated management key: `~/.ssh/tux2lab-nfs-host-ubuntu24_ed25519`, outside
  served data; public fingerprint
  `SHA256:UkuolQ8udu7LlqEjXmn95X+9AgDlORGCIqtU+EwE3yA`. The inherited sync timer,
  sync service and golden-boot service were backed up and disabled/stopped only
  inside Ubuntu. Independent key-only SSH and all three disabled/inactive states
  survived the CPU power cycle. No private key or password is stored in Git.
- Source: archive of `bb6f29e404ebb3d5ea382f7210a3e1500eb40aa2` in guest
  `/tux2lab`. Only its custom network input differs: `labbr0` uses
  `10.10.24.1/22` and `fd60:6060:2026:2::1/64`, NAT, libvirt DNS/DHCP disabled,
  no physical interface and only the normal dummy bridge member. The subnets
  do not overlap the parent or Alma lab networks.

Actual `bash /tux2lab/setup/setup-host.sh --yes` completed successfully. The new
persistent network UUID is `51f3ad8a-fd4a-4b9b-b9cb-d828f3e480d0`, bridge MAC
`52:54:00:16:a4:25`; source XML SHA256 is
`4999eb391b99894959979cfcdcea1525f93b097e3a3d9a782b6dda04f26fb48b`.
Setup installed Podman `4.9.3+ds1-1ubuntu0.2`, libvirt
`10.0.0-2ubuntu8.19`, QEMU `1:8.2.2+ds-0ubuntu1.18`, NFS server/client packages
`1:2.6.4-3ubuntu5.1` and rpcbind `1.2.6-7ubuntu2`. AppArmor remains enabled;
Podman reports AppArmor/seccomp enabled and overlay image storage. The candidate
still uses the managed native rootfs launcher, not overlay as its export root.
Firewalld is absent/inactive, and the actual conditional helper created a
zone-free network successfully. UFW was not found during the initial check.

Fresh-host preparation was necessary, not an out-of-the-box deployment pass:
rpcbind was already active, and package installation also started/enabled native
NFS. The real preflight rejected `nfs-server.service` before preparation. After
confirming no configured/active exports, NFS mounts/clients, guests, engine or lab
configuration, the native configuration and unit/lockd states were saved. Only
inside Ubuntu, native NFS was disabled/stopped, mountd/idmapd/statd stopped and
rpcbind service/socket stopped/masked. The real preflight and no-listener/thread
check then passed. All packages remain installed; no AppArmor policy was disabled.

The existing local candidate image was streamed from the parent's image store,
not rebuilt or published: `localhost/tux2lab-engine:nfs-direct-layout`, ID
`ef259c909b57cb4fd05695b27d928c1c1a1c1fd0e19c824789997f0303ac4eb6`. Its original-layout
labels were verified. Guest preparation logs/backups are in
`/home/musubram/nfs-host-preparation.UEc2QR5m/`, including `setup-host.log`, sync/SSH
baselines, native unit snapshots, `native-nfs-config.original.tar`, lockd state
and the expected preflight rejection. Domain XML backups are local test artifacts;
the source/runbook records the reproducible changes, not VM disks or secrets.

Preparation checkpoint `61194359ae70b08e7d5a0fdad3db58129139e44e` preceded actual
deployment. The following results supersede its pending-deployment status.

#### Deployment and Protocol Acceptance (October 6, 2026)

Actual deployment used the prepared source and candidate image:

```bash
TUX2LAB_ENGINE_IMAGE=localhost/tux2lab-engine:nfs-direct-layout tux2lab deploy
```

The user entered credentials directly in the interactive terminal. Deployment
completed with 11/11 deep health checks and 6/6 dual-stack service checks. A fresh
dedicated-key SSH connection still worked afterward, and the three inherited
credential-sync hooks remained inactive/disabled.

- Engine ID: `c0f76408142481009bcc70741451bb8cba718576db6a3c80789f67b508593f29`.
- Managed XFS root: `/var/lib/tux2lab/engine-rootfs/engine.6qyvzpbG/rootfs`.
- Initial start: `2026-10-06 03:44:41.195105759 +0000 UTC`; eight NFS threads.
- Host/container `/tux2lab-data` are real directories, not symlinks. Discovery
  advertises only `/tux2lab-data`; exports retain `ro`, `fsid=1`, `crossmnt`,
  `*.musubram.internal`, `10.10.24.0/22` and `fd60:6060:2026:2::/64`.
- The existing AlmaLinux 9 boot ISO and `almalinux-9-CHECKSUM` were transferred
  as a known-checksum installer workload, not as a claim of Alma guest boot on
  Ubuntu. ISO SHA256:
  `445f99e24399bbe98aab86111d60751c142eda049d2444fd76da5eb03472e4ab`.
  Normal `tux2lab distro setup almalinux -v 9` verified and mounted the ISO on
  `/tux2lab-data/os-repos/almalinux/9`. The original running engine immediately
  read the full installer with SHA256
  `539f423b5456aa36877b255b1fd2486d86fff9bfafc34ecb83282b72a93b70a2`, without
  changing its ID, PID, start time or root. A first transfer attempt used a
  nonexistent checksum sidecar name; the correct file and ISO were then verified.
- Existing `--deployed-network` tests passed real DHCPv4/v6 leases, DNS/domain
  and PXE options, managed RA flags/prefix/DNS/domain, and full installer reads
  over NFSv3/IPv4 and NFSv4/IPv4/IPv6. These are process-only namespace clients;
  no inner VM was created. NFSv3/IPv6 was not part of this reader's coverage.
- Existing `--deployed-restart`, run as the sudo-capable non-root user, passed
  graceful outage/recovery with the same open NFSv4.1 descriptor, matching
  O_DIRECT reads and recovered server-side OPEN state. The engine/root were
  retained. The first-MiB checksum was
  `91b2819e63ca51ad9b2c4c1718ad7e1ffb70328be6db1cccbef9e445e3973705`.
- AppArmor remained enabled. The privileged engine reports an empty AppArmor
  profile, so this is not proof of container AppArmor confinement. No
  `apparmor="DENIED"` record appeared in the captured kernel-log interval from
  `2026-10-06 03:44:00 UTC` through post-recovery verification. Firewalld remains
  absent/inactive; no enabled-firewall reload acceptance is claimed on Ubuntu.

#### Reproducible SIGKILL Blocker and Recovery (October 6, 2026)

The unchanged `--deployed-crash` harness killed engine PID1, verified exit 137
and unchanged `inet tux2lab_nfs` protection, then failed its no-listener check.
Container rpcbind/mountd exited, but eight kernel `nfsd` threads and IPv4/IPv6
port 2049 listeners remained. Automatic recovery called normal `tux2lab start`;
the engine refused the occupied ports and exited 1. This is a runtime acceptance
failure, not a passing crash test or a reason to weaken its assertion.

The first investigation found native `nfsdcld.service` and
`proc-fs-nfsd.mount` still active despite the initial preflight pass. Both were
stopped only inside Ubuntu, after checking the exact stopped engine, no inner
guests and no remaining NFS clients. Stopping the daemon left eight threads;
unmounting the native control filesystem still did not remove the listeners.
Thus removing these leftover native components alone is not a recovery fix.

After explicit manual recovery, the same SIGKILL test was repeated with both
native components already inactive. It failed identically. Their presence is
not required to reproduce the blocker. Exact kernel/runtime causation and a
guarded automatic recovery implementation remain unresolved; no production
runtime or test assertion was changed to obtain a pass.

Both manual recoveries were restricted to the exact stopped Ubuntu engine above,
with host native-owner preflight, no inner guests or NFS client mounts, and the
unchanged recorded NFS nftables ruleset checked first. A private mount namespace
mounted the NFS control filesystem, verified no server-side clients and exactly
eight orphaned threads, then ran bounded `rpc.nfsd 0`. Zero threads and absent
RPC listeners were verified before unmounting that private control filesystem.
Normal `tux2lab start` then restored the same engine/root. This used the retained
host NFS utility and is manual test-host recovery, not implemented automatic
container recovery or a generic instruction to stop another host's NFS server.
No ISO, export layout or firewall protection was removed to hide the failure.

Final recovery start: `2026-10-06 03:55:14.712551652 +0000 UTC`, PID `28270`.
Health returned to 11/11 and 6/6; subsequent actual DHCP/RA transactions and full
NFS reads passed again. Temporary client namespaces/bridge peers were removed;
the normal dummy bridge member remained. Native tracking/control units are left
inactive/static, AppArmor remains enabled, and all host packages are retained.

Private evidence directories on Ubuntu, deliberately outside Git/served data:

- `/home/musubram/nfs-ubuntu-deployment.Iz5P2FVD/`: original engine identity and
  normal distro setup log.
- `/home/musubram/nfs-ubuntu-network.5V6WaCl1/`: initial DHCP/RA and NFS reads.
- `/home/musubram/nfs-ubuntu-restart.5wm8DG1o/`: graceful active-client recovery.
- `/home/musubram/nfs-ubuntu-crash.k7huHE5o/`: first failed SIGKILL, retained
  listeners/firewall, startup failure and native-control investigation.
- `/home/musubram/nfs-ubuntu-crash-clean.iXAoeI8V/`: identical clean-state
  failure, guarded manual recovery, restored engine identity and unit states.
- `/home/musubram/nfs-ubuntu-recovered-network.Hb0xlqce/`: post-recovery full
  client acceptance and kernel-log interval.

To reproduce, use the existing `--deployed-crash EXPECTED_HOST RELATIVE_FILE
EVIDENCE_DIR` mode as the non-root sudo-capable user on this dedicated host,
with `os-repos/almalinux/9/images/install.img` and a new evidence directory.
Expect the current candidate to leave the engine down with kernel listeners;
arrange guarded manual recovery before running it. Do not run it on the parent.

At checkpoint `333d2962d3f4259b9496d60ef668e2a3783e55f0`, Ubuntu acceptance was
blocked on abrupt-exit recovery. The following authorized fix supersedes that
blocker; remaining lifecycle/rebuild/reboot, released-baseline migration/rollback
and applicable security-policy gates remain open.

#### Ownership-Checked Startup Recovery (October 6, 2026)

The user authorized an ownership-checked fix. The implementation adds a
standard-library Python host helper, not another daemon or a host NFS service.
The local image remains
`ef259c909b57cb4fd05695b27d928c1c1a1c1fd0e19c824789997f0303ac4eb6`; no image was
rebuilt or published. Only the migration worktree and Ubuntu source were changed.

`wait_for_engine_nfs` now records `nfs-owner.json` beside the managed root after
actual health succeeds. The instance and store are root-only directories, and
the snapshot is root-owned mode 600, atomically replaced. It records the host
boot ID/network namespace, full engine ID/root/start time, exact kernel `nfsd`
worker PIDs/start counters, and stateless `inet tux2lab_nfs` JSON. Worker parsing
requires host kernel-thread identity, including the kernel-thread flag and
parent PID 2. A healthy existing engine can establish its initial snapshot with
normal `tux2lab start`; no stopped/orphaned server is adopted to manufacture proof.

Before `podman start`, recovery validates the managed root/marker and fully
stopped engine, private snapshot, exact recorded ownership, inactive native
NFS/RPC services, absence of host NFS client mounts and unexpected RPC listeners.
The helper serializes its own record/recovery operations with a root-private
lock. It enters a private mount namespace, exposes the NFS control filesystem,
rechecks the engine/worker/firewall identities and exact thread count, and writes
zero to the kernel `threads` control. Zero threads and absent reserved listeners
must be verified before normal startup proceeds. No native `rpc.nfsd` executable
is used by this automatic recovery, and firewall protection remains installed.
Unknown ownership or any failed inspection stops the operation instead.

Native `nfsdcld.service` is now included in host preflight and the migration unit
snapshot/stop/mask/restore list. This does not assert that the earlier leftover
tracking service caused the Ubuntu kernel behavior, nor does it replace actual
Ubuntu released-baseline migration acceptance. Packages remain installed.

Validation on the existing Ubuntu engine:

- Root-only eight-worker snapshot creation passed through actual `tux2lab start`.
  Attempted recovery of the running engine was refused without changing its
  identity/PID or health.
- `--deployed-crash` passed exit 137, unchanged firewall, ownership-checked kernel
  cleanup, absent RPC listeners, a blocked direct read during the outage, and
  matching NFSv4.1 reads/OPEN-state recovery on the same mounted descriptor.
  The listener assertion now follows explicit guarded recovery; immediate
  disappearance after SIGKILL is deliberately not claimed.
- New `--deployed-crash-start EXPECTED_HOST EVIDENCE_DIR` passed the actual CLI
  path. With the snapshot withheld after SIGKILL, startup failed before launching
  the engine, leaving exit 137, listeners and firewall unchanged. Restoring the
  original snapshot allowed normal startup to recover the same engine/root.
  The harness preserves evidence and restores the snapshot/engine on failure.
- Graceful same-descriptor recovery and full DHCPv4/v6, RA and NFSv3/IPv4 plus
  NFSv4/IPv4/IPv6 installer reads passed again afterward. AppArmor stayed enabled,
  health passed, and temporary namespace peers were cleaned up.
- Rootless tests cover changed/missing ownership fields, PID reuse, native/RPC
  conflicts, changed identity at the final check, unexpected thread counts,
  failed shutdown, running/transitional engines and failed guest/client queries.
  Bash syntax/editor/whitespace checks pass. ShellCheck 0.11.0 was downloaded to
  a temporary directory and checked against its published SHA256; the engine
  harness is warning-clean, and other touched shell files have no new
  warning/error diagnostics compared with the committed baseline.

Evidence on Ubuntu:

- `/home/musubram/nfs-ubuntu-ownership.7IHcbKFb/`
- `/home/musubram/nfs-ubuntu-owned-crash.4tzUHG87/`
- `/home/musubram/nfs-ubuntu-crash-start.wfaTqNdL/`
- `/home/musubram/nfs-ubuntu-owned-restart.yENE6LaY/`
- `/home/musubram/nfs-ubuntu-owned-network.siZ6tzWZ/`

The original engine/root were retained; final verified start was
`2026-10-06 04:31:03.631818685 +0000 UTC`, PID `48276`. The native tracking/control
units remain inactive, firewalld remains absent/inactive, and Alma remains off.

Limits: no guarantee of immediate kernel cleanup after SIGKILL, no cold-boot
or missing-record adoption, and no support for concurrent manual changes to
host NFS ownership. Root administrators remain trusted; these checks are not
a security boundary against privileged tampering. The new recovery path has
actual Ubuntu evidence, not a new Alma/Mariner runtime acceptance claim.
At that checkpoint, remaining Ubuntu gates and separately approved parent
handover/PXE were unchanged. The continuation below supersedes that status.

#### Ubuntu Lifecycle and Migration Completion (October 6, 2026)

The user authorized continuing the remaining Ubuntu checks. Only the dedicated
Ubuntu host and migration worktree were changed. No deeper guest, host package
removal, image rebuild/publication, parent handover or main merge occurred.

Lifecycle results:

- Actual `tux2lab stop --yes` and `tux2lab start` passed, including verified NFS
  shutdown, ISO unmount/remount and preservation of configuration/network data.
- Two actual `tux2lab rebuild --yes` runs using the existing direct-layout image
  passed. Each replaced the engine/root and removed the superseded managed
  instance only after readiness. Full installer reads passed afterward.
- `tux2lab enable` installed/enabled the normal boot unit. The first reboot
  started automatically, but shutdown failed because systemd stopped the Podman
  scopes before lab cleanup, leaving NFS listeners. A runtime-only exact-scope
  `After=` probe then blocked in `podman stop` until the 120-second service
  timeout. That failed probe was not promoted; its `/run` drop-in is gone.
- The interrupted shutdown left Podman reporting `created`, PID zero, on the
  next boot. Recovery now permits this clean state only when kernel workers and
  reserved listeners are absent. Live-worker recovery still requires `exited`
  and the full private ownership proof. Normal service startup restored the
  existing engine without deleting or recreating it.
- `stop_engine_nfs` now attempts the same ownership-checked recovery if ordinary
  stop leaves residual NFS state, then requires final stopped verification.
  Unknown ownership still blocks filesystem teardown. Rootless regressions
  cover clean, recovered, refused and absent-owner paths. The successful actual
  reboot below did not need the fallback, so it is not a claim that every
  shutdown race has been reproduced with the new branch executing.
- The subsequent actual reboot passed previous-boot lab shutdown, ISO cleanup,
  unit deactivation and automatic startup. Full DHCPv4/v6, RA and NFSv3/IPv4 plus
  NFSv4.1/IPv4/IPv6 installer reads passed afterward. Final boot ID:
  `2f33d342-a776-47c0-9999-3f9adcc4f0a1`. SSH authorization, custom persistent
  network and lab configuration hashes were unchanged.

The new `--deployed-crash-stop HOST RELATIVE_FILE EVIDENCE` mode reuses the active
NFSv4 descriptor harness but invokes full CLI stop after SIGKILL. A file on the
persistent XFS data filesystem recovered matching direct reads and server OPEN
state after startup. The ISO-submount file returned EIO after full CLI stop
unmounted/remounted that filesystem. These runs left no residual workers by stop
verification, so neither proves live execution of the fallback branch. The
earlier engine-only graceful/SIGKILL ISO-handle recovery remains a separate pass.
Drain clients before full lab stop; continuity across deliberate ISO teardown is
not an accepted guarantee.

Actual released-baseline migration:

- Staged released source `0d0c7dc01395a484a98f2ef3a72f6aea0b465bf9` and the exact
  local 2.1.1 image, without replacing the guest checkout or parent runtime.
  Retained the current candidate as the guarded restoration target.
- Fresh Ubuntu lacked `/etc/exports.d`. The initial harness backup stopped
  before ownership mutation. It now records absence and removes only an empty
  directory it created during restoration, refusing unexpected contents.
- The first real handover failed because masking canonical `nfs-server.service`
  left Ubuntu's `nfs-kernel-server.service` alias with an unusable load state.
  Automatic rollback restored the baseline, then the original candidate.
  Migration snapshots now retain alias names separately, mask them too, and
  unmask them on rollback while recording canonical service state once.
- A retry exposed an inherited acceptance-lock descriptor in `conmon`. Normal
  engine stop/start released it. Supervising shells now retain acceptance and
  migration locks while descriptor-closed children run the workload, including
  EXIT-trap rollback. No lock file was deleted to bypass ownership.
- The corrected cycle passed real apply, explicit rollback and fault injection
  after the real candidate became ready, followed by automatic rollback and
  original restoration. All five states passed full installer checksums over
  NFSv3/IPv4 and NFSv4.1/IPv4/IPv6, 15 full reads in total. Both rollback paths
  restored the released engine ID, exports, native unit states and lockd values.
  Final restoration included Ubuntu's active `run-rpc_pipefs.mount` and
  `nfs-blkmap.service`, original absent exports directory, and released locks.
- Released 2.1.1 still needed Podman's SIGKILL fallback after its 30-second stop
  timeout, as on Alma. This is recorded, not a new graceful-stop claim for that
  old image. The maintained candidate passed readiness and restoration checks.

Final policy checks: AppArmor remained active/enabled with no `apparmor="DENIED"`
records in the final test boot. The privileged engine has an empty AppArmor
profile; this is compatibility, not confinement. Firewalld and UFW remain
absent/inactive, not enabled/reload acceptance. Actual management-interface
IPv4/IPv6 probes could reach SSH but not TCP ports 111/2049/20048/32803 or UDP
NULL RPC on 111/20048/32769. Server-side EROFS was verified from `rw` mounts on
all three accepted protocol/address combinations. Only `/tux2lab-data` was
advertised and only `tux2lab-data` appeared at the NFSv4 root.

Private evidence on Ubuntu:

- `/home/musubram/nfs-ubuntu-lifecycle.7Sw5f8yt/`: ordinary lifecycle, rebuilds,
  failed ordering probe, clean-Created restoration, successful reboot and full
  postboot network/protocol reads.
- `/home/musubram/nfs-ubuntu-crash-stop.aDrSqnuD/`: full-stop ISO-handle EIO.
- `/home/musubram/nfs-ubuntu-crash-stop-base.VY3Auo3L/`: persistent-file recovery.
- `/home/musubram/nfs-migration-validation.Z9cL5xYb/`: pre-mutation backup failure.
- `/home/musubram/nfs-migration-validation.YI9DDNmQ/`: alias failure and guarded
  original-engine restoration.
- `/home/musubram/nfs-migration-validation.cdop2Zgm/`: final complete migration,
  both rollbacks, original restoration, policy/read-only checks and health.

Final engine ID is
`960e098711e554c50e04cead2b982a3af0694985cb791c4269ea5a8be6a9f759`, using
`/var/lib/tux2lab/engine-rootfs/engine.1DVdbSXc/rootfs`. This replaces the earlier
`c0f764...` identity through the successful rebuilds. The image is unchanged,
the lab boot unit stays enabled, and all three inherited credential-sync hooks
remain disabled/inactive. Alma stays off. Rootless regressions, warning-level
ShellCheck and editor checks pass; code, tests and this runbook are the portable
checkpoint, not private evidence/disks/credentials.

The bounded Ubuntu stage is complete. Remaining work is separately approved
current-Mariner handover, real PXE/rollback, then final review/image/release
gates. No independent-client host-reboot recovery, nested guest provisioning,
package-free operation, strong container confinement, writable NFS locking or
additional distribution/version acceptance is claimed. The latest recovery
changes have not been rerun on the powered-off Alma host.

### AlmaLinux Remaining Work (Updated October 5, 2026)

Implementation checkpoint `90b0342b39e07f9de8b50df9102d68761a246499` includes
the tested device-visibility fix. Passed checks include actual setup/deployment
with the documented manual prerequisites, normal lifecycle and reboot startup,
full installer reads, original export-layout compatibility, and NFSv4.1
same-host-client engine restart/SIGKILL recovery with hot-added ISO devices.
Actual deployed DHCPv4/DHCPv6 and RA transactions now also pass, with released
leases and namespace cleanup verified. Released-baseline migration, explicit
rollback and injected failed-handover rollback also pass, with the original
container restored afterward. Host dependency inventory and scoped helper tracing
are complete with packages retained. Broad kernel-helper independence is not
claimed. Firewalld start/reload/restart now pass with the explicitly zoned network
and firewalld enabled. Permissive relabel/automatic startup and controlled runtime
SELinux enforcing acceptance pass. Alma is left permissive; enforcing host boot
was not tested. Conditional shared setup/start integration now passes actual
inactive/active-firewalld transitions and reload/restart on Alma, with the source
XML and original network identity preserved. The bounded Alma stage is complete.
The parent lab remains unchanged. The dated sections below retain earlier
checkpoint results; they are not the current remaining-work list.

Remaining Alma-only work and rough active-work estimates:

| Work | Estimate | Acceptance Still Needed |
| --- | --- | --- |
| Deployed DHCPv4/DHCPv6 and RA | Completed | Passed against the actual deployed configuration; see October 5 results above |
| Released-host migration and rollback | Completed | Real released baseline, successful handover, explicit and post-launch-failure rollback passed |
| SELinux/firewalld validation | Scoped tests completed | Explicit-zone reload/restart, permissive relabel/boot and runtime enforcing workloads passed; not enforcing host boot or confined-container security |
| Shared firewalld network handling | Completed | Conditional setup/start helper; actual inactive/active transitions and reload/restart passed, with live restart staged for approved maintenance |
| Host prerequisites/dependencies | Scoped audit complete | Inventory, positive-control helper trace and actual workload recorded; packages retained, no package-free claim |
| Documentation and final checkpoint | Results recorded | Security results, conditional network integration, final policy state and recovery evidence recorded; Ubuntu 24.04 follows |

The original October 3 estimate was **6-10 hours**, including the now-completed
DHCP/RA and migration/rollback work and assuming no substantial new defects. It is not a refreshed
remaining-time estimate or completion guarantee. It excludes other distributions,
parent-host handover/PXE and the independent-client reboot test below.

No additional VM will be installed inside the Alma test VM. The tested
DHCP/RA client is an ordinary process in a temporary Linux network namespace,
connected by a virtual Ethernet pair to the existing private `labbr0`. It shares
Alma's kernel and adds no QEMU, KVM instance or guest operating system. Keep DHCP
and RA off the management interface and parent network; remove the temporary
client namespace and links afterward. This approach avoids another nested
virtualization layer, but is not a guarantee against host freezes. Migration and
rollback also passed without an inner VM. The approved security-policy tests
above likewise used only process clients and temporary namespaces.

Active-client recovery across an Alma **host reboot** remains unverified.
A client namespace inside Alma cannot survive that reboot. This check requires
a separately connected external client and an agreed network setup; without
that setup, retain its unverified status rather than creating an inner VM.
The estimates and proposed topology do not authorize additional disruptive
tests, policy changes or package removal. Parent handover/PXE requires its own
approval; the no-deeper-nesting constraint remains in force.

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
  The later SSH recovery above established that the inherited golden-boot
  service must also be disabled when this VM becomes an independent lab host.
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

Apply these checks to the selected release-test hosts. The follow-up matrix
does not require additional host deployments before this release.

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