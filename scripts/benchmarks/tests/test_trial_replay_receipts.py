"""Receipt contract tests. PostgreSQL tests use only their own disposable local DB."""
import copy
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import threading
import unittest
import urllib.parse
import uuid
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location("receipts", Path(__file__).resolve().parents[1] / "trial_replay_receipts.py")
m = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(m)


def configuration():
    return {"replay_receipts": {"module_sha256": m.hashlib.sha256(Path(m.__file__).read_bytes()).hexdigest(), "environment": "dev", "source_generation": "tsw92-replay-aaaaaaaaaaaa",
        "after_seq": 100, "before_seq": 200, "maximum_receipts": 100, "maximum_receipt_bytes": 1_000_000,
        "semantics": "unique_committed_acknowledged_events", "instrumentation_in_both_rounds": True}}


class ReceiptTests(unittest.TestCase):
    def test_source_range_and_overhead_fail_closed(self):
        c = configuration()
        m.scope(c)
        for key, value in [("environment", "prod"), ("source_generation", "wire-global-v4"),
                ("before_seq", 99), ("after_seq", True), ("maximum_receipts", 99),
                ("maximum_receipts", 10_000_001), ("semantics", "changed_content"),
                ("instrumentation_in_both_rounds", False)]:
            broken = copy.deepcopy(c); broken["replay_receipts"][key] = value
            with self.assertRaises(m.Error): m.scope(broken)

    def test_receipt_is_not_transport_or_approximate_counter(self):
        c = configuration()
        sample = {"completed": 5, "snapshot_complete": False, "drain_complete": True,
                  "receipt_bytes": 8192, "scope_matches": True, "instrumentation_valid": True}
        self.assertFalse(m.validated_progress(c, sample)["snapshot_complete"])
        for key, value in [("completed", True), ("completed", 101), ("snapshot_complete", 1),
                           ("scope_matches", False), ("instrumentation_valid", False)]:
            with self.assertRaises(m.Error): m.validated_progress(c, sample | {key: value})

    def test_provider_verification_happens_before_runtime_read_or_mutation(self):
        with patch.object(m.provider, "execute", side_effect=m.Error("protected")) as verify:
            with patch.object(m.provider, "private_path") as private:
                with self.assertRaises(m.Error): m.verified_connection(configuration(), {})
                verify.assert_called_once_with("identity", configuration(), {})
                private.assert_not_called()


@unittest.skipUnless(os.environ.get("TSW_RECEIPT_TEST_ADMIN_URL"), "requires explicitly disposable local Postgres")
class ReceiptPostgresTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        parsed = urllib.parse.urlsplit(os.environ["TSW_RECEIPT_TEST_ADMIN_URL"])
        if parsed.hostname not in {"localhost", "127.0.0.1", "::1"}:
            raise RuntimeError("Receipt integration tests refuse remote PostgreSQL")
        cls.database = "tsw92_receipt_test_" + uuid.uuid4().hex[:12]
        cls.psql = os.environ.get("TSW_RECEIPT_TEST_PSQL", "psql")
        cls.env = {k: v for k, v in os.environ.items() if not k.startswith("PG")}
        cls.env.update(PGHOST=parsed.hostname, PGPORT=str(parsed.port or 5432), PGUSER=urllib.parse.unquote(parsed.username or "postgres"),
                       PGPASSWORD=urllib.parse.unquote(parsed.password or ""), PGDATABASE=parsed.path.lstrip("/") or "postgres",
                       PGCONNECT_TIMEOUT="3", PGOPTIONS="-c statement_timeout=5000")
        cls.sql('CREATE DATABASE "' + cls.database + '"', admin=True)

    @classmethod
    def tearDownClass(cls):
        cls.sql('DROP DATABASE "' + cls.database + '" WITH (FORCE)', admin=True)

    @classmethod
    def sql(cls, statement, admin=False, check=True):
        env = cls.env.copy()
        if not admin: env["PGDATABASE"] = cls.database
        result = subprocess.run([cls.psql, "-XqAt", "-v", "ON_ERROR_STOP=1"], input=statement,
                                text=True, capture_output=True, env=env, timeout=10)
        if check and result.returncode:
            raise AssertionError("Disposable receipt SQL failed: " + result.stderr)
        return result

    def setUp(self):
        self.config = configuration()
        self.sql("""DROP SCHEMA IF EXISTS tsw92_trial_receipts CASCADE;
            DROP TABLE IF EXISTS wire_ingestion_inbox, wire_recommendation_journal,
              appview_jetstream_checkpoints, wire_recommendation_dependency_recovery CASCADE;
            CREATE UNLOGGED TABLE wire_ingestion_inbox(environment text, source_generation text, seq bigint,
              status text, applied_at timestamptz, expires_at timestamptz, PRIMARY KEY(environment,source_generation,seq));
            CREATE TABLE wire_recommendation_journal(environment text, source_generation text, seq bigint, status text,
              PRIMARY KEY(environment,source_generation,seq));
            CREATE TABLE appview_jetstream_checkpoints(environment text, source_generation text, replay_state text,
              replay_after_seq bigint, replay_before_seq bigint, replay_sealed_seq bigint);
            CREATE TABLE wire_recommendation_dependency_recovery(environment text, source_generation text, status text);""")
        self.sql(m.installation_sql(self.config))

    def insert(self, seq=101, status="applied"):
        return "INSERT INTO wire_ingestion_inbox VALUES('dev','tsw92-replay-aaaaaaaaaaaa',%s,'%s',now(),now()-interval '1 second');" % (seq, status)

    def sample(self):
        return json.loads(self.sql(m.progress_sql(self.config)).stdout)

    def test_commit_rollback_ttl_and_new_connection_duplicate(self):
        self.sql("BEGIN;" + self.insert() + "ROLLBACK;")
        self.assertEqual(self.sample()["completed"], 0)
        self.sql(self.insert())
        self.sql("DELETE FROM wire_ingestion_inbox WHERE expires_at<now();")
        self.assertEqual(self.sample()["completed"], 1)
        # Every call is a fresh backend. Re-staging after source loss cannot add credit.
        self.sql(self.insert())
        self.assertEqual(self.sample()["completed"], 1)
        self.sql("TRUNCATE wire_ingestion_inbox;")
        self.sql(self.insert())
        self.assertEqual(self.sample()["completed"], 1)

    def test_bulk_and_deferred_journal_are_deduplicated(self):
        self.sql(self.insert(101, "pending") + self.insert(102, "retry") + self.insert(103, "deferred"))
        self.sql("UPDATE wire_ingestion_inbox SET status='applied' WHERE seq IN(101,102);")
        self.assertEqual(self.sample()["completed"], 2)
        self.sql("INSERT INTO wire_recommendation_journal VALUES('dev','tsw92-replay-aaaaaaaaaaaa',103,'pending');")
        self.assertFalse(self.sample()["drain_complete"])
        self.sql("UPDATE wire_recommendation_journal SET status='resolved';")
        self.sql("UPDATE wire_ingestion_inbox SET status='applied' WHERE seq=103;")
        self.assertEqual(self.sample()["completed"], 3)
        self.sql("UPDATE wire_recommendation_journal SET status='deleted';")
        self.assertEqual(self.sample()["completed"], 3)

    def test_other_sources_failed_statuses_and_out_of_range(self):
        self.sql(self.insert(101, "dead_letter") + self.insert(102, "superseded"))
        self.sql("INSERT INTO wire_ingestion_inbox VALUES('dev','other-source',103,'applied',now(),now());")
        self.assertEqual(self.sample()["completed"], 0)
        self.assertFalse(self.sample()["drain_complete"])
        self.assertNotEqual(self.sql(self.insert(201), check=False).returncode, 0)
        self.assertEqual(self.sample()["completed"], 0)

    def test_completion_needs_exact_seal_and_resolved_dependencies(self):
        self.assertTrue(self.sample()["drain_complete"])
        self.assertFalse(self.sample()["snapshot_complete"])
        self.sql("INSERT INTO appview_jetstream_checkpoints VALUES('dev','tsw92-replay-aaaaaaaaaaaa','snapshot_complete',100,200,199);")
        self.assertFalse(self.sample()["snapshot_complete"])
        self.sql("UPDATE appview_jetstream_checkpoints SET replay_sealed_seq=200;")
        self.assertTrue(self.sample()["snapshot_complete"])
        self.sql("INSERT INTO wire_recommendation_dependency_recovery VALUES('dev','tsw92-replay-aaaaaaaaaaaa','pending');")
        self.assertFalse(self.sample()["drain_complete"])

    def test_concurrent_transactions_deduplicate_inbox_and_journal(self):
        env = self.env | {"PGDATABASE": self.database}
        first = subprocess.Popen([self.psql, "-XqAt", "-v", "ON_ERROR_STOP=1"], stdin=subprocess.PIPE,
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=env)
        try:
            first.stdin.write("BEGIN;" + self.insert() + "SELECT 'ready';\n"); first.stdin.flush()
            self.assertEqual(first.stdout.readline().strip(), "ready")
            result = []
            def second():
                result.append(self.sql("INSERT INTO wire_recommendation_journal VALUES('dev','tsw92-replay-aaaaaaaaaaaa',101,'resolved');", check=False))
            thread = threading.Thread(target=second); thread.start()
            first.stdin.write("COMMIT;\n"); first.stdin.close()
            first.wait(timeout=5); thread.join(timeout=8)
            self.assertFalse(thread.is_alive())
            self.assertEqual(result[0].returncode, 0)
            self.assertEqual(self.sample()["completed"], 1)
        finally:
            if first.poll() is None: first.kill(); first.wait()
            for stream in (first.stdin, first.stdout, first.stderr): stream.close()

    def test_reinstall_and_disabled_instrumentation_rejected(self):
        self.assertNotEqual(self.sql(m.installation_sql(self.config), check=False).returncode, 0)
        self.sql("ALTER TABLE wire_ingestion_inbox DISABLE TRIGGER tsw92_trial_inbox_ack;")
        with self.assertRaises(m.Error): m.validated_progress(self.config, self.sample())

    def test_trigger_with_same_name_on_wrong_relation_is_not_coverage(self):
        self.sql("DROP TRIGGER tsw92_trial_inbox_ack ON wire_ingestion_inbox;")
        self.sql("CREATE TRIGGER tsw92_trial_inbox_ack AFTER INSERT OR UPDATE OF status ON wire_recommendation_journal FOR EACH ROW EXECUTE FUNCTION tsw92_trial_receipts.acknowledge();")
        with self.assertRaises(m.Error): m.validated_progress(self.config, self.sample())

    def test_preexisting_source_cannot_gain_historical_receipts(self):
        self.sql("DROP SCHEMA tsw92_trial_receipts CASCADE;")
        self.sql(self.insert())
        self.assertNotEqual(self.sql(m.installation_sql(self.config), check=False).returncode, 0)

    @unittest.skipUnless(os.environ.get("TSW_RECEIPT_RESTART_CONTAINER"), "requires separately owned restart container")
    def test_real_database_restart_preserves_receipts_and_replay_deduplication(self):
        import re
        import time
        container = os.environ["TSW_RECEIPT_RESTART_CONTAINER"]
        if not re.fullmatch(r"tsw92-receipt-test-[a-f0-9]{12}", container):
            self.fail("Restart test refuses a container outside its owned receipt-test namespace")
        inspected = json.loads(subprocess.run(["docker", "inspect", container], check=True, capture_output=True, text=True).stdout)[0]
        mappings = inspected["NetworkSettings"]["Ports"]["5432/tcp"]
        self.assertTrue(any(entry["HostPort"] == self.env["PGPORT"] and entry["HostIp"] == "127.0.0.1" for entry in mappings))
        self.assertEqual(inspected["Config"]["Labels"].get("tsw92.receipt-test"), "owned-disposable")
        self.sql(self.insert())
        subprocess.run(["docker", "restart", "--time", "2", container], check=True, capture_output=True, timeout=15)
        for _ in range(30):
            if self.sql("SELECT 1", check=False).returncode == 0: break
            time.sleep(.1)
        self.assertEqual(self.sample()["completed"], 1)
        self.sql("DELETE FROM wire_ingestion_inbox;")
        self.sql(self.insert())
        self.assertEqual(self.sample()["completed"], 1)
