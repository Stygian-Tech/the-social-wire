"""Safety and orchestration checks; mocked runs are never performance evidence."""

import copy
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch


MODULE_PATH = Path(__file__).resolve().parents[1] / "postgres_replay.py"
SPEC = importlib.util.spec_from_file_location("postgres_replay", MODULE_PATH)
replay = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(replay)


def sample(sequence=200, *, pending=0, generation="generation-a", wal_bytes=100):
    return {
        "wal": {"stats_reset": "2026-09-05T00:00:00Z", "wal_bytes": wal_bytes},
        "wal_insert_lsn": "0/%X" % (wal_bytes * 2),
        "cluster_bytes": 400,
        "wal_directory_bytes": 100,
        "checkpoint": {
            "replay_state": "snapshot_complete",
            "replay_before_seq": sequence,
            "replay_sealed_seq": sequence,
        },
        "actionable_count": pending,
        "dead_letters": 0,
        "active_generation": {"generation_id": generation, "ranked_count": 50},
    }


class TargetSafetyTests(unittest.TestCase):
    def test_only_explicit_isolated_targets_are_accepted(self):
        for url in (
            "postgresql://postgres:secret@127.0.0.1:55492/tsw92_admin",
            "postgres://postgres@localhost:55492/tsw92_admin",
            "postgresql://postgres@[::1]:55492/tsw92_admin",
            "postgresql://postgres@tsw92-replay-db.railway.internal:5432/postgres",
        ):
            with self.subTest(url=url):
                self.assertIsNotNone(replay.validate_target(url))

    def test_normal_postgres_production_and_hostname_lookalikes_are_rejected(self):
        for url in (
            "postgresql://postgres@127.0.0.1:5432/postgres",
            "postgresql://postgres@localhost/postgres",
            "postgresql://postgres@[::1]:5432/postgres",
            "postgresql://postgres@postgres.railway.internal/postgres",
            "postgresql://postgres@production.railway.internal/postgres",
            "postgresql://postgres@tsw92-replay-db.railway.internal.example.com/postgres",
            "postgresql://postgres@not-tsw92-replay.railway.internal/postgres",
            "postgresql://postgres@localhost.example.com:55492/postgres",
            "postgresql://postgres@192.168.1.2:55492/postgres",
            "https://tsw92-replay-db.railway.internal/postgres",
        ):
            with self.subTest(url=url):
                with self.assertRaises(replay.BenchmarkError):
                    replay.validate_target(url)

    def test_connection_query_cannot_override_the_guarded_target(self):
        origin = "postgresql://postgres@127.0.0.1:55492/postgres"
        for query in (
            "host=production.railway.internal", "service=production", "port=5432",
            "dbname=production", "options=-csearch_path=public", "sslmode=invalid",
            "sslmode=", "sslmode=disable&sslmode=require", "sslmode=disable&host=production",
            "%68ost=production", "sslmode=disable#fragment",
        ):
            with self.subTest(query=query):
                with self.assertRaises(replay.BenchmarkError):
                    replay.validate_target(origin + "?" + query)
        for mode in ("disable", "allow", "prefer", "require", "verify-ca", "verify-full"):
            self.assertIsNotNone(replay.validate_target(origin + "?sslmode=" + mode))
        with self.assertRaises(replay.BenchmarkError):
            replay.validate_target("postgresql://postgres@127.0.0.1:0/postgres")

    def test_database_names_are_owned_and_connection_options_are_preserved(self):
        admin = "postgresql://user:p%40ss@localhost:55492/tsw92_admin?sslmode=disable"
        actual = replay.database_url(admin, "tsw92_bench_012345abcdef")
        self.assertEqual(actual, "postgresql://user:p%40ss@localhost:55492/tsw92_bench_012345abcdef?sslmode=disable")
        for database in ("postgres", "production", "tsw92_bench_short", 'tsw92_bench_012345abcdef"; DROP DATABASE postgres'):
            with self.subTest(database=database):
                with self.assertRaises(replay.BenchmarkError):
                    replay.database_url(admin, database)


class ActorHMACSecretTests(unittest.TestCase):
    def test_default_key_is_fresh_and_does_not_inherit_a_service_key(self):
        with patch.dict(replay.os.environ, {"WIRE_ACTOR_HMAC_SECRET": "inherited-service-secret"}):
            first = replay.actor_hmac_secret({})
            second = replay.actor_hmac_secret({})
        self.assertRegex(first, r"^[a-f0-9]{64}$")
        self.assertRegex(second, r"^[a-f0-9]{64}$")
        self.assertNotEqual(first, second)

    def test_named_key_matches_worker_whitespace_and_utf8_validation(self):
        config = {"actor_hmac_secret_environment": "TEST_ACTOR_KEY"}
        for secret in ("a" * 32, "é" * 16):
            with self.subTest(secret_bytes=len(secret.encode())), \
                 patch.dict(replay.os.environ, {"TEST_ACTOR_KEY": " \n" + secret + "\t"}):
                self.assertEqual(replay.actor_hmac_secret(config), secret)

    def test_invalid_inputs_fail_without_exposing_the_value(self):
        config = {"actor_hmac_secret_environment": "TEST_ACTOR_KEY"}
        for secret in (None, "", " \n\t", "private-short-key", "é" * 15):
            with self.subTest(secret=secret), patch.dict(replay.os.environ, {}, clear=True):
                if secret is not None:
                    replay.os.environ["TEST_ACTOR_KEY"] = secret
                with self.assertRaises(replay.BenchmarkError) as raised:
                    replay.actor_hmac_secret(config)
                if secret and secret.strip():
                    self.assertNotIn(secret, str(raised.exception))
        for name in (None, 123, "", "INVALID-NAME", "literal key material"):
            with self.subTest(name=name), self.assertRaises(replay.BenchmarkError):
                replay.actor_hmac_secret({"actor_hmac_secret_environment": name})


class ObservationSafetyTests(unittest.TestCase):
    def test_lsn_span_handles_cross_highword_rollover_and_unsigned_64bit_bounds(self):
        self.assertEqual(replay.wal_lsn_span_bytes("0/FFFFFFFF", "1/0"), 1)
        self.assertEqual(replay.wal_lsn_span_bytes("ABC/FFFFFFF0", "ABD/10"), 32)
        self.assertEqual(replay.wal_lsn_span_bytes("0/0", "FFFFFFFF/FFFFFFFF"), (1 << 64) - 1)
        self.assertEqual(replay.wal_lsn_span_bytes("a/b", "A/B"), 0)
        self.assertEqual(replay.wal_lsn_span_bytes("00000000/00000000", "0/0"), 0)

    def test_lsn_span_rejects_malformed_out_of_range_and_backwards_positions(self):
        for invalid in (None, 0, "", "0", "0/", "/0", "-1/0", "+1/0", "0x1/0",
                        "0/G", "1/2/3", " 0/0", "0/0\n", "100000000/0", "0/100000000"):
            for before, after in ((invalid, "0/1"), ("0/0", invalid)):
                with self.subTest(before=before, after=after), self.assertRaises(replay.BenchmarkError):
                    replay.wal_lsn_span_bytes(before, after)
        with self.assertRaisesRegex(replay.BenchmarkError, "backwards"):
            replay.wal_lsn_span_bytes("1/0", "0/FFFFFFFF")

    def test_wal_delta_matches_one_unreset_counter_epoch(self):
        before = {"wal_bytes": "100", "stats_reset": "epoch-a"}
        self.assertEqual(replay.wal_delta(before, {"wal_bytes": "140", "stats_reset": "epoch-a"}), 40)
        self.assertEqual(replay.wal_delta(before, before), 0)
        for after in ({"wal_bytes": 140, "stats_reset": "epoch-b"}, {"wal_bytes": 99, "stats_reset": "epoch-a"}):
            with self.subTest(after=after):
                with self.assertRaises(replay.BenchmarkError):
                    replay.wal_delta(before, after)

    def test_runtime_cap_is_inclusive(self):
        replay.check_limits(sample(), 10, 69.999, 60, 501)
        for now in (70, 71):
            with self.subTest(now=now):
                with self.assertRaisesRegex(replay.BenchmarkError, "deadline"):
                    replay.check_limits(sample(), 10, now, 60, 501)

    def test_database_and_wal_bytes_share_an_inclusive_cap(self):
        for cluster, wal in ((400, 100), (500, 0), (0, 500), (400, 101)):
            current = sample()
            current.update(cluster_bytes=cluster, wal_directory_bytes=wal)
            with self.subTest(cluster=cluster, wal=wal):
                with self.assertRaisesRegex(replay.BenchmarkError, "byte cap"):
                    replay.check_limits(current, 0, 1, 60, 500)

    def test_snapshot_requires_exact_seal_and_an_empty_actionable_queue(self):
        self.assertTrue(replay.snapshot_complete(sample(), 200))
        cases = [
            {"checkpoint": None},
            {"checkpoint": {}},
            {"actionable_count": 1},
            {"actionable_count": None},
        ]
        for field, value in (("replay_state", "replaying"), ("replay_before_seq", 199),
                             ("replay_sealed_seq", 199), ("replay_sealed_seq", 201)):
            changed = copy.deepcopy(sample()["checkpoint"])
            changed[field] = value
            cases.append({"checkpoint": changed})
        for changes in cases:
            with self.subTest(changes=changes):
                self.assertFalse(replay.snapshot_complete(dict(sample(), **changes), 200))
        missing_count = sample()
        del missing_count["actionable_count"]
        self.assertFalse(replay.snapshot_complete(missing_count, 200))

    def test_archive_identity_requires_the_same_checksums_and_full_sealed_interval(self):
        config = {"archive_host": "https://jetstream.us-west.bsky.network", "after_seq": 100,
                  "before_seq": 200, "collections": ["app.bsky.feed.post"],
                  "archive_segments": [{"name": "public-segment", "checksum": "expected-checksum"}]}
        plan = {"segments": config["archive_segments"], "sealedTipSeq": 200, "plannedThroughSeq": 200}
        with patch.object(replay.urllib.request, "urlopen", return_value=io.StringIO(json.dumps(plan))) as request:
            self.assertEqual(replay.archive_plan(config, "test-key"), plan)
            body = json.loads(request.call_args.args[0].data)
            self.assertEqual(body, {"afterSeq": 100, "beforeSeq": 200, "collections": ["app.bsky.feed.post"]})
        for changes in ({"sealedTipSeq": 201}, {"plannedThroughSeq": 199},
                        {"segments": [{"name": "public-segment", "checksum": "changed"}]}):
            with self.subTest(changes=changes), \
                 patch.object(replay.urllib.request, "urlopen", return_value=io.StringIO(json.dumps(dict(plan, **changes)))):
                with self.assertRaisesRegex(replay.BenchmarkError, "Archive identity/plan changed"):
                    replay.archive_plan(config, "test-key")


class FakeProcess:
    def __init__(self, name, events, status=None, slow=False):
        self.name, self.events, self.status, self.slow = name, events, status, slow

    def poll(self):
        return self.status

    def terminate(self):
        self.events.append(("terminate", self.name))

    def wait(self, timeout):
        self.events.append(("wait", self.name))
        if self.slow:
            self.slow = False
            raise subprocess.TimeoutExpired(self.name, timeout)
        self.status = 0
        return self.status

    def kill(self):
        self.events.append(("kill", self.name))


class ProcessSafetyTests(unittest.TestCase):
    def test_shutdown_stops_intake_first_and_reaps_every_child(self):
        events = []
        processes = [FakeProcess(name, events) for name in ("appview", "drain", "rank", "ingest")]
        replay.stop_processes(processes)
        self.assertEqual(events[:4], [("terminate", name) for name in ("ingest", "rank", "drain", "appview")])
        self.assertEqual(events[4:], [("wait", name) for name in ("ingest", "rank", "drain", "appview")])

    def test_unresponsive_children_are_killed_and_already_exited_children_are_reaped(self):
        events = []
        replay.stop_processes([FakeProcess("exited", events, status=7), FakeProcess("stuck", events, slow=True)])
        self.assertEqual(events, [("terminate", "stuck"), ("wait", "stuck"),
                                  ("kill", "stuck"), ("wait", "stuck"), ("wait", "exited")])


class PostgresConnectionTests(unittest.TestCase):
    def test_observation_samples_include_lsn_and_checkpointer_without_resetting_counters(self):
        expected = {"wal_insert_lsn": "0/123", "checkpointer": {"num_timed": 2, "stats_reset": "epoch-a"}}
        with patch.object(replay.Postgres, "query", return_value=expected) as query:
            result = replay.sample_database(replay.Postgres("psql"), "postgresql://localhost:55492/admin",
                "wire-global-v4-tsw92-bench-012345abcdef")
        self.assertEqual(result, expected)
        sql = query.call_args.args[1]
        self.assertIn("pg_current_wal_insert_lsn()::text", sql)
        self.assertIn("FROM pg_stat_checkpointer", sql)
        self.assertNotIn("pg_stat_reset", sql)

    def test_checkpoint_is_standalone_with_server_side_deadline(self):
        with patch.object(replay.subprocess, "run", return_value=subprocess.CompletedProcess(["psql"], 0, stdout="")) as run:
            replay.Postgres("psql").run("postgresql://localhost:55492/tsw92_bench_012345abcdef",
                sql="CHECKPOINT", statement_timeout_seconds=10)
        self.assertEqual(run.call_args.args[0][-2:], ["-c", "CHECKPOINT"])
        self.assertEqual(run.call_args.kwargs["env"]["PGOPTIONS"], "-c statement_timeout=10000")
        self.assertEqual(run.call_args.kwargs["timeout"], 12)

    def test_checkpoint_rejects_unowned_targets_and_other_clients(self):
        pg = type("FakePostgres", (), {"query": lambda *args: 1})()
        with self.assertRaisesRegex(replay.BenchmarkError, "owned benchmark"):
            replay.checkpoint_phase(pg, "postgresql://localhost:55492/production")
        with self.assertRaisesRegex(replay.BenchmarkError, "idle dedicated"):
            replay.checkpoint_phase(pg, "postgresql://localhost:55492/tsw92_bench_012345abcdef")

    def test_signal_cardinality_reads_partition_rows_with_existing_read_only_timeout(self):
        counts = {"total": 3, "by_signal_kind": {"like": 2, "share": 1}}
        with patch.object(replay.Postgres, "run", return_value=json.dumps(counts)) as run:
            self.assertEqual(replay.signal_cardinality(replay.Postgres("psql"),
                "postgresql://localhost:55492/tsw92_admin"), counts)
        sql = run.call_args.args[1]
        self.assertIn("BEGIN READ ONLY; SET LOCAL statement_timeout='5s';", sql)
        self.assertIn("FROM public.wire_signal_events GROUP BY signal_kind", sql)
        self.assertIn("count(*)", sql)
        self.assertNotIn("pg_stat_user_tables", sql)
        self.assertNotIn("ONLY", sql.split("SET LOCAL", 1)[1])
        self.assertNotIn("reset", sql.lower())

    def test_uri_values_are_decoded_into_libpq_environment_without_inherited_overrides(self):
        url = "postgresql://bench%20user:p%40ss%2Fword%3Asecret@localhost:55492/tsw92%20fixture?sslmode=verify-full"
        inherited = {"PGSERVICE": "production", "PGOPTIONS": "-c default_transaction_read_only=off",
                     "PGHOST": "production.railway.internal", "PGPORT": "5432", "PGDATABASE": "production",
                     "PGPASSWORD": "wrong-password", "PGSSLMODE": "disable", "PGSERVICEFILE": "/private/service.conf",
                     "PATH": "/usr/bin"}
        completed = subprocess.CompletedProcess(["psql"], 0, stdout="  42\n", stderr="")
        with patch.dict(replay.os.environ, inherited, clear=True), \
             patch.object(replay.subprocess, "run", return_value=completed) as run:
            self.assertEqual(replay.Postgres("/usr/bin/psql").run(url, sql="SELECT 42"), "42")
        command = run.call_args.args[0]
        self.assertEqual(command, ["/usr/bin/psql", "-X", "-qAt", "-v", "ON_ERROR_STOP=1", "-c", "SELECT 42"])
        self.assertNotIn(url, command)
        self.assertNotIn("p@ss/word:secret", " ".join(command))
        self.assertEqual(run.call_args.kwargs["env"], {
            "PATH": "/usr/bin", "PGHOST": "localhost", "PGPORT": "55492", "PGUSER": "bench user",
            "PGPASSWORD": "p@ss/word:secret", "PGDATABASE": "tsw92 fixture", "PGCONNECT_TIMEOUT": "5",
            "PGAPPNAME": "tsw92-benchmark", "PGSSLMODE": "verify-full",
        })
        self.assertEqual(run.call_args.kwargs["timeout"], 12)

    def test_psql_failures_do_not_expose_sensitive_stderr(self):
        url = "postgresql://postgres:secret@localhost:55492/tsw92_fixture"
        completed = subprocess.CompletedProcess(["psql"], 2, stdout="", stderr=url + " private seed contents")
        with patch.object(replay.subprocess, "run", return_value=completed):
            with self.assertRaises(replay.BenchmarkError) as raised:
                replay.Postgres("psql").run(url, sql="SELECT 42")
        self.assertIn("exit 2", str(raised.exception))
        self.assertNotIn("secret", str(raised.exception))
        self.assertNotIn("private seed", str(raised.exception))


class SignedReadProbeTests(unittest.TestCase):
    def test_signature_matches_known_path_only_hmac_without_base64_padding(self):
        # Independently calculated with OpenSSL SHA-256 HMAC over the protocol's
        # literal timestamp, method, path, and anonymous discovery DID.
        expected = {
            "X-SocialWire-Gateway-DID": "did:web:thesocialwire.app:anonymous-discovery",
            "X-SocialWire-Gateway-Timestamp": "1700000000",
            "X-SocialWire-Gateway-Signature": "F1JmBxwU1536lL1scwhN2qoKL8ahqcE4V1V3MrU3-d8",
        }
        path = "/xrpc/app.thesocialwire.discovery.getWire"
        for query in ("", "?limit=50", "?limit=10&cursor=encoded%3Fvalue"):
            with self.subTest(query=query):
                self.assertEqual(replay.anonymous_gateway_headers("test-gateway-secret", path + query, 1700000000), expected)
        self.assertNotEqual(replay.anonymous_gateway_headers("test-gateway-secret", path + "/other", 1700000000), expected)

    def test_local_read_probe_attaches_trust_headers_and_matches_the_local_generation(self):
        response = io.StringIO(json.dumps({"generationId": "local-generation", "source": "ranked",
                                           "degraded": False, "items": [{"id": "story"}]}))
        response.status = 200
        with patch.object(replay.time, "time", return_value=1700000000), \
             patch.object(replay.urllib.request, "urlopen", return_value=response) as request:
            result = replay.read_probe(18081, "local-generation", "test-gateway-secret")
        sent = request.call_args.args[0]
        self.assertEqual(sent.full_url, "http://127.0.0.1:18081/xrpc/app.thesocialwire.discovery.getWire?limit=50")
        self.assertEqual(sent.get_header("X-socialwire-gateway-signature"), "F1JmBxwU1536lL1scwhN2qoKL8ahqcE4V1V3MrU3-d8")
        self.assertEqual(sent.get_header("X-socialwire-gateway-timestamp"), "1700000000")
        self.assertNotIn("test-gateway-secret", str(sent.header_items()))
        self.assertEqual(result["status"], 200)
        self.assertTrue(result["matches_local_active"])
        self.assertEqual(result["item_count"], 1)


class ReplayOrchestrationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.seed = self.root / "seed.sql"
        self.seed.write_text("-- Explicit test fixture; no database is contacted.\n")
        self.output = self.root / "evidence"
        self.output.mkdir()
        self.events = []
        self.environments = []
        self.config = {
            "archive_host": "https://jetstream.us-west.bsky.network",
            "after_seq": 100, "before_seq": 200, "collections": ["app.bsky.feed.post"],
            "common_environment": {"WIRE_FEED_ENABLED": "true"},
            "maximum_seconds": 60, "maximum_database_and_wal_bytes": 1000,
            "observation_seconds": 0.25, "sample_seconds": 1, "minimum_successful_reads": 2,
        }
        self.variant = {"name": "candidate", "revision": "a" * 40,
                        "rank_interval_seconds": 300, "generation_retention_seconds": 7200}
        for binary in ("ingest", "wire", "appview"):
            path = self.root / binary
            path.write_bytes(b"unit-test executable identity only")
            self.variant[binary] = str(path)
        self.generation = "wire-global-v4-tsw92-bench-012345abcdef"
        self.pg = type("FakePostgres", (), {"run": lambda _, url, sql=None, file=None, **kwargs: self.events.append(("sql", sql, str(file)))})()
        def count_signals(url, sql):
            if "pg_stat_activity" in sql:
                self.events.append(("idle_check",))
                return 0
            if "pg_stat_checkpointer" in sql:
                self.events.append(("checkpoint_snapshot",))
                return {"captured_at": "2026-09-05T00:00:00Z", "wal_insert_lsn": "0/123",
                        "checkpointer": {"num_timed": 3, "num_requested": 1, "stats_reset": "epoch-a"}}
            self.events.append(("signal_count",))
            return {"total": 3, "by_signal_kind": {"like": 2, "share": 1}}
        self.pg.query = count_signals

    def run_replay(self, samples, *, failed_child=None, ingest_status=0):
        def start(binary, env, log_path):
            name = log_path.stem
            self.events.append(("start", name))
            self.environments.append((name, env))
            status = 9 if name == failed_child else (ingest_status if name == "ingest" else None)
            return FakeProcess(name, self.events, status=status)

        def probe(port, generation, trust_secret):
            self.assertEqual(trust_secret, "unit-test-gateway-secret")
            return {"status": 200, "matches_local_active": True, "generation_id": generation,
                    "source": "ranked", "degraded": False, "item_count": 50}

        sample_iterator = iter(samples)
        def database_sample(*args):
            self.events.append(("sample",))
            return next(sample_iterator)

        with patch.object(replay, "sample_database", side_effect=database_sample), \
             patch.object(replay, "start_process", side_effect=start), \
             patch.object(replay, "read_probe", side_effect=probe), \
             patch.object(replay.time, "sleep"), \
             patch.object(replay.time, "monotonic", side_effect=(100 + n / 10 for n in range(200))):
            return replay.run_variant(self.config, self.variant, self.pg,
                "postgresql://postgres@localhost:55492/tsw92_admin", self.output,
                {"JETSTREAM_API_KEY": "unit-test-only", "GATEWAY_APPVIEW_INTERNAL_SECRET": "unit-test-gateway-secret"},
                self.generation, self.seed)

    def assert_cleanup_after_children(self):
        drops = [i for i, event in enumerate(self.events) if event[0] == "sql" and (event[1] or "").startswith("DROP")]
        waits = [i for i, event in enumerate(self.events) if event[0] == "wait"]
        self.assertEqual(len(drops), 1)
        self.assertEqual(len(waits), 4)
        self.assertGreater(drops[0], max(waits))
        sql = self.events[drops[0]][1]
        self.assertRegex(sql, r'^DROP DATABASE "tsw92_bench_[a-f0-9]{12}" WITH \(FORCE\)$')

    def test_success_requires_replay_drain_and_multiple_local_generations(self):
        result = self.run_replay([sample(), sample(pending=1, wal_bytes=140), sample(generation="generation-b", wal_bytes=180)])
        self.assertEqual(result["status"], "passed")
        self.assertEqual(result["wal_bytes"], 80)
        # Address span is intentionally distinct from asynchronously visible counters.
        self.assertEqual(result["wal_lsn_span_bytes"], 160)
        self.assertEqual(result["observed_generations"], 2)
        self.assertEqual(result["successful_reads"], 2)
        self.assert_cleanup_after_children()
        counts = [i for i, event in enumerate(self.events) if event[0] == "signal_count"]
        self.assertEqual(len(counts), 2)
        self.assertLess(counts[0], next(i for i, event in enumerate(self.events) if event[0] == "start"))
        self.assertGreater(counts[1], max(i for i, event in enumerate(self.events) if event[0] == "wait"))
        self.assertEqual(result["initial_signal_cardinality"]["total"], 3)
        self.assertEqual(result["final_signal_cardinality"]["by_signal_kind"], {"like": 2, "share": 1})
        checkpoint = next(i for i, event in enumerate(self.events) if event[:2] == ("sql", "CHECKPOINT"))
        snapshots = [i for i, event in enumerate(self.events) if event[0] == "checkpoint_snapshot"]
        self.assertEqual(len(snapshots), 2)
        self.assertLess(snapshots[0], checkpoint)
        self.assertGreater(snapshots[1], checkpoint)
        self.assertLess(snapshots[1], next(i for i, event in enumerate(self.events) if event[0] == "sample"))
        self.assertTrue(result["checkpoint_phase"]["completed"])
        self.assertEqual(result["checkpoint_phase"]["after"]["checkpointer"]["stats_reset"], "epoch-a")

    def test_each_variant_gets_exactly_one_checkpoint_after_restoring_its_seed(self):
        for name in ("baseline", "candidate"):
            self.variant["name"] = name
            self.run_replay([sample(), sample(pending=1), sample(generation="generation-b")])
        checkpoints = [i for i, event in enumerate(self.events) if event[:2] == ("sql", "CHECKPOINT")]
        restores = [i for i, event in enumerate(self.events) if event[0] == "sql" and event[2] == str(self.seed)]
        self.assertEqual(len(checkpoints), 2)
        self.assertEqual(len(restores), 2)
        self.assertLess(restores[0], checkpoints[0])
        self.assertLess(checkpoints[0], restores[1])
        self.assertLess(restores[1], checkpoints[1])

    def test_checkpoint_failure_starts_no_child_and_removes_only_owned_database(self):
        original = self.pg.run
        def fail_checkpoint(url, sql=None, file=None, **kwargs):
            original(url, sql=sql, file=file, **kwargs)
            if sql == "CHECKPOINT":
                raise replay.BenchmarkError("Checkpoint deadline exceeded")
        self.pg.run = fail_checkpoint
        with self.assertRaisesRegex(replay.BenchmarkError, "Checkpoint deadline"):
            self.run_replay([])
        self.assertFalse(any(event[0] in {"start", "sample"} for event in self.events))
        self.assertRegex(self.events[-1][1], r'^DROP DATABASE "tsw92_bench_[a-f0-9]{12}" WITH \(FORCE\)$')
        result = json.loads((self.output / "result.json").read_text())
        self.assertEqual(result["status"], "failed")
        self.assertNotIn("checkpoint_phase", result)

    def test_final_signal_count_timeout_fails_acceptance_but_still_cleans_up(self):
        original = self.pg.query
        calls = 0
        def timeout_final(url, sql):
            nonlocal calls
            if "public.wire_signal_events" in sql:
                calls += 1
            if calls == 2:
                raise replay.BenchmarkError("bounded signal count timed out")
            return original(url, sql)
        self.pg.query = timeout_final
        result = self.run_replay([sample(), sample(pending=1), sample(generation="generation-b")])
        self.assertEqual(result["status"], "failed")
        self.assertEqual(result["signal_cardinality_error"], "BenchmarkError")
        self.assertNotIn("final_signal_cardinality", result)
        self.assert_cleanup_after_children()

    def test_failed_child_aborts_and_reaps_before_removing_owned_database(self):
        with self.assertRaisesRegex(replay.BenchmarkError, "child exited"):
            self.run_replay([sample(), sample()], failed_child="rank")
        self.assert_cleanup_after_children()
        result = json.loads((self.output / "result.json").read_text())
        self.assertEqual(result["status"], "failed")
        self.assertNotIn("wal_bytes", result)

    def test_growing_wal_aborts_run_and_cleans_up(self):
        full = sample()
        full["wal_directory_bytes"] = 600
        with self.assertRaisesRegex(replay.BenchmarkError, "byte cap"):
            self.run_replay([sample(), full])
        self.assert_cleanup_after_children()

    def test_counter_reset_aborts_before_reporting_a_comparison(self):
        reset = sample()
        reset["wal"]["stats_reset"] = "new-counter-epoch"
        with self.assertRaisesRegex(replay.BenchmarkError, "statistics reset"):
            self.run_replay([sample(), reset])
        self.assert_cleanup_after_children()

    def test_backward_lsn_aborts_and_cleans_up_without_a_valid_span(self):
        backwards = sample(wal_bytes=140)
        backwards["wal_insert_lsn"] = "0/1"
        with self.assertRaisesRegex(replay.BenchmarkError, "LSN moved backwards"):
            self.run_replay([sample(), backwards])
        self.assert_cleanup_after_children()
        result = json.loads((self.output / "result.json").read_text())
        self.assertEqual(result["status"], "failed")
        self.assertNotIn("wal_lsn_span_bytes", result)

    def test_unconfirmed_process_shutdown_never_drops_the_database(self):
        with patch.object(replay, "stop_processes", side_effect=subprocess.TimeoutExpired("child", 5)):
            with self.assertRaises(subprocess.TimeoutExpired):
                self.run_replay([sample(), sample(pending=1), sample(generation="generation-b")])
        self.assertFalse(any(event[0] == "sql" and (event[1] or "").startswith("DROP") for event in self.events))
        evidence = json.loads((self.output / "result.json").read_text())
        self.assertEqual(evidence["status"], "failed")
        self.assertEqual(evidence["cleanup_error"], "TimeoutExpired")
        self.assertEqual(evidence["database_retained"], evidence["database"])
        self.assertRegex(evidence["database_retained"], r"^tsw92_bench_[a-f0-9]{12}$")

    def test_seed_restore_failure_starts_no_child_and_removes_only_the_created_database(self):
        def fail_seed(url, sql=None, file=None):
            self.events.append(("sql", sql, str(file)))
            if file:
                raise replay.BenchmarkError("Invalid seed fixture")
        self.pg.run = fail_seed
        with self.assertRaisesRegex(replay.BenchmarkError, "Invalid seed"):
            self.run_replay([])
        self.assertFalse(any(event[0] == "start" for event in self.events))
        self.assertRegex(self.events[-1][1], r'^DROP DATABASE "tsw92_bench_[a-f0-9]{12}" WITH \(FORCE\)$')
        self.assertEqual(json.loads((self.output / "result.json").read_text())["status"], "failed")

    def test_config_rejects_credentials_before_network_or_output_creation(self):
        for key in ("WIRE_METADATA_API_KEY", "DATABASE_URL", "WIRE_ACTOR_HMAC_SECRET", "SERVICE_TOKEN", "PGPASSWORD"):
            config_path = self.root / "config.json"
            config_path.write_text(json.dumps({"common_environment": {key: "not-for-evidence"}}))
            forbidden_output = self.root / "rejected-output"
            with self.subTest(key=key), \
                 patch.object(replay.os.sys, "argv", [str(MODULE_PATH), str(config_path), "--output", str(forbidden_output)]), \
                 patch.object(replay, "archive_plan") as archive:
                with self.assertRaisesRegex(replay.BenchmarkError, "Keep credentials out"):
                    replay.main()
                archive.assert_not_called()
                self.assertFalse(forbidden_output.exists())

    def test_snapshot_marker_does_not_accept_a_still_running_ingester(self):
        self.config["maximum_seconds"] = 0.5
        result = self.run_replay([sample()] + [sample(generation=str(n)) for n in range(10)], ingest_status=None)
        self.assertEqual(result["status"], "failed")
        self.assertIn("snapshot incomplete", result["acceptance_errors"][0])
        self.assert_cleanup_after_children()

    def test_missing_named_actor_key_fails_before_network_or_output_creation(self):
        config_path = self.root / "missing-key-config.json"
        config_path.write_text(json.dumps({"common_environment": {},
            "actor_hmac_secret_environment": "TEST_MISSING_ACTOR_KEY"}))
        output = self.root / "missing-key-output"
        with patch.dict(replay.os.environ, {}, clear=True), \
             patch.object(replay.os.sys, "argv", [str(MODULE_PATH), str(config_path), "--output", str(output)]), \
             patch.object(replay, "archive_plan") as archive:
            with self.assertRaisesRegex(replay.BenchmarkError, "missing or empty"):
                replay.main()
            archive.assert_not_called()
            self.assertFalse(output.exists())

    def test_comparison_shares_one_actor_key_without_serializing_its_value(self):
        for configured in (False, True):
            with self.subTest(configured=configured):
                config = dict(self.config, observation_seconds=60, maximum_seconds=120,
                    seed_sql=str(self.seed), admin_url_environment="TEST_BENCH_URL",
                    archive_key_environment="TEST_ARCHIVE_KEY",
                    variants=[dict(self.variant, name="baseline"), self.variant])
                if configured:
                    config["actor_hmac_secret_environment"] = "TEST_SEEDED_ACTOR_KEY"
                config_path = self.root / ("actor-config-%s.json" % configured)
                config_path.write_text(json.dumps(config))
                output = self.root / ("actor-output-%s" % configured)
                secret = "isolated-preseed-actor-key-" + "a" * 32
                keys = []

                def run(config, variant, pg, admin_url, output, secrets, generation, seed):
                    env = replay.process_environment(config, variant, admin_url, generation, secrets)
                    keys.append(env["WIRE_ACTOR_HMAC_SECRET"])
                    self.assertNotIn("TEST_SEEDED_ACTOR_KEY", env)
                    # Later environment changes must not change the candidate's key.
                    replay.os.environ["TEST_SEEDED_ACTOR_KEY"] = "changed-after-baseline-" + "b" * 32
                    return {"variant": variant["name"], "status": "passed"}

                with patch.object(replay.os.sys, "argv", [str(MODULE_PATH), str(config_path), "--output", str(output)]), \
                     patch.dict(replay.os.environ, {"TEST_BENCH_URL": "postgresql://localhost:55492/admin",
                         "TEST_ARCHIVE_KEY": "fixture-only", "TEST_SEEDED_ACTOR_KEY": secret}), \
                     patch.object(replay, "archive_plan", return_value={}), \
                     patch.object(replay.Postgres, "query", return_value=0), \
                     patch.object(replay, "run_variant", side_effect=run):
                    replay.main()
                self.assertEqual(len(keys), 2)
                self.assertEqual(keys[0], keys[1])
                if configured:
                    self.assertEqual(keys[0], secret)
                else:
                    self.assertNotEqual(keys[0], secret)
                evidence = "".join(path.read_text() for path in output.rglob("*.json"))
                self.assertNotIn(keys[0], evidence)
                self.assertNotIn(secret, evidence)
                self.assertEqual(json.loads((output / "configuration.json").read_text()), config)

    def test_one_generation_cannot_pass_even_when_http_reads_succeed(self):
        result = self.run_replay([sample(), sample(), sample()])
        self.assertEqual(result["status"], "failed")
        self.assertIn("insufficient nonempty local generations/reads", result["acceptance_errors"])
        self.assert_cleanup_after_children()

    def test_fixed_observation_preserves_unresolved_backlog_as_failed_acceptance(self):
        result = self.run_replay([sample(), sample(pending=7), sample(pending=7, generation="generation-b")])
        self.assertTrue(result["observation_complete"])
        self.assertEqual(result["status"], "failed")
        self.assertEqual(result["final"]["actionable_count"], 7)
        self.assertEqual(result["final_signal_cardinality"]["total"], 3)
        self.assertIn("snapshot incomplete or unresolved actionable backlog", result["acceptance_errors"])
        self.assert_cleanup_after_children()
        self.assertFalse(any(event[0] == "sql" and "UPDATE" in (event[1] or "") for event in self.events))

    def test_failed_acceptance_still_observes_both_variants_and_exits_nonzero(self):
        config = dict(self.config, observation_seconds=60, maximum_seconds=120,
            seed_sql=str(self.seed), admin_url_environment="TEST_BENCH_URL",
            archive_key_environment="TEST_ARCHIVE_KEY",
            variants=[dict(self.variant, name="baseline"), self.variant])
        config_path = self.root / "comparison-config.json"
        config_path.write_text(json.dumps(config))
        output = self.root / "comparison-output"
        results = [{"variant":"baseline", "status":"failed", "observation_complete":True},
                   {"variant":"candidate", "status":"passed", "observation_complete":True}]
        with patch.object(replay.os.sys, "argv", [str(MODULE_PATH), str(config_path), "--output", str(output)]), \
             patch.dict(replay.os.environ, {"TEST_BENCH_URL":"postgresql://localhost:55492/admin", "TEST_ARCHIVE_KEY":"fixture-only"}), \
             patch.object(replay, "archive_plan", return_value={}), \
             patch.object(replay.Postgres, "query", return_value=0), \
             patch.object(replay, "run_variant", side_effect=results) as run:
            with self.assertRaisesRegex(replay.BenchmarkError, "observations completed but acceptance failed"):
                replay.main()
        self.assertEqual([call.args[1]["name"] for call in run.call_args_list], ["baseline", "candidate"])
        self.assertEqual(json.loads((output / "comparison.json").read_text()), results)

    def test_child_environment_pins_the_same_real_snapshot_and_isolates_sources(self):
        self.config["common_environment"].update({
            "DATABASE_URL": "postgresql://production/forbidden", "APP_ENV": "prod",
            "WIRE_CORPUS_EDGE_BASE_URL": "https://production.example", "JETSTREAM_REPLAY_SNAPSHOT_ONLY": "false",
        })
        self.run_replay([sample(), sample(pending=1), sample(generation="generation-b")])
        self.assertEqual([name for name, _ in self.environments], ["appview", "drain", "rank", "ingest"])
        for name, env in self.environments:
            with self.subTest(child=name):
                # AppView exercises production local serving against the same isolated
                # DB; its development mode intentionally requires Corpus Edge.
                self.assertEqual(env["APP_ENV"], "prod" if name == "appview" else "dev")
                self.assertIn("localhost:55492/tsw92_bench_", env["DATABASE_URL"])
                self.assertEqual(env["WIRE_CORPUS_EDGE_BASE_URL"], "")
                self.assertEqual(env["JETSTREAM_SOURCE_GENERATION"], self.generation)
                self.assertEqual(env["WIRE_INBOX_SOURCE_GENERATIONS"], self.generation)
                self.assertEqual(env["JETSTREAM_BOOTSTRAP_AFTER_SEQ"], "100")
                self.assertEqual(env["JETSTREAM_REPLAY_BEFORE_SEQ"], "200")
                self.assertEqual(env["JETSTREAM_REPLAY_SNAPSHOT_ONLY"], "true")
                self.assertEqual(env["JETSTREAM_EXIT_AFTER_SNAPSHOT"], "true")
                self.assertEqual(env["WIRE_RANK_INTERVAL_SECONDS"], "300")
                self.assertEqual(env["WIRE_GENERATION_RETENTION_SECONDS"], "7200")
                self.assertEqual(env["WIRE_EXTERNAL_SIGNAL_MODE"], "off")
        serialized = (self.output / "result.json").read_text() + (self.output / "samples.jsonl").read_text()
        self.assertNotIn("unit-test-only", serialized)
        self.assertNotIn("unit-test-gateway-secret", serialized)
        self.assertNotIn("DATABASE_URL", serialized)


if __name__ == "__main__":
    unittest.main()
