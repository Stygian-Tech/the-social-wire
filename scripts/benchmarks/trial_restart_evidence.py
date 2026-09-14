"""Strict evidence for a clean process restart; never container-loss or crash proof."""
import hashlib
import math
import os
from pathlib import Path
import re

MODE = "postgres_process"
KIND = "retained_container_kernel"
SOCKET = "/run/tsw92-postgres-restart/control.sock"


def require(condition, message):
    if not condition:
        raise ValueError(message)


def start_ticks(pid):
    # comm may contain spaces or parentheses; fields after its final ')' start at field 3.
    return int(Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()[19])


def kernel_identity(config, cgroup=Path("/sys/fs/cgroup")):
    restart = config["restart"]
    script = Path(__file__).with_name("trial_postgres_supervisor.py")
    require(restart["mode"] == MODE, "Explicit clean process restart mode required")
    require(hashlib.sha256(script.read_bytes()).hexdigest() == restart["supervisor_sha256"], "Supervisor hash mismatch")
    require(hashlib.sha256(Path(__file__).read_bytes()).hexdigest() == restart["evidence_sha256"], "Restart evidence hash mismatch")
    cmd = Path("/proc/1/cmdline").read_bytes().split(b"\0")
    require(str(script).encode() in cmd and b"--guardian" not in cmd, "The reviewed supervisor must remain PID1")
    st = cgroup.stat()
    return {"cgroup_device": st.st_dev, "cgroup_inode": st.st_ino,
            "boot_id": Path("/proc/sys/kernel/random/boot_id").read_text().strip(),
            "pid_namespace_inode": Path("/proc/1/ns/pid").stat().st_ino,
            "supervisor_start_ticks": start_ticks(1), "supervisor_sha256": restart["supervisor_sha256"]}


def zero_oom(events):
    require(isinstance(events, dict) and {"oom", "oom_kill"} <= events.keys(), "Missing kernel OOM counters")
    for key in ("oom", "oom_kill", "oom_group_kill"):
        if key in events:
            require(type(events[key]) is int and events[key] == 0, "OOM evidence is nonzero or invalid")
    return {key: events[key] for key in ("oom", "oom_kill", "oom_group_kill") if key in events}


def validate_receipt(config, receipt, previous, current, nonce):
    require(isinstance(nonce, str) and re.fullmatch(r"[a-f0-9]{32}", nonce), "Expected restart nonce missing")
    require(receipt.get("nonce") == nonce and receipt.get("mode") == MODE
            and receipt.get("evidence_kind") == KIND, "Wrong restart request or evidence kind")
    require(receipt.get("termination_reason") == "operator_restart" and receipt.get("oom_killed") is False
            and type(receipt.get("child_exit_code")) is int and receipt["child_exit_code"] == 0
            and receipt.get("subtree_retired") is True, "Clean owned subtree exit required")
    before, after = receipt["before"], receipt["after"]
    kernel = before["kernel_identity"]
    require(set(kernel) == {"cgroup_device", "cgroup_inode", "boot_id", "pid_namespace_inode", "supervisor_start_ticks", "supervisor_sha256"}, "Incomplete kernel identity")
    require(all(type(kernel[key]) is int and kernel[key] > 0 for key in ("cgroup_device", "cgroup_inode", "pid_namespace_inode", "supervisor_start_ticks"))
            and isinstance(kernel["boot_id"], str) and re.fullmatch(r"[a-f0-9-]{36}", kernel["boot_id"])
            and kernel["supervisor_sha256"] == config["restart"]["supervisor_sha256"], "Invalid kernel identity")
    epoch = before["container_epoch"]
    require(isinstance(epoch, list) and len(epoch) == 3 and isinstance(epoch[0], str)
            and re.fullmatch(r"[a-f0-9]{8}-(?:[a-f0-9]{4}-){3}[a-f0-9]{12}", epoch[0])
            and epoch[1] == kernel["cgroup_inode"] and epoch[2] == kernel["boot_id"], "Incomplete container epoch")
    for key in ("provider_instance_id", "provider_service_instance_id"):
        require(isinstance(before[key], str) and re.fullmatch(r"[a-f0-9]{8}-(?:[a-f0-9]{4}-){3}[a-f0-9]{12}", before[key]), "Invalid provider identity")
    for key in ("identity", "container_epoch", "kernel_identity", "provider_instance_id",
                "provider_service_instance_id", "restore", "memory_max", "page_size_bytes"):
        require(key in before and before[key] == previous[key] == after[key] == current[key],
                "Retained container, provider, volume, snapshot or cap changed")
    require(before["postmaster_started"] == previous["db"]["postmaster_started"]
            and after["postmaster_started"] == current["db"]["postmaster_started"]
            and before["postmaster_started"] != after["postmaster_started"], "Postmaster transition does not match samples")
    for value in (before["postmaster_process"], after["postmaster_process"]):
        require(isinstance(value, list) and len(value) == 2 and all(type(item) is int and item > 1 for item in value), "Invalid postmaster process identity")
    require(before["postmaster_process"] == previous["postmaster_process"] and after["postmaster_process"] == current["postmaster_process"]
            and before["postmaster_process"] != after["postmaster_process"], "Postmaster process did not match adjacent samples")
    require(before["database"] == after["database"] == config["target"]["database"], "Database changed")
    require(before["system_identifier"] == after["system_identifier"], "PostgreSQL cluster changed")
    counters = [zero_oom(value["memory_events"]) for value in (previous, before, after, current)]
    require(all(value == counters[0] for value in counters), "OOM counter set changed or reset")
    times = [previous["time"], before["time"], receipt["requested_at"], receipt["exited_at"], after["time"], current["time"]]
    require(all(type(value) in (int, float) and math.isfinite(value) for value in times)
            and times == sorted(times) and times[2] < times[3] < times[4]
            and times[4] - times[1] <= config["restart_grace_seconds"], "Unordered or unbounded restart timestamps")
    require(receipt["previous_container_epoch"] == previous["container_epoch"], "Previous epoch mismatch")
