"""Safety tests use fabricated telemetry only, never performance/capacity evidence."""
import copy
import importlib.util
from pathlib import Path
import unittest

SPEC = importlib.util.spec_from_file_location("memory_trial", Path(__file__).resolve().parents[1] / "postgres_memory_trial.py")
m = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(m)


def configuration():
    target = {key: "%08d-0000-0000-0000-000000000000" % (index + 1) for index, key in enumerate(m.IDENTITIES)}
    target.update(host="tsw92-memory.railway.internal", database="tsw92_memory_012345abcdef")
    return {"target": target, "protected_source_ids": ["source-service", "source-volume"], "memory_gib": 16,
            "snapshot_sha256": "a" * 64, "workload_sha256": "b" * 64, "binary_manifest_sha256": "c" * 64,
            "observation_seconds": 3600, "sample_seconds": 30, "restart_at_seconds": 1800,
            "restart_grace_seconds": 120, "minimum_free_bytes": 100, "maximum_queue_age_seconds": 60,
            "maximum_queue_rows": 1000, "maximum_p95_ms": 500, "maximum_connections": 100,
            "minimum_restore_bytes": 1000, "seed": 123}


def probe(t=0, epoch=1, phase="mixed"):
    c = configuration()
    stats = {"stats_reset": str(epoch)}
    return {"time": t, "identity": {key: c["target"][key] for key in m.IDENTITIES}, "memory_max": 16 * m.GIB,
            "memory_events": {"oom": 0, "oom_kill": 0}, "container_epoch": [epoch], "volume_free_bytes": 1000,
            "restore": {"dataset": "full_snapshot", "snapshot_sha256": c["snapshot_sha256"], "restored_bytes": 1000, "restore_epoch": "restore1"},
            "db": {"database_bytes": 1000, "postmaster_started": str(epoch), "connections": 10,
                   "queues": {key: {"rows_lower_bound": 0, "oldest_seconds": 0} for key in ("wire_ingestion_inbox", "appview_ingestion_inbox")},
                   "wal": {**stats, "wal_bytes": t * 10}, "wal_insert_lsn": "0/%X" % (t * 20),
                   "checkpointer": dict(stats), "archiver": {**stats, "failed_count": 0}, "database_stats": dict(stats)},
            "load": {"workload_sha256": c["workload_sha256"], "binary_manifest_sha256": c["binary_manifest_sha256"],
                     "seed": 123, "phase": phase, "interval_start": t-30, "interval_end": t, "attempted": 100, "successful": 100, "p95_ms": 20}}


class MemoryTrialTests(unittest.TestCase):
    def test_target_and_limit_identity_fail_closed(self):
        c = configuration()
        m.target_identity(c, {env: c["target"][key] for key, env in m.IDENTITIES.items()})
        with self.assertRaises(m.Error):
            m.target_identity(c, {})
        c["protected_source_ids"].append(c["target"]["volume_id"])
        with self.assertRaises(m.Error):
            m.validate_config(c)

    def test_incomplete_or_synthetic_observation_cannot_pass(self):
        r = m.Round(configuration())
        r.accept(probe())
        with self.assertRaises(m.Error):
            r.finish()
        for key, value in (("dataset", "synthetic"), ("snapshot_sha256", "d" * 64)):
            p = probe(); p["restore"][key] = value
            with self.assertRaises(m.Error):
                m.Round(configuration()).accept(p)

    def test_sample_stop_gates(self):
        mutations = [lambda p: p.update(memory_max=8 * m.GIB), lambda p: p.update(volume_free_bytes=1),
                     lambda p: p["memory_events"].update(oom_kill=1), lambda p: p["db"].update(connections=101),
                     lambda p: p["db"].update(database_bytes=1), lambda p: p["db"].update(queues={}),
                     lambda p: p["load"].update(successful=99), lambda p: p["load"].update(p95_ms=float("nan")),
                     lambda p: p["load"].update(seed=999), lambda p: p["load"].update(interval_end=999),
                     lambda p: p["db"]["queues"]["wire_ingestion_inbox"].update(oldest_seconds=61)]
        for mutate in mutations:
            p = probe(); mutate(p)
            with self.subTest(mutation=mutate), self.assertRaises(m.Error):
                m.Round(configuration()).accept(p)

    def test_resets_and_missing_samples_fail(self):
        for mutate in (lambda p: p["db"]["wal"].update(stats_reset="changed"),
                       lambda p: p["memory_events"].update(oom=1),
                       lambda p: p.update(time=121), lambda p: p["db"].update(wal_insert_lsn="0/0")):
            r = m.Round(configuration()); r.accept(probe(30)); p = probe(60); mutate(p)
            with self.assertRaises(m.Error): r.accept(p)

    def test_hour_excludes_restart_gap_and_requires_external_oom_receipt(self):
        r = m.Round(configuration())
        for t in range(0, 1800, 30): r.accept(probe(t, phase="burst" if 900 <= t <= 1200 else "mixed"))
        restarted = probe(1800, epoch=2, phase="recovery")
        with self.assertRaises(m.Error): r.accept(restarted)
        restarted["restart_receipt"] = {"previous_container_epoch": [1], "termination_reason": "operator_restart", "oom_killed": False}
        r.accept(restarted)
        for t in range(1830, 3601, 30): r.accept(probe(t, epoch=2, phase="recovery" if t <= 2400 else "mixed"))
        with self.assertRaises(m.Error): r.finish()
        r.accept(probe(3630, epoch=2))
        self.assertEqual(r.finish()["observed_seconds"], 3600)
        r.last["db"]["queues"]["appview_ingestion_inbox"]["rows_lower_bound"] = 1
        with self.assertRaises(m.Error): r.finish()


if __name__ == "__main__": unittest.main()
