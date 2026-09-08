"""Local safety tests only. No HTTP, hosted service or representative load is run."""
import copy
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch
from test_postgres_memory_trial import configuration, probe

SPEC = importlib.util.spec_from_file_location("runner", Path(__file__).resolve().parents[1] / "postgres_memory_trial_runner.py")
m = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(m)


class RunnerTests(unittest.TestCase):
    def fixture(self, directory):
        c = configuration()
        token = directory / "token"; token.write_text("test-only"); token.chmod(0o600)
        adapter = directory / "adapter"; adapter.write_text("#!/bin/sh\nprintf '{}'\n"); adapter.chmod(0o700)
        adapters = {name: {"path": str(adapter), "sha256": m.digest(adapter)} for name in ("identity", "probe", "signer", "replay", "ranking", "restart")}
        binary = directory / "binary.json"; binary.write_text(json.dumps({"adapters": {name: value["sha256"] for name, value in adapters.items()}}))
        c["binary_manifest_sha256"] = m.digest(binary)
        c["runner"] = {"project_id": c["target"]["project_id"], "environment_id": c["target"]["environment_id"],
            "service_id": "00000005-0000-0000-0000-000000000000", "concurrency": 2, "request_timeout_seconds": 2,
            "token_file": str(token), "binary_manifest_file": str(binary), "adapters": adapters,
            "minimum_replay_per_minute": 10, "minimum_rankings_per_minute": 1, "throughput_window_seconds": 60}
        c["read_targets"] = {"gateway": {"origin": "http://tsw92-gateway.railway.internal:8080", "service_id": "00000006-0000-0000-0000-000000000000"}}
        trace = directory / "trace.json"; trace.write_text(json.dumps({"dataset": "reviewed_authenticated_trace", "source_evidence": "fixture-only",
            "rates": {"mixed": 1, "burst": 2, "recovery": 1}, "requests": [{"id": key, "target": "gateway", "category": key, "path": "/xrpc/test"} for key in sorted(m.CATEGORIES)]}))
        c["workload_sha256"] = m.digest(trace)
        env = {m.trial.IDENTITIES[key]: c["runner"][key] for key in ("project_id", "environment_id", "service_id")}
        return c, trace, env

    def test_identity_trace_adapter_and_token_fail_closed(self):
        with tempfile.TemporaryDirectory() as raw:
            directory = Path(raw); c, trace, env = self.fixture(directory)
            self.assertEqual(len(m.validate_inputs(c, trace, env)["requests"]), 5)
            mutations = [lambda x: x["runner"].update(service_id=c["target"]["service_id"]),
                lambda x: x.update(workload_sha256="f" * 64),
                lambda x: x["read_targets"]["gateway"].update(origin="https://api.thesocialwire.app"),
                lambda x: x["read_targets"]["gateway"].update(service_id="source-service"),
                lambda x: x["runner"]["adapters"]["probe"].update(sha256="f" * 64)]
            for mutate in mutations:
                invalid = copy.deepcopy(c); mutate(invalid)
                with self.assertRaises(m.Error): m.validate_inputs(invalid, trace, env)
            Path(c["runner"]["token_file"]).chmod(0o644)
            with self.assertRaises(m.Error): m.validate_inputs(c, trace, env)

    def test_incomplete_or_flat_workload_rejected_even_with_matching_hash(self):
        with tempfile.TemporaryDirectory() as raw:
            c, trace, env = self.fixture(Path(raw)); data = json.loads(trace.read_text())
            data["requests"].pop(); trace.write_text(json.dumps(data)); c["workload_sha256"] = m.digest(trace)
            with self.assertRaises(m.Error): m.validate_inputs(c, trace, env)
            c, trace, env = self.fixture(Path(raw)); data = json.loads(trace.read_text())
            data["rates"]["burst"] = 1; trace.write_text(json.dumps(data)); c["workload_sha256"] = m.digest(trace)
            with self.assertRaises(m.Error): m.validate_inputs(c, trace, env)

    def test_preflight_rejects_oom_wrong_snapshot_and_disk_before_work(self):
        c = configuration(); m.initial_probe(probe(), c)
        for mutate in (lambda p: p["memory_events"].update(oom_kill=1), lambda p: p.update(volume_free_bytes=1),
                       lambda p: p["restore"].update(snapshot_sha256="f" * 64)):
            sample = probe(); mutate(sample)
            with self.assertRaises(m.Error): m.initial_probe(sample, c)

    def test_throughput_is_a_delta_and_cannot_pass_on_an_old_burst(self):
        c = {"runner": {"minimum_replay_per_minute": 10, "minimum_rankings_per_minute": 1}}
        m.check_progress({"replay": 110, "ranking": 2}, {"replay": 100, "ranking": 1}, c)
        with self.assertRaises(m.Error): m.check_progress({"replay": 110, "ranking": 2}, {"replay": 110, "ranking": 2}, c)

    def test_cleanup_stops_only_owned_children_on_failure(self):
        children = m.Children()
        unrelated = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(30)"])
        owned = children.start([sys.executable, "-c", "import time; time.sleep(30)"])
        try:
            children.stop()
            self.assertIsNotNone(owned.poll())
            self.assertIsNone(unrelated.poll())
            with self.assertRaises(m.Error): children.start([sys.executable, "-c", "pass"])
        finally:
            unrelated.terminate(); unrelated.wait()

    def test_adapter_timeout_remains_owned_until_cleanup(self):
        with tempfile.TemporaryDirectory() as raw:
            path = Path(raw) / "slow"; path.write_text("#!/bin/sh\nsleep 30\n"); path.chmod(0o700)
            children = m.Children()
            try:
                with self.assertRaises(m.Error): m.invoke(children, {"path": str(path), "sha256": m.digest(path)}, {}, {}, .05)
                self.assertEqual(len(children.processes), 1)
            finally:
                children.stop()
            self.assertIsNotNone(children.processes[0].poll())

    def test_supervisor_failure_stops_started_workers_and_retains_failure(self):
        with tempfile.TemporaryDirectory() as raw:
            directory = Path(raw); c, trace, _ = self.fixture(directory)
            adapter = directory / "adapter"
            adapter.write_text("#!/bin/sh\nsleep 30\n")
            for value in c["runner"]["adapters"].values(): value["sha256"] = m.digest(adapter)
            config_path = directory / "config.json"; config_path.write_text(json.dumps(c))
            identity = {"target": c["target"], "runner": {key: c["runner"][key] for key in ("project_id", "environment_id", "service_id")},
                "read_targets": c["read_targets"], "snapshot_sha256": c["snapshot_sha256"]}
            children = m.Children()
            with patch.object(m, "validate_inputs", return_value=json.loads(trace.read_text())), \
                 patch.object(m, "invoke", side_effect=[identity, probe()]), \
                 patch.object(m, "Children", return_value=children), \
                 patch.object(m, "load_interval", side_effect=m.Error("simulated latency stop")):
                with self.assertRaises(m.Error): m.run(config_path, trace, directory / "evidence")
            self.assertEqual(len(children.processes), 2)
            self.assertTrue(all(process.poll() is not None for process in children.processes))
            self.assertEqual(json.loads((directory / "evidence/failure.json").read_text())["status"], "stopped")

    def test_redirect_never_forwards_authentication(self):
        with self.assertRaises(m.Error):
            m.NoRedirect().redirect_request(None, None, 302, "", {}, "https://api.thesocialwire.app")

    def test_private_evidence_refuses_overwrite(self):
        with tempfile.TemporaryDirectory() as raw:
            path = Path(raw) / "evidence"
            with m.private_file(path) as handle: handle.write("test")
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            with self.assertRaises(FileExistsError): m.private_file(path)


if __name__ == "__main__": unittest.main()
