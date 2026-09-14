#!/usr/bin/env python3
"""One clean process restart in a previously reviewed isolated trial container."""
import importlib.util
import hashlib
import json
import os
from pathlib import Path
import shlex
import signal
import sys

ROOT = Path(__file__).parent
spec = importlib.util.spec_from_file_location("provider", ROOT / "railway_memory_adapters.py")
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
import trial_restart_evidence as evidence


def execute(config, request, environment=os.environ, command=m.owned_command):
    m.validate_config(config)
    evidence.require(hashlib.sha256((ROOT / "trial_restart_evidence.py").read_bytes()).hexdigest()
                     == config["restart"]["evidence_sha256"], "Local evidence module differs from reviewed hash")
    evidence.require(config["restart"]["mode"] == evidence.MODE, "Clean process restart must be explicit")
    for key in ("project_id", "environment_id", "service_id"):
        evidence.require(environment.get(m.trial.IDENTITIES[key]) == config["runner"][key], "Wrong executing runner")
    provider = m.Provider(config, command)
    identity = provider.identity(include_reads=False)
    evidence.require(environment.get("RAILWAY_DEPLOYMENT_ID") == identity["runner"]["activeDeployments"][0]["id"], "Runner epoch changed")
    before = provider.probe(identity)
    evidence.require(request["previous_container_epoch"] == before["container_epoch"]
        and request["previous_postmaster_started"] == before["db"]["postmaster_started"], "Restart request is stale")
    deployment = identity["database"]["activeDeployments"][0]
    payload = {**request, "provider_instance_id": deployment["instances"][0]["id"],
               "provider_service_instance_id": identity["database"]["id"]}
    # The persistent supervisor owns the stop/restart even if this transport dies.
    # A lost response fails this trial; never resend a mutation under another nonce.
    program = """import json,socket,sys
p=json.load(sys.stdin)
with socket.socket(socket.AF_UNIX,socket.SOCK_STREAM) as s:
 s.settimeout(p['timeout']); s.connect('/run/tsw92-postgres-restart/control.sock')
 s.sendall(json.dumps(p['request']).encode()+b'\\n'); out=bytearray()
 while b'\\n' not in out:
  chunk=s.recv(4096)
  if not chunk or len(out)+len(chunk)>65536: raise RuntimeError('invalid receipt')
  out.extend(chunk)
 print(json.dumps(json.loads(out)))
"""
    settings = config["provider"]
    timeout = config["restart_grace_seconds"] - 5
    remote = f"timeout --signal=TERM --kill-after=1s {timeout}s python3 -c " + shlex.quote(program)
    args = [settings["ssh_binary"], "-F", "/dev/null", "-o", "BatchMode=yes", "-o", "IdentitiesOnly=yes",
            "-o", "StrictHostKeyChecking=yes", "-o", "ConnectTimeout=3", "-o", "ServerAliveInterval=2",
            "-o", "ServerAliveCountMax=2", "-i", settings["ssh_identity_file"],
            identity["database"]["id"] + "@ssh.railway.com", remote]
    receipt = command(args, json.dumps({"request": payload, "timeout": timeout}).encode(), timeout=timeout + 1)
    fresh = provider.identity(include_reads=False)
    after = provider.probe(fresh)
    evidence.validate_receipt(config, receipt, before, after, request["nonce"])
    return receipt


def main():
    def stopped(_signal, _frame):
        raise ValueError("Restart transport cancelled")
    signal.signal(signal.SIGTERM, stopped); signal.signal(signal.SIGINT, stopped)
    try:
        raw = sys.stdin.buffer.read(16385)
        evidence.require(len(raw) <= 16384, "Request too large")
        request = json.loads(raw)
        config = json.loads(Path(os.environ["TSW92_TRIAL_CONFIG"]).read_text())
        print(json.dumps(execute(config, request)))
        return 0
    except BaseException:
        print("Isolated clean restart failed; preserve evidence and do not retry this round.", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
