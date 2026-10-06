#!/usr/bin/env python3

import contextlib
import fcntl
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import tempfile


def thread_identity(stat_line):
    match = re.fullmatch(r"([0-9]+) \(nfsd\) (.+)", stat_line.strip())
    if match is None:
        raise ValueError("Unrecognized NFS kernel thread")
    fields = match[2].split()
    if len(fields) < 20 or fields[1] != "2" or not int(fields[6]) & 0x200000:
        raise ValueError("NFS worker is not a host kernel thread")
    return {"pid": int(match[1]), "started": int(fields[19])}


def require_same_owner(recorded, current):
    required = {"version", "boot", "netns", "engine", "rootfs", "started", "threads", "firewall"}
    if set(recorded) != required or set(current) != required:
        raise ValueError("Missing or unknown NFS ownership evidence")
    if recorded["version"] != 1 or not recorded["threads"] or recorded != current:
        raise ValueError("NFS ownership changed; refusing kernel shutdown")


def command(arguments):
    return subprocess.run(arguments, check=True, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, universal_newlines=True, timeout=30).stdout


def inspect_engine(name):
    metadata = json.loads(command(["podman", "inspect", name]))
    if not isinstance(metadata, list) or len(metadata) != 1:
        raise ValueError("Cannot identify exactly one engine")
    return metadata[0]


def private_path(path, directory=False):
    attributes = path.lstat()
    expected_type = stat.S_ISDIR if directory else stat.S_ISREG
    if (not expected_type(attributes.st_mode) or attributes.st_uid != 0
            or attributes.st_mode & 0o077 or path.resolve() != path):
        raise ValueError("Untrusted NFS ownership path: " + str(path))


def engine_root(metadata):
    root = Path(metadata["Rootfs"])
    labels = metadata["Config"]["Labels"]
    if (not re.fullmatch(r"/var/lib/tux2lab/engine-rootfs/engine\.[a-zA-Z0-9]{8}/rootfs", str(root))
            or not re.fullmatch(r"[a-f0-9]{64}", metadata["Id"])
            or labels.get("io.tux2lab.nfs") != "container-v1"
            or labels.get("io.tux2lab.nfs.layout") != "direct-v1"
            or labels.get("io.tux2lab.rootfs") != str(root)
            or metadata["HostConfig"]["NetworkMode"] != "host"
            or metadata["HostConfig"]["Privileged"] is not True
            or root.resolve() != root or not root.is_dir()):
        raise ValueError("Engine is not a managed original-layout NFS owner")
    private_path(root.parent.parent, directory=True)
    private_path(root.parent, directory=True)
    marker = root.parent / "owner"
    attributes = marker.lstat()
    if (not stat.S_ISREG(attributes.st_mode) or attributes.st_uid != 0
            or attributes.st_mode & 0o022 or marker.read_text().strip() != "tux2lab-engine-rootfs-v1"):
        raise ValueError("Invalid engine root ownership marker")
    return root


def kernel_threads():
    workers = []
    namespace = os.readlink("/proc/self/ns/net")
    for process in Path("/proc").glob("[0-9]*"):
        try:
            information = (process / "stat").read_text()
        except FileNotFoundError:
            continue
        if " (nfsd) " not in information:
            continue
        identity = thread_identity(information)
        if os.readlink(str(process / "ns/net")) == namespace:
            workers.append(identity)
    return sorted(workers, key=lambda worker: worker["pid"])


def ownership(metadata):
    return dict(version=1, boot=Path("/proc/sys/kernel/random/boot_id").read_text().strip(),
                netns=os.readlink("/proc/self/ns/net"), engine=metadata["Id"],
                rootfs=str(engine_root(metadata)), started=metadata["State"]["StartedAt"],
                threads=kernel_threads(),
                firewall=json.loads(command(["nft", "-j", "-s", "list", "table", "inet", "tux2lab_nfs"])))


def native_preflight():
    helper = str(Path(__file__).resolve().with_name("container-nfs.sh"))
    command(["bash", "-c", 'source "$1"; container_nfs_host_preflight', "nfs-recovery", helper])


def require_stopped(metadata):
    state = metadata["State"]
    if (state["Running"] is not False or state["Status"] != "exited"
            or state["Pid"] != 0 or state.get("Restarting", False)):
        raise ValueError("Engine is not fully stopped; refusing recovery")


def require_no_listeners(include_kernel=True):
    ports = [111, 20048, 32765, 32766]
    if include_kernel:
        ports += [2049, 32803, 32769]
    expression = "( " + " or ".join("sport = :" + str(port) for port in ports) + " )"
    if command(["ss", "-H", "-lntu", expression]).strip():
        raise ValueError("Unexpected NFS/RPC listeners; refusing recovery")


def record_owner(name):
    native_preflight()
    metadata = inspect_engine(name)
    root = engine_root(metadata)
    if metadata["State"]["Running"] is not True:
        raise ValueError("Cannot record ownership of a stopped engine")
    command(["podman", "exec", name, "/bin/bash", "/usr/local/lib/tux2lab/nfs-service.sh", "check"])
    evidence = ownership(metadata)
    require_same_owner(evidence, ownership(inspect_engine(name)))
    destination = root.parent / "nfs-owner.json"
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(mode="w", dir=str(root.parent), prefix="nfs-owner.", delete=False) as output:
            temporary = output.name
            json.dump(evidence, output, sort_keys=True)
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, str(destination))
        temporary = None
    finally:
        if temporary is not None:
            os.unlink(temporary)


@contextlib.contextmanager
def control_mount():
    if os.readlink("/proc/self/ns/mnt") == os.readlink("/proc/1/ns/mnt"):
        raise ValueError("Recovery requires a private mount namespace")
    target = Path("/proc/fs/nfsd")
    probe = subprocess.run(["findmnt", "-rn", "-o", "FSTYPE", "--mountpoint", str(target)],
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                           universal_newlines=True, timeout=10)
    mounted = False
    if probe.returncode == 1 and not probe.stdout.strip():
        command(["mount", "-t", "nfsd", "nfsd", str(target)])
        mounted = True
    elif probe.returncode != 0 or probe.stdout.strip() != "nfsd":
        raise ValueError("Cannot identify NFS control mount")
    try:
        yield target / "threads"
    finally:
        if mounted:
            command(["umount", str(target)])


def recover_owner(name):
    metadata = inspect_engine(name)
    root = engine_root(metadata)
    require_stopped(metadata)
    if not kernel_threads():
        require_no_listeners()
        return
    record = root.parent / "nfs-owner.json"
    private_path(record)
    recorded = json.loads(record.read_text())
    require_same_owner(recorded, ownership(metadata))
    native_preflight()
    require_no_listeners(include_kernel=False)
    with control_mount() as control:
        metadata = inspect_engine(name)
        require_stopped(metadata)
        require_same_owner(recorded, ownership(metadata))
        if int(control.read_text().strip()) != len(recorded["threads"]):
            raise ValueError("NFS thread count changed; refusing shutdown")
        control.write_text("0\n")
        if control.read_text().strip() != "0":
            raise ValueError("Owned kernel NFS shutdown did not complete")
        require_no_listeners()
    print("Recovered the stopped engine's recorded kernel NFS threads; firewall retained.")


def main():
    if os.geteuid() != 0 or len(sys.argv) != 3 or sys.argv[1] not in ("record", "recover"):
        raise ValueError("Usage: sudo nfs-recovery.py record|recover ENGINE")
    if os.readlink("/proc/self/ns/net") != os.readlink("/proc/1/ns/net"):
        raise ValueError("Recovery must run in the host network namespace")
    descriptor = os.open("/run/tux2lab-nfs-recovery.lock", os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, "w") as lock:
        attributes = os.fstat(lock.fileno())
        if not stat.S_ISREG(attributes.st_mode) or attributes.st_uid != 0 or attributes.st_mode & 0o077:
            raise ValueError("Untrusted NFS recovery lock")
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        if sys.argv[1] == "record":
            record_owner(sys.argv[2])
        else:
            recover_owner(sys.argv[2])


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as error:
        print("NFS ownership recovery refused: " + str(error), file=sys.stderr)
        sys.exit(1)