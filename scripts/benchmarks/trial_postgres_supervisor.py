#!/usr/bin/env python3
"""Trial-only PID1, one requested clean restart; no automatic recovery or worker control."""
import ctypes
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import signal
import socket
import stat
import subprocess
import sys
import time

import trial_restart_evidence as evidence

ROOT = Path(__file__).parent
spec = importlib.util.spec_from_file_location("provider", ROOT / "railway_memory_adapters.py")
provider = importlib.util.module_from_spec(spec); spec.loader.exec_module(provider)
ENTRYPOINT = "/usr/local/bin/railway-entrypoint.sh"
COMMAND = [ENTRYPOINT, "postgres", "-p", "5432", "-c", "listen_addresses=*"]


class SupervisorTermination(BaseException):
    """Never swallowed by socket/transport rejection handlers."""


def descendants(parent):
    processes = {}
    for path in Path("/proc").glob("[0-9]*/stat"):
        try:
            fields = path.read_text().rsplit(")", 1)[1].split()
            processes[int(path.parent.name)] = int(fields[1])
        except (FileNotFoundError, ProcessLookupError):
            pass
    found = {parent}
    while True:
        more = {pid for pid, ppid in processes.items() if ppid in found} - found
        if not more:
            return found - {parent}
        found |= more


def retire_descendants(grace=2):
    """Subreaper ownership includes detached vendor helpers, never PID1 siblings."""
    deadline = time.monotonic() + grace
    while True:
        for pid in descendants(os.getpid()):
            try:
                fd = os.pidfd_open(pid)
                try:
                    # Confirm ancestry again after opening the stable process handle.
                    if pid in descendants(os.getpid()):
                        signal.pidfd_send_signal(fd, signal.SIGTERM if time.monotonic() < deadline else signal.SIGKILL)
                finally:
                    os.close(fd)
            except ProcessLookupError:
                pass
        while True:
            try:
                if os.waitpid(-1, os.WNOHANG)[0] == 0:
                    break
            except ChildProcessError:
                return
        if time.monotonic() > deadline + 3:
            raise ValueError("Owned subtree failed to retire")
        time.sleep(.02)


def guardian(command=COMMAND):
    # Keep this process alive until helpers adopted from tini have all exited.
    if ctypes.CDLL(None, use_errno=True).prctl(36, 1, 0, 0, 0) != 0:
        raise ValueError("Subreaper unavailable")
    stop = False
    child = None
    def requested(_signal, _frame):
        nonlocal stop
        stop = True
        if child is not None and child.poll() is None:
            child.send_signal(signal.SIGTERM)
    signal.signal(signal.SIGTERM, requested)
    signal.signal(signal.SIGINT, requested)
    child = subprocess.Popen(command)
    if stop:
        requested(None, None)
    try:
        result = child.wait()
    finally:
        retire_descendants()
    # An unexpected clean exit must still fail; the parent never respawns it.
    return result if result else (0 if stop else 1)


def config_from_environment(guardian_child=False):
    path = Path(os.environ["TSW92_TRIAL_CONFIG"])
    evidence.require(path.is_absolute() and path.is_file() and not path.is_symlink()
        and path.stat().st_uid == os.getuid() and not stat.S_IMODE(path.stat().st_mode) & 0o077,
        "Supervisor config must be owner-only")
    config = json.loads(path.read_text())
    provider.trial.validate_config(config)
    actual = provider.trial.target_identity(config, os.environ)
    evidence.require(actual["project_id"] == provider.PROJECT
        and not set(actual.values()) & provider.PROTECTED, "Protected target refused")
    evidence.require(config["restart"]["mode"] == evidence.MODE and (os.getpid() == 1 or (guardian_child and os.getppid() == 1)), "Trial-only PID1 required")
    evidence.kernel_identity(config)
    evidence.require(Path(os.environ["RAILWAY_VOLUME_MOUNT_PATH"]).resolve() == Path("/var/lib/postgresql/data"), "Wrong trial volume mount")
    evidence.require(hasattr(os, "pidfd_open") and hasattr(signal, "pidfd_send_signal"), "Stable process handles required")
    return config


def observe(config):
    mount = Path(os.environ["RAILWAY_VOLUME_MOUNT_PATH"])
    restored = json.loads((mount / "memory-trial-snapshot.json").read_text())
    evidence.require(restored.get("dataset") == "full_snapshot" and restored.get("snapshot_sha256") == config["snapshot_sha256"]
        and restored.get("restored_bytes", 0) >= config["minimum_restore_bytes"] and restored.get("restore_epoch"), "Restore attestation changed")
    pg = subprocess.run(["/usr/local/bin/gosu", "postgres", "psql", "-X", "-At", "-v", "ON_ERROR_STOP=1",
        "-h", "/var/run/postgresql", "-U", "postgres", "-d", config["target"]["database"], "-c",
        "SELECT json_build_object('postmaster_started',pg_postmaster_start_time(),'database',current_database(),"
        "'system_identifier',(SELECT system_identifier::text FROM pg_control_system()),'data_directory',current_setting('data_directory'))"],
        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=3, check=True,
        env={**os.environ, "PGOPTIONS": "-c statement_timeout=2000 -c lock_timeout=500", "PGCONNECT_TIMEOUT": "2"})
    db = json.loads(pg.stdout)
    data = Path(db.pop("data_directory")).resolve()
    evidence.require(data == Path(os.environ["PGDATA"]).resolve() and mount.resolve() in data.parents, "Postmaster data path changed")
    pid = int((data / "postmaster.pid").read_text().splitlines()[0])
    db["postmaster_process"] = [pid, evidence.start_ticks(pid)]
    cgroup = Path("/sys/fs/cgroup")
    kernel = evidence.kernel_identity(config)
    events = provider.trial.pairs(cgroup / "memory.events")
    evidence.zero_oom(events)
    page = os.sysconf("SC_PAGE_SIZE")
    cap = int((cgroup / "memory.max").read_text())
    evidence.require(provider.trial.memory_limit_matches(config["memory_limit_bytes"], cap, page), "Trial cap changed")
    return {**db, "time": time.time(), "identity": provider.trial.target_identity(config, os.environ),
        "container_epoch": [os.environ["RAILWAY_DEPLOYMENT_ID"], cgroup.stat().st_ino, kernel["boot_id"]],
        "kernel_identity": kernel, "memory_events": events, "memory_max": cap, "page_size_bytes": page,
        "restore": {key: restored[key] for key in ("dataset", "snapshot_sha256", "restored_bytes", "restore_epoch")}}


class Supervisor:
    def __init__(self, config):
        self.config, self.child, self.used = config, None, False

    def launch(self):
        self.child = subprocess.Popen([sys.executable, str(Path(__file__).resolve()), "--guardian"], start_new_session=True)

    def stop(self, deadline):
        self.child.send_signal(signal.SIGTERM)
        try:
            code = self.child.wait(timeout=max(.01, deadline - time.monotonic()))
        except subprocess.TimeoutExpired:
            # Do not start a second postmaster after an ambiguous/hung shutdown.
            raise ValueError("Clean shutdown exceeded trial deadline") from None
        evidence.require(code == 0, "Requested subtree did not exit cleanly")

    def restart(self, request):
        evidence.require(not self.used and self.child.poll() is None, "Restart already used or child exited")
        evidence.require(re.fullmatch(r"[a-f0-9]{32}", request.get("nonce", "")), "Invalid restart nonce")
        before = observe(self.config)
        evidence.require(request["previous_container_epoch"] == before["container_epoch"]
            and request["previous_postmaster_started"] == before["postmaster_started"], "Stale restart request")
        for key in ("provider_instance_id", "provider_service_instance_id"):
            before[key] = provider.uuid(request[key])
        self.used = True
        receipt = {"mode": evidence.MODE, "evidence_kind": evidence.KIND, "nonce": request["nonce"],
            "previous_container_epoch": before["container_epoch"], "before": before, "requested_at": time.time()}
        deadline = time.monotonic() + self.config["restart_grace_seconds"] - 5
        self.stop(deadline)
        receipt.update(exited_at=time.time(), child_exit_code=0, subtree_retired=True)
        self.launch()
        while time.monotonic() < deadline:
            evidence.require(self.child.poll() is None, "New subtree exited")
            try:
                after = observe(self.config)
                break
            except (subprocess.SubprocessError, FileNotFoundError):
                time.sleep(.1)
        else:
            raise ValueError("Database readiness exceeded trial deadline")
        for key in ("provider_instance_id", "provider_service_instance_id"):
            after[key] = before[key]
        receipt.update(after=after, termination_reason="operator_restart", oom_killed=False)
        # Verify the full receipt before returning or recording any success.
        adjacent_before = {**before, "db": {"postmaster_started": before["postmaster_started"]}}
        adjacent_after = {**after, "db": {"postmaster_started": after["postmaster_started"]}}
        evidence.validate_receipt(self.config, receipt, adjacent_before, adjacent_after, request["nonce"])
        return receipt

    def run(self):
        self.launch()
        directory = Path(evidence.SOCKET).parent
        directory.mkdir(mode=0o700)  # Never reuse a socket or state from another supervisor.
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as listener:
            listener.bind(evidence.SOCKET); os.chmod(evidence.SOCKET, 0o600)
            listener.listen(1); listener.settimeout(.2)
            while True:
                evidence.require(self.child.poll() is None, "Unexpected database subtree exit")
                try:
                    connection, _ = listener.accept()
                except socket.timeout:
                    continue
                with connection:
                    connection.settimeout(3)
                    try:
                        payload = bytearray()
                        while b"\n" not in payload:
                            chunk = connection.recv(4096)
                            evidence.require(chunk and len(payload) + len(chunk) <= 16384, "Invalid restart request")
                            payload.extend(chunk)
                        request = json.loads(payload)
                        evidence.require(isinstance(request, dict), "Restart request must be an object")
                    except (ValueError, OSError):
                        # Transport failure before admission never stops a healthy database.
                        continue
                    was_used = self.used
                    try:
                        receipt = self.restart(request)
                    except (ValueError, KeyError, TypeError):
                        if self.used and not was_used:
                            raise
                        try:
                            connection.sendall(b'{"error":"restart rejected"}\n')
                        except OSError:
                            pass
                        continue
                    # Preserve completion even if the SSH client disconnected; never repeat it.
                    with (directory / "receipt.json").open("x") as output:
                        os.chmod(output.name, 0o600); json.dump(receipt, output); output.flush(); os.fsync(output.fileno())
                    try:
                        connection.sendall(json.dumps(receipt).encode() + b"\n")
                    except (BrokenPipeError, ConnectionResetError, socket.timeout):
                        pass


def main():
    if sys.argv[1:] == ["--guardian"]:
        # Internal child only, launched by the reviewed PID1 supervisor.
        evidence.require(os.getppid() == 1, "Guardian must be owned by PID1")
        config_from_environment(guardian_child=True)
        return guardian()
    supervisor = None
    exit_code = 1
    def terminate(_signal, _frame):
        raise SupervisorTermination()
    signal.signal(signal.SIGTERM, terminate); signal.signal(signal.SIGINT, terminate)
    try:
        supervisor = Supervisor(config_from_environment())
        supervisor.run()
    except SupervisorTermination:
        exit_code = 0
    except BaseException:
        print("Trial database supervisor stopped; no acceptance receipt available.", file=sys.stderr)
    finally:
        if supervisor and supervisor.child:
            # Final container teardown never restarts the child. PID1 exits if it hangs.
            if supervisor.child.poll() is None:
                supervisor.child.send_signal(signal.SIGTERM)
            try:
                if supervisor.child.wait(timeout=5) != 0:
                    exit_code = 1
            except subprocess.TimeoutExpired:
                exit_code = 1
    return exit_code


if __name__ == "__main__":
    sys.exit(main())
