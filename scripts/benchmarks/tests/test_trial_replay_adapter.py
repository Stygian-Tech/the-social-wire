"""Adapter safety fixtures and real owned subprocesses, never capacity evidence."""
import copy
import importlib.util
import io
import json
import os
from pathlib import Path
import signal
import shlex
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch
from test_trial_replay_receipts import configuration as receipt_configuration

SPEC = importlib.util.spec_from_file_location("replay_adapter", Path(__file__).resolve().parents[1] / "trial_replay_adapter.py")
m = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(m)


class ReplayAdapterTests(unittest.TestCase):
    def fixture(self, root):
        config = receipt_configuration()
        config.update(observation_seconds=3600, restart_grace_seconds=120, sample_seconds=5, maximum_queue_rows=5000)
        config["replay_receipts"].update(before_seq=10000, maximum_receipts=10000)
        runtime = {"APP_ENV": "dev", "DATABASE_URL": "postgresql://postgres:test@tsw92-postgres.railway.internal/tsw92_memory_aaaaaaaaaaaa",
            "WIRE_INBOX_SOURCE_GENERATIONS": "tsw92-replay-aaaaaaaaaaaa", "JETSTREAM_SOURCE_GENERATION": "tsw92-replay-aaaaaaaaaaaa", "WIRE_ACTOR_HMAC_SECRET": "fixture-actor-secret",
            "JETSTREAM_API_KEY": "fixture-archive-token", "WIRE_POSTGRES_MAX_CONNECTIONS": "12", "WIRE_INBOX_BATCH_SIZE": "1000",
            "WIRE_INBOX_CONCURRENCY": "16", "WIRE_INBOX_IDLE_MILLISECONDS": "250",
            "WIRE_DEFERRED_RECOMMENDATIONS_ENABLED": "true", "WIRE_DEPENDENCY_HYDRATION_ENABLED": "true",
            "PORT": "18086", "INDEXING_APPVIEW_HEALTH_PORT": "18087", "INDEXING_WIRE_HEALTH_PORT": "18088"}
        runtime_path = root / "runtime.json"; runtime_path.write_text(json.dumps(runtime)); runtime_path.chmod(0o600)
        config["replay_receipts"].update(runtime_environment_file=str(runtime_path), runtime_environment_sha256=m.digest(runtime_path))
        worker = root / "worker"; worker.write_text("#!/bin/sh\nexec sleep 30\n"); worker.chmod(0o700)
        executable = {"path": str(worker), "sha256": m.digest(worker)}
        manifest = root / "binary.json"; manifest.write_text(json.dumps({"workers": {"replay_ingest": executable["sha256"], "replay_drain": executable["sha256"]}}))
        config.update(binary_manifest_sha256=m.digest(manifest), runner={"binary_manifest_file": str(manifest), "throughput_window_seconds": 600})
        config["replay"] = {"module_sha256": m.digest(m.__file__), "ingest": executable, "drain": executable,
            "archive_host": m.ARCHIVE, "archive_segments": [{"name": "segment.jss", "checksum": "1234567890abcdef"}],
            "collections": ["app.bsky.feed.post"], "batch_size": 256, "admission_burst": 1, "admission_rate_per_second": 2,
            "reviewed_matching_events": 6800, "source_evidence": "fixture-only-not-a-reviewed-workload",
            "maximum_inbox_rows": 1000, "maximum_database_bytes": 10_000_000_000, "incident_bytes": 1_000_000,
            "daily_bytes": 2_000_000, "maximum_runtime_seconds": 3840, "maximum_unavailable_seconds": 120,
            "sample_seconds": 5, "ingest_port": 18084, "drain_port": 18085, "evidence_file": str(root / "evidence.jsonl")}
        return config, runtime

    def test_binary_manifest_pacing_and_bounds_fail_closed(self):
        with tempfile.TemporaryDirectory() as raw:
            config, _ = self.fixture(Path(raw)); m.validate(config)
            for key, value in [("archive_host", "https://other.example"), ("reviewed_matching_events", 10),
                    ("sample_seconds", 6), ("admission_rate_per_second", float("nan")), ("admission_burst", 257),
                    ("maximum_inbox_rows", 5001), ("maximum_runtime_seconds", 3600),
                    ("maximum_unavailable_seconds", 121), ("module_sha256", "0" * 64)]:
                broken = copy.deepcopy(config); broken["replay"][key] = value
                with self.assertRaises(m.Error): m.validate(broken)
            worker = Path(config["replay"]["ingest"]["path"]); worker.write_text("#!/bin/sh\nexit 0\n")
            with self.assertRaises(m.Error): m.validate(config)

    def test_public_runner_is_rejected_from_actual_provider_response(self):
        from types import SimpleNamespace
        config = {"runner": {"project_id": "project", "environment_id": "isolated", "service_id": "runner"}}
        clean = {"domains": {"serviceDomains": [], "customDomains": []}, "tcpProxies": []}
        calls = []
        def query(document, variables):
            calls.append((document, variables))
            return clean
        m.verify_private_runner(config, SimpleNamespace(query=query))
        self.assertIn("domains(projectId:$project", calls[0][0])
        self.assertEqual(calls[0][1]["service"], "runner")
        for exposed in ({}, clean | {"tcpProxies": [{"__typename": "TCPProxy"}]},
                clean | {"domains": {"serviceDomains": [{"__typename": "ServiceDomain"}], "customDomains": []}},
                clean | {"domains": {"serviceDomains": [], "customDomains": [{"__typename": "CustomDomain"}]}}):
            with self.assertRaises(m.Error): m.verify_private_runner(config, SimpleNamespace(query=lambda *a: exposed))

    def test_shared_coordinator_runtime_ports_cannot_collide_with_replay(self):
        with tempfile.TemporaryDirectory() as raw:
            config, runtime = self.fixture(Path(raw))
            m.validate(config)
            for key in ("PORT", "INDEXING_APPVIEW_HEALTH_PORT", "INDEXING_WIRE_HEALTH_PORT"):
                changed = runtime | {key: str(config["replay"]["ingest_port"])}
                path = Path(config["replay_receipts"]["runtime_environment_file"])
                path.write_text(json.dumps(changed))
                config["replay_receipts"]["runtime_environment_sha256"] = m.digest(path)
                with self.assertRaises(m.Error): m.validate(config)

    def test_runtime_is_private_and_only_allowlisted_keys_reach_workers(self):
        with tempfile.TemporaryDirectory() as raw:
            config, runtime = self.fixture(Path(raw))
            supplied = {"PATH": "/usr/bin:/bin", "RAILWAY_SERVICE_ID": "actual-id", "RAILWAY_DEPLOYMENT_ID": "actual-deployment",
                       "JETSTREAM_APPVIEW_ENABLED": "true", "DATABASE_URL": "production-secret", "RAILWAY_TOKEN": "provider-secret"}
            runtime.update(JETSTREAM_WIRE_LANES="live", WIRE_CORPUS_EDGE_BASE_URL="https://production.example", DATABASE_COPY_URL="source-secret")
            ingest, drain = m.child_environments(config, runtime, supplied)
            self.assertEqual(ingest["JETSTREAM_PIPELINE_MODE"], "wire-global-v1")
            self.assertEqual(ingest["JETSTREAM_REPLAY_SNAPSHOT_ONLY"], "true")
            self.assertEqual(ingest["JETSTREAM_EXIT_AFTER_SNAPSHOT"], "false")
            self.assertEqual(ingest["JETSTREAM_BOOTSTRAP_AFTER_SEQ"], "100")
            self.assertEqual(ingest["JETSTREAM_REPLAY_BEFORE_SEQ"], "10000")
            self.assertEqual(ingest["WIRE_ADMISSION_RATE_PER_SECOND"], "2")
            self.assertEqual(drain["WIRE_WORKER_ROLE"], "drain")
            self.assertEqual(drain["WIRE_INBOX_CONCURRENCY"], "16")
            for result in (ingest, drain):
                self.assertEqual(result["RAILWAY_SERVICE_ID"], "actual-id")
                for key in ("JETSTREAM_APPVIEW_ENABLED", "JETSTREAM_WIRE_LANES", "RAILWAY_TOKEN", "DATABASE_COPY_URL", "WIRE_CORPUS_EDGE_BASE_URL"):
                    self.assertNotIn(key, result)
            self.assertNotIn("JETSTREAM_API_KEY", drain)
            self.assertNotIn("WIRE_ACTOR_HMAC_SECRET", ingest)
            Path(config["replay_receipts"]["runtime_environment_file"]).chmod(0o644)
            with self.assertRaises(m.Error): m.validate(config)

    def test_archive_plan_has_exact_bounds_hashes_and_never_redirects_credentials(self):
        with tempfile.TemporaryDirectory() as raw:
            config, _ = self.fixture(Path(raw))
            plan = {"segments": config["replay"]["archive_segments"], "sealedTipSeq": 10000, "plannedThroughSeq": 10000}
            class Opener:
                def __init__(self, payload): self.payload = payload
                def open(self, request, timeout):
                    assert request.full_url == m.ARCHIVE + "/xrpc/network.bsky.jetstream.planSnapshot"
                    assert json.loads(request.data)["afterSeq"] == 100
                    assert timeout == 10
                    return io.BytesIO(json.dumps(self.payload).encode())
            m.verify_archive(config, "fixture-token", Opener(plan))
            for changed in (plan | {"sealedTipSeq": 10001}, plan | {"segments": []}, plan | {"cursor": "more"}):
                with self.assertRaises(m.Error): m.verify_archive(config, "fixture-token", Opener(changed))
            with self.assertRaises(m.Error): m.NoRedirect().redirect_request(None)

    def test_does_not_kill_callers_group_when_invoked_without_supervisor(self):
        with patch.object(m.os, "getpid", return_value=42), patch.object(m.os, "getsid", return_value=41):
            with patch.object(m.os, "killpg") as kill:
                with self.assertRaises(m.Error): m.run({})
                kill.assert_not_called()

    def test_lost_owner_requests_cancellation_without_restarting_workers(self):
        from unittest.mock import Mock
        stopped = Mock()
        stopped.wait.return_value = False
        with patch.object(m.os, "getppid", return_value=1), patch.object(m.os, "getpid", return_value=42):
            with patch.object(m.os, "kill") as kill:
                m.watch_owner(100, stopped)
                kill.assert_called_once_with(42, signal.SIGTERM)

    def test_real_child_failure_is_not_respawned_or_counted(self):
        owned = m.OwnedWorkers()
        try:
            child = owned.start("ingest", "/usr/bin/false", {"PATH": "/usr/bin:/bin"})
            child.wait(timeout=3)
            with self.assertRaisesRegex(m.Error, "no automatic restart"): owned.check()
            self.assertEqual(len(owned.processes), 1)
        finally:
            owned.stop()

    def test_cancellation_retires_owned_group_and_descendants(self):
        self.exercise_owned_stop()

    def test_absolute_deadline_interrupts_blocking_query_and_retires_descendants(self):
        self.exercise_owned_stop(deadline=True)

    def exercise_owned_stop(self, deadline=False):
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw); config, runtime = self.fixture(root)
            # These are process-ownership fixtures, not fake application throughput.
            child = root / "descendants"
            descendants = root / "descendant-pids"
            child.write_text("#!/bin/sh\nsleep 30 &\necho $! >> " + shlex.quote(str(descendants)) + "\nwait\n"); child.chmod(0o700)
            for key in ("ingest", "drain"): config["replay"][key] = {"path": str(child), "sha256": m.digest(child)}
            config["replay"]["sample_seconds"] = 1
            if deadline:
                config["replay"]["maximum_runtime_seconds"] = 1
            config_path = root / "config.json"; config_path.write_text(json.dumps(config))
            harness = root / "harness.py"
            harness.write_text("""import sys,json,time\nfrom pathlib import Path\nsys.path.insert(0,sys.argv[1])\nimport trial_replay_adapter as m\nc=json.loads(Path(sys.argv[2]).read_text())\nr=json.loads(Path(c['replay_receipts']['runtime_environment_file']).read_text())\nm.validate=lambda config:(config['replay'],r)\nclass PG:\n def run(self,*a,**k): pass\n def query(self,*a,**k):
  if c['replay']['maximum_runtime_seconds']==1: time.sleep(30)
  return {'completed':0,'snapshot_complete':False,'drain_complete':False,'receipt_bytes':8192,'scope_matches':True,'instrumentation_valid':True}\nm.receipts.verified_connection=lambda config:(PG(),'fixture-only')\nm.verify_archive=lambda *a:None\nm.verify_private_runner=lambda *a:None\nm.run(c)\n""")
            process = subprocess.Popen([sys.executable, str(harness), str(Path(m.__file__).parent), str(config_path)],
                                       start_new_session=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            try:
                wait_until = time.monotonic() + 5
                evidence = root / "evidence.jsonl"
                while time.monotonic() < wait_until:
                    if (evidence.exists() and evidence.read_text().count('"event": "worker_started"') == 2
                            and descendants.exists() and len(descendants.read_text().splitlines()) == 2): break
                    time.sleep(.02)
                self.assertEqual(evidence.read_text().count('"event": "worker_started"'), 2)
                started = time.monotonic()
                if not deadline: process.terminate()
                process.wait(timeout=4)
                self.assertLess(time.monotonic() - started, 3.5)
                events = [json.loads(line) for line in evidence.read_text().splitlines()]
                self.assertTrue(any(x["event"] == "stopped" for x in events))
                for pid in descendants.read_text().splitlines():
                    status = subprocess.run(["ps", "-o", "stat=", "-p", pid], capture_output=True, text=True).stdout.strip()
                    self.assertTrue(not status or status.startswith("Z"), "owned grandchild still running")
                for event in events:
                    if event["event"] == "worker_started":
                        with self.assertRaises(ProcessLookupError): os.kill(event["pid"], 0)
            finally:
                try: os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError: pass
                process.wait(timeout=3)
                for stream in (process.stdout, process.stderr): stream.close()
