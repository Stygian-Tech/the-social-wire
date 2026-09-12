"""Synthetic correctness and real owned-process tests; never ranking capacity evidence."""
import copy
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import Mock, patch
import test_railway_memory_adapters as fixtures
import test_trial_replay_receipts as receipt_fixtures

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
import memory_ranking_evidence as evidence
import railway_memory_ranking as ranking


def config():
    return {"target": {"database": "tsw92_memory_012345abcdef"}, "ranking": {
        "supported_languages": ["und", "en"], "config_version": "wire-v10", "maximum_stale_seconds": 720}}


def baseline():
    return {"database": config()["target"]["database"], "system_identifier": "12345", "postmaster_started": "fixture-epoch",
        "observed_at": "1000", "leases": [], "generations": []}


def sample(generated="1090", observed="1100", owner="owned", fence=1, acquired="1001"):
    result = baseline(); result["observed_at"] = observed
    result["leases"] = [{"role": role, "owner_id": owner, "fencing_token": fence,
        "acquired_at": acquired, "expires_at": "999999", "released": False} for role in evidence.ROLES]
    result["generations"] = [{"generation_id": fixtures.uid(i + 40), "language_bucket": lang, "config_version": "wire-v10",
        "generated_at": generated, "expires_at": "999999", "status": "committed", "ranked_count": 50,
        "has_commit": True, "published": True, "has_items": True} for i, lang in enumerate(("und", "en"))]
    return result


class RankingEvidenceTests(unittest.TestCase):
    def state(self): return evidence.RankingEvidence(config(), "owned", baseline(), 0)

    def test_complete_cycle_observation_has_honest_time_and_does_not_double_count(self):
        state = self.state()
        result = state.accept(sample(), 100)
        self.assertEqual(result["completed"], 1)
        self.assertEqual(result["new_cycles"][0]["generated_at"], "1090")
        self.assertEqual(result["new_cycles"][0]["first_observed_complete_at"], "1100")
        self.assertEqual(set(result["new_cycles"][0]["generation_ids"]), {"und", "en"})
        repeated = state.accept(sample(observed="1110"), 110)
        self.assertEqual(repeated["completed"], 1)
        self.assertEqual(repeated["new_cycles"], [])

    def test_missing_language_or_interrupted_publication_is_never_completion(self):
        for mutate in (lambda s: s["generations"].pop(),
            lambda s: s["generations"][0].update(status="building"),
            lambda s: s["generations"][0].update(status="shadow"),
            lambda s: s["generations"][0].update(has_commit=False),
            lambda s: s["generations"][0].update(published=False),
            lambda s: s["generations"][0].update(has_items=False),
            lambda s: s["generations"][0].update(ranked_count=0),
            lambda s: s["generations"][0].update(expires_at="1100")):
            state = self.state(); value = sample(); mutate(value)
            self.assertEqual(state.accept(value, 100)["completed"], 0)
            with self.assertRaises(evidence.RankingError): state.check_stale(721)

    def test_historical_superseded_is_complete_but_pretrial_or_stale_is_not(self):
        state = self.state(); value = sample()
        value["generations"][0]["status"] = "superseded"
        self.assertEqual(state.accept(value, 100)["completed"], 1)
        self.assertEqual(self.state().accept(sample(generated="999"), 100)["completed"], 0)
        self.assertEqual(self.state().accept(sample(generated="1002", observed="1800"), 100)["completed"], 0)

    def test_restart_reacquisition_excludes_old_fence_work_and_preserves_count(self):
        state = self.state(); state.accept(sample(), 100)
        missing = sample(observed="1120"); missing["leases"] = []; missing["generations"] = []
        self.assertEqual(state.accept(missing, 120)["status"], "awaiting_authority")
        old = sample(observed="1150", generated="1140", fence=2, acquired="1145")
        old["postmaster_started"] = "new-fixture-epoch"
        self.assertEqual(state.accept(old, 150)["completed"], 1)
        new = sample(observed="1190", generated="1180", fence=2, acquired="1145")
        self.assertEqual(state.accept(new, 190)["completed"], 2)
        with self.assertRaises(evidence.RankingError): state.accept(sample(observed="1200"), 200)

    def test_wrong_owner_identity_languages_algorithm_truncation_or_future_clock_fails(self):
        for mutate in (lambda s: s["leases"][0].update(owner_id="other"),
            lambda s: s.update(system_identifier="changed"), lambda s: s.update(database="railway"),
            lambda s: s["generations"][0].update(language_bucket="fr"),
            lambda s: s["generations"][0].update(config_version="wire-v11"),
            lambda s: s["generations"].append(s["generations"][0]),
            lambda s: s.update(generations=s["generations"] * 1025),
            lambda s: s["generations"][0].update(generated_at="1106"),
            lambda s: s.update(observed_at="999")):
            value = sample(); mutate(value)
            with self.assertRaises(evidence.RankingError): self.state().accept(value, 100)
        with self.assertRaises(evidence.RankingError): evidence.RankingEvidence(config(), "owned", sample(), 0)


class RankingAdapterTests(unittest.TestCase):
    def fixture(self, root):
        value, identity, *_ = fixtures.AdapterTests().fixture(root)
        value.update(receipt_fixtures.configuration())
        value["replay"] = {"ingest_port": 8083, "drain_port": 8084}
        binary = root / "IndexingWorker"; binary.write_text("fixture-only-not-a-Coordinator"); binary.chmod(0o700)
        runtime = {"DATABASE_URL": "postgresql://fixture:private-password@tsw92-postgres.railway.internal/" + value["target"]["database"],
            "REDIS_URL": "redis://fixture:private-redis@tsw92-redis.railway.internal:6379", "APP_ENV": "dev",
            "ENABLE_THIN_APPVIEW": "true", "APPVIEW_CACHE_BACKEND": "redis", "WIRE_FEED_MODE": "visible",
            "PORT": "8080", "INDEXING_APPVIEW_HEALTH_PORT": "8081", "INDEXING_WIRE_HEALTH_PORT": "8082",
            "WIRE_EXTERNAL_SIGNAL_MODE": "off", "WIRE_LANGUAGE_BUCKET": "und",
            "WIRE_INBOX_SOURCE_GENERATIONS": value["replay_receipts"]["source_generation"],
            "JETSTREAM_SOURCE_GENERATION": value["replay_receipts"]["source_generation"]}
        path = root / "runtime.json"; path.write_text(json.dumps(runtime)); path.chmod(0o600)
        value["ranking"] = {"binary": {"path": str(binary), "sha256": ranking.digest(binary)}, "psql": sys.executable,
            "runtime_environment_file": str(path), "runtime_environment_sha256": ranking.digest(path),
            "source_generations": [runtime["JETSTREAM_SOURCE_GENERATION"]], "supported_languages": ["und", "en"],
            "config_version": "wire-v10", "sample_seconds": 10, "maximum_stale_seconds": 720, "maximum_runtime_seconds": 5000,
            "redis_target": {"service_id": fixtures.uid(7), "host": "tsw92-redis.railway.internal", "port": 6379},
            "evidence_file": str(root / "evidence.jsonl")}
        manifest = root / "manifest.json"; value["runner"]["binary_manifest_file"] = str(manifest)
        self.repin(value)
        return value, runtime, identity

    def repin(self, value):
        settings = value["ranking"]
        settings["runtime_environment_sha256"] = ranking.digest(settings["runtime_environment_file"])
        value["replay_receipts"].update(runtime_environment_file=settings["runtime_environment_file"],
            runtime_environment_sha256=settings["runtime_environment_sha256"])
        manifest = Path(value["runner"]["binary_manifest_file"])
        manifest.write_text(json.dumps({"adapters": {"ranking": ranking.digest(ranking.__file__)}, "ranking": {
            "binary_sha256": settings["binary"]["sha256"], "runtime_environment_sha256": settings["runtime_environment_sha256"],
            "evidence_module_sha256": ranking.digest(evidence.__file__)}}))
        value["binary_manifest_sha256"] = ranking.digest(manifest)

    def test_pinned_runtime_preserves_real_coordinator_role_and_actual_identity_only(self):
        with tempfile.TemporaryDirectory() as raw:
            value, runtime, identity = self.fixture(Path(raw))
            self.assertEqual(ranking.load_runtime(value), runtime)
            child = ranking.child_environment(runtime, "owned-process", identity | {"PGPASSWORD": "never-inherit", "RAILWAY_REPLICA_ID": "unrelated"})
            self.assertEqual(child["INDEXING_WORKER_ROLE"], "coordinator")
            self.assertEqual(child["HOSTNAME"], "owned-process")
            self.assertEqual({key: child[key] for key in identity}, identity)
            self.assertNotIn("PGPASSWORD", child); self.assertNotIn("RAILWAY_REPLICA_ID", child)

    def test_ranking_and_replay_compose_one_real_scope_and_private_runtime(self):
        with tempfile.TemporaryDirectory() as raw:
            value, runtime, identity = self.fixture(Path(raw))
            runtime["JETSTREAM_API_KEY"] = "replay-only-never-pass-to-Coordinator"
            Path(value["ranking"]["runtime_environment_file"]).write_text(json.dumps(runtime))
            self.repin(value)
            receipt = ranking.replay_receipts.scope(value)
            coordinator = ranking.load_runtime(value)
            self.assertEqual(value["ranking"]["source_generations"], [receipt["source_generation"]])
            self.assertEqual(coordinator["WIRE_INBOX_SOURCE_GENERATIONS"], receipt["source_generation"])
            self.assertEqual(coordinator["JETSTREAM_SOURCE_GENERATION"], receipt["source_generation"])
            self.assertNotIn("JETSTREAM_API_KEY", ranking.child_environment(coordinator, "owned", identity))
            self.assertIn("source_generation='" + receipt["source_generation"] + "'", ranking.replay_receipts.progress_sql(value))
            for mutate in (lambda c: c["ranking"].update(source_generations=["tsw92-replay-bbbbbbbbbbbb"]),
                lambda c: c["replay_receipts"].update(source_generation="wire-global-v4"),
                lambda c: c["replay_receipts"].update(module_sha256="0" * 64),
                lambda c: c["replay_receipts"].update(runtime_environment_file="/different-private-input"),
                lambda c: c["replay_receipts"].update(runtime_environment_sha256="0" * 64),
                lambda c: c["replay"].update(ingest_port=8080),
                lambda c: c["replay"].update(drain_port=8081),
                lambda c: c["replay"].update(ingest_port=8084)):
                invalid = copy.deepcopy(value); mutate(invalid)
                with self.assertRaises((ranking.RankingError, ranking.replay_receipts.Error)):
                    ranking.load_runtime(invalid)

    def test_retargeting_inherited_credentials_mutated_hashes_and_source_scope_fail(self):
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            for key, wrong in (("DATABASE_URL", "postgresql://secret@postgres.railway.internal/railway"),
                ("REDIS_URL", "redis://redis.railway.internal"), ("APP_ENV", "prod"), ("WIRE_FEED_MODE", "shadow"),
                ("WIRE_EXTERNAL_SIGNAL_MODE", "shadow"), ("WIRE_INBOX_SOURCE_GENERATIONS", "canonical-live"),
                ("RAILWAY_SERVICE_ID", fixtures.uid(99)), ("LD_PRELOAD", "/tmp/inject.so"), ("RAILWAY_TOKEN", "secret")):
                value, runtime, _ = self.fixture(root)
                runtime[key] = wrong; Path(value["ranking"]["runtime_environment_file"]).write_text(json.dumps(runtime)); self.repin(value)
                with self.subTest(key=key), self.assertRaises((ranking.RankingError, ranking.provider_tools.Error, ranking.provider_tools.trial.replay.BenchmarkError)):
                    ranking.load_runtime(value)
            value, _, _ = self.fixture(root)
            Path(value["ranking"]["binary"]["path"]).write_text("changed")
            with self.assertRaises(ranking.RankingError): ranking.load_runtime(value)

    def test_database_observer_uses_read_only_deadlines_and_no_url_argv(self):
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw); value, runtime, _ = self.fixture(root)
            script = root / "psql"
            script.write_text(f"#!{sys.executable}\nimport os,sys,json\ns=sys.stdin.read()\n"
                "assert 'BEGIN READ ONLY' in s and \"statement_timeout='2s'\" in s and \"lock_timeout='500ms'\" in s\n"
                "assert os.environ['PGPASSWORD']=='private-password' and 'DATABASE_URL' not in os.environ\n"
                "assert not any('private-password' in a for a in sys.argv)\n"
                f"print(json.dumps({baseline()!r}))\n")
            script.chmod(0o700); value["ranking"]["psql"] = str(script)
            self.assertEqual(ranking.observe(value, runtime, 0), baseline())
            script.write_text(f"#!{sys.executable}\nimport time\ntime.sleep(10)\n")
            start = time.monotonic()
            with self.assertRaises(OSError): ranking.observe(value, runtime, 0)
            self.assertLess(time.monotonic() - start, 4)

    def test_redis_requires_live_isolated_service_and_endpoint(self):
        with tempfile.TemporaryDirectory() as raw:
            value, _, _ = self.fixture(Path(raw))
            identity = {"privateNetworks": [{"publicId": fixtures.uid(9), "dnsName": "railway"}]}
            data = {"service": {"id": fixtures.uid(17), "environmentId": value["target"]["environment_id"],
                "serviceId": fixtures.uid(7), "serviceName": "tsw92-redis", "activeDeployments": [{
                    "projectId": ranking.provider_tools.PROJECT, "environmentId": value["target"]["environment_id"],
                    "serviceId": fixtures.uid(7), "status": "SUCCESS", "instances": [{"status": "RUNNING"}]}]},
                "endpoint": {"serviceInstanceId": fixtures.uid(17), "dnsName": "tsw92-redis", "newDnsName": None, "deletedAt": None}}
            provider = Mock(); provider.config = value; provider.query.return_value = data
            ranking.verify_redis(provider, identity)
            self.assertNotIn("mutation", provider.query.call_args.args[0])
            for change in (lambda d: d["service"].update(environmentId=fixtures.uid(99)),
                lambda d: d["endpoint"].update(dnsName="redis"),
                lambda d: d["endpoint"].update(serviceInstanceId=fixtures.uid(99)),
                lambda d: d["service"]["activeDeployments"][0].update(status="CRASHED")):
                invalid = copy.deepcopy(data); change(invalid); provider.query.return_value = invalid
                with self.assertRaises(ranking.RankingError): ranking.verify_redis(provider, identity)

    def test_real_coordinator_entrypoint_is_owned_and_early_exit_fails_without_respawn(self):
        with tempfile.TemporaryDirectory() as raw:
            value, _, observed_identity = self.fixture(Path(raw))
            provider = Mock()
            provider.identity.return_value = {"runner": {"activeDeployments": [{"id": observed_identity["RAILWAY_DEPLOYMENT_ID"]}]}}
            initial = baseline(); initial["database"] = value["target"]["database"]
            child = Mock(); child.poll.return_value = 17
            with patch.dict(os.environ, observed_identity, clear=True), patch.object(ranking.provider_tools, "Provider", return_value=provider), \
                patch.object(ranking, "verify_redis"), patch.object(ranking, "observe", return_value=initial), \
                patch.object(ranking.subprocess, "Popen", return_value=child) as spawn, patch.object(ranking.sys, "stdout"):
                with self.assertRaisesRegex(ranking.RankingError, "Coordinator exited"):
                    ranking.run(value)
            spawn.assert_called_once()
            self.assertEqual(spawn.call_args.args[0], [value["ranking"]["binary"]["path"]])
            self.assertNotIn("start_new_session", spawn.call_args.kwargs)
            self.assertEqual(spawn.call_args.kwargs["env"]["INDEXING_WORKER_ROLE"], "coordinator")
            record = json.loads(Path(value["ranking"]["evidence_file"]).read_text())
            self.assertEqual(record["completed"], 0)
            self.assertEqual(record["status"], "started")

    def test_session_retirement_kills_stubborn_descendant_but_not_unrelated_process(self):
        unrelated = subprocess.Popen([sys.executable, "-c", "import time;time.sleep(15)"])
        try:
            with tempfile.TemporaryDirectory() as raw:
                pidfile = Path(raw) / "child"
                child_code = "import signal,time;signal.signal(signal.SIGTERM,signal.SIG_IGN);time.sleep(15)"
                code = f"import sys;sys.path.insert(0,{str(ROOT)!r});import railway_memory_ranking as m\n"
                code += f"p=m.subprocess.Popen([{sys.executable!r},'-c',{child_code!r}]);m.Path({str(pidfile)!r}).write_text(str(p.pid));m.time.sleep(.15);m.retire_session(.05)\n"
                process = subprocess.Popen([sys.executable, "-c", code], start_new_session=True)
                try:
                    process.wait(timeout=3)
                    self.assertEqual(process.returncode, -signal.SIGKILL)
                    pid = int(pidfile.read_text())
                    for _ in range(30):
                        state = subprocess.run(["ps", "-o", "stat=", "-p", str(pid)], capture_output=True, text=True).stdout.strip()
                        if not state or state.startswith("Z"): break
                        time.sleep(.02)
                    self.assertTrue(not state or state.startswith("Z"), "Owned descendant must not remain runnable")
                    self.assertIsNone(unrelated.poll())
                finally:
                    if process.poll() is None: os.killpg(process.pid, signal.SIGKILL); process.wait()
        finally:
            unrelated.terminate(); unrelated.wait()

    def test_parent_loss_or_local_deadline_triggers_cancellation(self):
        for parent, deadline in ((98, 100), (99, 0)):
            with patch.object(ranking.os, "getppid", return_value=99), patch.object(ranking.time, "monotonic", return_value=1), patch.object(ranking.os, "kill") as cancel:
                gate = Mock(); gate.wait.return_value = False
                ranking.watch_owner(parent, deadline, gate)
                cancel.assert_called_once_with(os.getpid(), signal.SIGTERM)

    def test_orphaned_adapter_does_not_launch_work_before_watchdog_starts(self):
        with patch.object(ranking.os, "getsid", return_value=42), patch.object(ranking.os, "getpid", return_value=42), \
            patch.object(ranking.os, "getpgrp", return_value=42), patch.object(ranking.os, "getppid", return_value=1), \
            patch.object(ranking, "run") as run, patch.object(ranking, "retire_session") as retire, \
            patch.object(ranking.signal, "signal"), patch.object(ranking.sys, "stderr"):
            ranking.main()
            run.assert_not_called()
            retire.assert_called_once_with()


if __name__ == "__main__": unittest.main()
