"""Safety tests use fabricated telemetry only, never performance/capacity evidence."""
import copy
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import Mock, patch

SPEC = importlib.util.spec_from_file_location("memory_trial", Path(__file__).resolve().parents[1] / "postgres_memory_trial.py")
m = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(m)


def configuration(memory_limit_bytes=16_000_000_000):
    target = {key: "%08d-0000-0000-0000-000000000000" % (index + 1) for index, key in enumerate(m.IDENTITIES)}
    target.update(host="tsw92-memory.railway.internal", database="tsw92_memory_012345abcdef")
    return {"target": target, "protected_source_ids": ["source-service", "source-volume"], "memory_limit_bytes": memory_limit_bytes,
            "snapshot_sha256": "a" * 64, "workload_sha256": "b" * 64, "binary_manifest_sha256": "c" * 64,
            "observation_seconds": 3600, "sample_seconds": 30, "restart_at_seconds": 1800,
            "restart_grace_seconds": 120, "minimum_free_bytes": 100, "maximum_queue_age_seconds": 60,
            "maximum_queue_rows": 1000, "maximum_p95_ms": 500, "maximum_connections": 100,
            "minimum_restore_bytes": 1000, "seed": 123}


def probe(t=0, epoch=1, phase="mixed", memory_limit_bytes=16_000_000_000):
    c = configuration(memory_limit_bytes)
    stats = {"stats_reset": str(epoch)}
    return {"time": t, "identity": {key: c["target"][key] for key in m.IDENTITIES}, "memory_limit_bytes": memory_limit_bytes,
            "memory_max": (memory_limit_bytes // 4096) * 4096, "page_size_bytes": 4096,
            "memory_events": {"oom": 0, "oom_kill": 0}, "container_epoch": [epoch], "volume_free_bytes": 1000,
            "restore": {"dataset": "full_snapshot", "snapshot_sha256": c["snapshot_sha256"], "restored_bytes": 1000, "restore_epoch": "restore1"},
            "db": {"database_bytes": 1000, "postmaster_started": str(epoch), "connections": 10,
                   "queues": {key: {"rows_lower_bound": 0, "oldest_seconds": 0,
                                    "unreconciled_dead_letters": {"rows_lower_bound": 0, "latest_at": None}}
                              for key in ("wire_ingestion_inbox", "appview_ingestion_inbox")},
                   "wal": {**stats, "wal_bytes": t * 10}, "wal_insert_lsn": "0/%X" % (t * 20),
                   "checkpointer": dict(stats), "archiver": {**stats, "failed_count": 0}, "database_stats": dict(stats)},
            "load": {"workload_sha256": c["workload_sha256"], "binary_manifest_sha256": c["binary_manifest_sha256"],
                     "seed": 123, "phase": phase, "interval_start": t-30, "interval_end": t, "attempted": 100, "successful": 100, "p95_ms": 20}}


class MemoryTrialTests(unittest.TestCase):
    def test_exact_decimal_byte_caps_are_required_without_unit_coercion(self):
        for cap in (16_000_000_000, 13_000_000_000, 12_000_000_000, 11_000_000_000, 10_000_000_000, 8_000_000_000):
            with self.subTest(cap=cap):
                config = configuration(cap)
                m.validate_config(config)
                m.Round(config).accept(probe(memory_limit_bytes=cap))
                for observed in (cap + 1, cap - 1, (cap // 1_000_000_000) * 1024 ** 3, float(cap)):
                    with self.subTest(observed=observed), self.assertRaises(m.Error):
                        sample = probe(memory_limit_bytes=cap); sample["memory_max"] = observed
                        m.Round(config).accept(sample)
        for cap in (16 * 1024 ** 3, 16, 16_000_000_001, "16000000000", 16_000_000_000.0, True, None):
            with self.subTest(configured=cap), self.assertRaises(m.Error):
                m.validate_config(configuration(cap))
        legacy = configuration(); legacy["memory_gib"] = 16
        with self.assertRaises(m.Error): m.validate_config(legacy)
        del legacy["memory_limit_bytes"]
        with self.assertRaises(m.Error): m.validate_config(legacy)

    def test_probe_compares_exact_cgroup_bytes_before_querying_database(self):
        with tempfile.TemporaryDirectory() as raw:
            directory = Path(raw); cgroup = directory / "cgroup"; cgroup.mkdir()
            for name, value in {"memory.current": "1000", "memory.stat": "anon 100\nfile 200\n",
                                "memory.events": "oom 0\noom_kill 0\n"}.items():
                (cgroup / name).write_text(value)
            boot = directory / "boot_id"; boot.write_text("local-fixture-only")
            config = configuration(); config["database_url_environment"] = "TSW92_TEST_DATABASE_URL"
            environment = {name: config["target"][key] for key, name in m.IDENTITIES.items()}
            environment.update(RAILWAY_DEPLOYMENT_ID="fixture-only", RAILWAY_VOLUME_MOUNT_PATH=raw,
                TSW92_TEST_DATABASE_URL="postgresql://fixture@tsw92-memory.railway.internal/tsw92_memory_012345abcdef")
            (directory / "memory-trial-snapshot.json").write_text(json.dumps(probe()["restore"]))
            pg = Mock(); pg.query.return_value = probe()["db"]
            def fixture_path(value):
                return boot if value == "/proc/sys/kernel/random/boot_id" else Path(value)
            with patch.object(m, "Path", side_effect=fixture_path), patch.object(m.os, "sysconf", return_value=4096) as page_size:
                for cap in (16_000_000_000, 13_000_000_000, 12_000_000_000, 11_000_000_000, 10_000_000_000, 8_000_000_000):
                    config["memory_limit_bytes"] = cap
                    observed = (cap // 4096) * 4096
                    (cgroup / "memory.max").write_text(str(observed) + "\n")
                    with self.subTest(cap=cap):
                        sample = m.sample(config, pg, environment, cgroup)
                        self.assertEqual(sample["memory_max"], observed)
                        self.assertEqual(sample["memory_limit_bytes"], cap)
                        self.assertEqual(sample["page_size_bytes"], 4096)
                        page_size.assert_called_with("SC_PAGE_SIZE")
                    for wrong in (observed + 1, observed - 1, observed + 4096, (cap // 1_000_000_000) * 1024 ** 3, "max"):
                        (cgroup / "memory.max").write_text(str(wrong))
                        calls = pg.query.call_count
                        with self.subTest(cap=cap, wrong=wrong), self.assertRaises(m.Error):
                            m.sample(config, pg, environment, cgroup)
                        self.assertEqual(pg.query.call_count, calls)
                (cgroup / "memory.max").write_text("8000000000")
                for invalid_page in (None, 4096.0, 16384, 65536):
                    page_size.return_value = invalid_page
                    calls = pg.query.call_count
                    with self.assertRaises(m.Error): m.sample(config, pg, environment, cgroup)
                    self.assertEqual(pg.query.call_count, calls)

    def test_only_verified_page_floor_is_accepted_and_legacy_aligned_evidence_remains_explicit(self):
        self.assertTrue(m.memory_limit_matches(4_000_000_000, 3_999_997_952, 4096))
        for cap in m.RAILWAY_MEMORY_LIMITS_BYTES:
            observed = cap // 4096 * 4096
            self.assertTrue(m.memory_limit_matches(cap, observed, 4096))
            for wrong in (observed + 1, observed - 1, observed + 4096, float(observed), str(observed), True, None):
                self.assertFalse(m.memory_limit_matches(cap, wrong, 4096))
            for page in (0, -4096, 4095, 8192, 16384, 65536, 4096.0, True, "4096"):
                self.assertFalse(m.memory_limit_matches(cap, observed, page))
            self.assertEqual(m.memory_limit_matches(cap, cap, None), cap in m.LEGACY_EXACT_CAPS)
        for cap in m.LEGACY_EXACT_CAPS:
            sample = probe(memory_limit_bytes=cap); sample.pop("page_size_bytes"); sample.pop("memory_limit_bytes")
            m.Round(configuration(cap)).accept(sample)
        sample = probe(memory_limit_bytes=13_000_000_000); sample.pop("page_size_bytes")
        with self.assertRaises(m.Error): m.Round(configuration(13_000_000_000)).accept(sample)
        state = m.Round(configuration()); state.accept(probe())
        changed = probe(t=30); changed.pop("page_size_bytes")
        with self.assertRaises(m.Error): state.accept(changed)

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
        mutations = [lambda p: p.update(memory_max=8_000_000_000), lambda p: p.update(volume_free_bytes=1),
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

    def test_historical_dead_letters_survive_but_new_failed_work_cannot_look_drained(self):
        for name in ("wire_ingestion_inbox", "appview_ingestion_inbox"):
            def with_dead(t, count, latest):
                p = probe(t)
                p["db"]["queues"][name]["unreconciled_dead_letters"] = {
                    "rows_lower_bound": count, "latest_at": latest}
                return p
            r = m.Round(configuration())
            r.accept(with_dead(0, 4, -10))
            r.accept(with_dead(30, 4, -10))
            r.accept(with_dead(60, 3, -10))  # Reconciliation of old failures is allowed.
            for count, latest in ((4, -10), (3, 70), (1, 70)):
                with self.subTest(queue=name, count=count, latest=latest), self.assertRaises(m.Error):
                    r.accept(with_dead(90, count, latest))
            r.accept(with_dead(90, 0, None))
            with self.assertRaises(m.Error):
                r.accept(with_dead(120, 1, 100))

    def test_missing_invalid_or_capped_dead_letter_evidence_fails_closed(self):
        for dead in (None, {}, {"rows_lower_bound": 0},
                     {"rows_lower_bound": True, "latest_at": None},
                     {"rows_lower_bound": 10001, "latest_at": 0},
                     {"rows_lower_bound": -1, "latest_at": None},
                     {"rows_lower_bound": 1, "latest_at": None},
                     {"rows_lower_bound": 0, "latest_at": 0},
                     {"rows_lower_bound": 1, "latest_at": float("nan")},
                     {"rows_lower_bound": 1, "latest_at": 999}):
            p = probe()
            p["db"]["queues"]["wire_ingestion_inbox"]["unreconciled_dead_letters"] = dead
            with self.subTest(dead=dead), self.assertRaises(m.Error):
                m.Round(configuration()).accept(p)

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
        self.assertEqual(r.finish()["memory_limit_bytes"], 16_000_000_000)
        self.assertEqual(r.finish()["memory_max"], 16_000_000_000)
        self.assertEqual(r.finish()["page_size_bytes"], 4096)
        self.assertNotIn("memory_gib", r.finish())
        r.last["db"]["queues"]["appview_ingestion_inbox"]["rows_lower_bound"] = 1
        with self.assertRaises(m.Error): r.finish()


if __name__ == "__main__": unittest.main()
