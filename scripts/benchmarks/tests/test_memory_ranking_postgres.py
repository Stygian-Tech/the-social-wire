"""Opt-in publication-observer SQL tests on one explicitly disposable local database.

These exercise real transaction visibility, not ranking throughput or database restart recovery.
"""
import json
import os
from pathlib import Path
import selectors
import subprocess
import sys
import time
import unittest
import urllib.parse
import uuid

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
import memory_ranking_evidence as evidence

URL = os.environ.get("RANKING_TEST_DATABASE_URL")


def fixture_environment(url):
    connection = urllib.parse.urlsplit(url)
    if (connection.scheme not in {"postgres", "postgresql"}
            or connection.hostname not in {"127.0.0.1", "localhost", "::1"}
            or connection.port == 0 or not connection.path.startswith("/") or len(connection.path) <= 1
            or connection.query not in ("", "sslmode=disable") or connection.fragment):
        raise RuntimeError("Ranking SQL tests require an explicit disposable loopback PostgreSQL database")
    return {key: os.environ[key] for key in ("PATH", "LANG") if key in os.environ} | {
        "PGHOST": connection.hostname, "PGPORT": str(connection.port or 5432),
        "PGDATABASE": urllib.parse.unquote(connection.path[1:]),
        "PGUSER": urllib.parse.unquote(connection.username or "postgres"),
        "PGPASSWORD": urllib.parse.unquote(connection.password or ""), "PGCONNECT_TIMEOUT": "2",
        "PGSSLMODE": "disable", "PGAPPNAME": "tsw114-ranking-fixture"}


class RankingFixtureConfigurationTests(unittest.TestCase):
    def test_ci_and_local_loopback_urls_preserve_explicit_target(self):
        for host, port, database in (("127.0.0.1", "5432", "postgres"),
                ("localhost", "55414", "tsw114_ranking_adapter"), ("::1", "5432", "fixture")):
            authority = "[::1]" if host == "::1" else host
            environment = fixture_environment(f"postgresql://postgres:fixture%40password@{authority}:{port}/{database}?sslmode=disable")
            self.assertEqual((environment["PGHOST"], environment["PGPORT"], environment["PGDATABASE"]), (host, port, database))
            self.assertEqual(environment["PGPASSWORD"], "fixture@password")
            self.assertNotIn("PGOPTIONS", environment)
        self.assertEqual(fixture_environment("postgresql://localhost/postgres")["PGPORT"], "5432")

    def test_remote_hosts_and_connection_option_overrides_fail_before_sql(self):
        for url in ("postgresql://postgres.railway.internal/railway", "postgresql://example.com/postgres",
                "postgresql://127.0.0.1/", "postgresql://127.0.0.1:0/postgres",
                "postgresql://127.0.0.1/postgres?host=remote.example", "postgresql://127.0.0.1/postgres?options=-csearch_path=public",
                "postgresql://127.0.0.1/postgres#fragment", "https://127.0.0.1/postgres"):
            with self.subTest(url=url), self.assertRaises(RuntimeError): fixture_environment(url)


@unittest.skipUnless(URL, "Set RANKING_TEST_DATABASE_URL for the dedicated local fixture")
class RankingPostgresTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.environment = fixture_environment(URL)
        cls.psql = os.environ.get("RANKING_TEST_PSQL", "psql")
        # A dedicated schema avoids taking ownership of any preexisting fixture tables.
        cls.schema = "ranking_test_" + uuid.uuid4().hex
        cls.sql(f"CREATE SCHEMA {cls.schema}")
        cls.addClassCleanup(cls.sql, f"DROP SCHEMA {cls.schema} CASCADE")
        # Never fall back to public tables, including if fixture setup fails partway.
        cls.environment["PGOPTIONS"] = "-c search_path=" + cls.schema
        migration = ROOT.parents[1] / "database/migrations/20260820120000_add_wire_discovery_feed.sql"
        source = migration.read_text()
        generation = source[source.index("CREATE TABLE IF NOT EXISTS wire_rank_generations ("):]
        # Retain the actual generation/item/feed table declarations and constraints.
        end = generation.index("PRIMARY KEY (feed_key, language_bucket)")
        generation = generation[:generation.index(");", end) + 2]
        cls.sql("CREATE TABLE wire_items (canonical_key TEXT PRIMARY KEY);" + generation)
        cls.sql((ROOT.parents[1] / "database/migrations/20260830190000_add_fenced_role_leases.sql").read_text())

    @classmethod
    def sql(cls, query):
        result = subprocess.run([cls.psql, "-X", "-qAt", "-v", "ON_ERROR_STOP=1"], input=query.encode(),
            env=cls.environment, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=5)
        if result.returncode:
            raise RuntimeError("Disposable ranking fixture SQL failed")
        return result.stdout.decode().strip()

    def setUp(self):
        self.sql("TRUNCATE wire_feed_state, wire_ranked_items, wire_rank_generations, wire_items, operations_role_leases")
        self.config = {"target": {"database": self.environment["PGDATABASE"]}, "ranking": {
            "supported_languages": ["und", "en"], "config_version": "wire-v10", "maximum_stale_seconds": 720}}
        self.after = 0
        self.state = evidence.RankingEvidence(self.config, "fixture-owned", self.observe(), time.monotonic())
        self.after = self.state.after
        self.sql("""INSERT INTO operations_role_leases
            SELECT 'dev', role, 'fixture-owned', 1, clock_timestamp(), clock_timestamp() + interval '1 hour', NULL, clock_timestamp()
            FROM unnest(ARRAY['indexing.appview-coordinator', 'indexing.wire-materializer']) role""")

    def observe(self):
        # Execute the exact production observer query and transaction bounds with the
        # fixture-only schema selected in libpq. The executable observer never accepts PGOPTIONS.
        return json.loads(self.sql("BEGIN READ ONLY; SET LOCAL statement_timeout='2s'; SET LOCAL lock_timeout='500ms'; "
            + evidence.observation_sql(self.after) + "; COMMIT;"))

    def accept(self):
        return self.state.accept(self.observe(), time.monotonic())

    def generation_sql(self, language, generated):
        generation = str(uuid.uuid4())
        return f"""INSERT INTO wire_items VALUES ('{generation}');
            INSERT INTO wire_rank_generations
              (generation_id, language_bucket, status, config_version, generated_at, committed_at, expires_at, ranked_count)
              VALUES ('{generation}', '{language}', 'committed', 'wire-v10', to_timestamp({generated}),
                to_timestamp({generated}), clock_timestamp() + interval '2 hours', 1);
            INSERT INTO wire_ranked_items (generation_id, position, canonical_key, score)
              VALUES ('{generation}', 0, '{generation}', 1);
            INSERT INTO wire_feed_state (feed_key, language_bucket, active_generation_id)
              VALUES ('wire', '{language}', '{generation}') ON CONFLICT (feed_key, language_bucket)
              DO UPDATE SET active_generation_id=EXCLUDED.active_generation_id;"""

    def session(self, query):
        process = subprocess.Popen([self.psql, "-X", "-qAt", "-v", "ON_ERROR_STOP=1"], env=self.environment,
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        process.stdin.write(("BEGIN; " + query + " SELECT 'fixture-ready';\n").encode()); process.stdin.flush()
        with selectors.DefaultSelector() as ready:
            ready.register(process.stdout, selectors.EVENT_READ)
            if not ready.select(timeout=3) or process.stdout.readline().strip() != b"fixture-ready":
                self.close_session(process)
                self.fail("Owned fixture transaction did not become ready")
        return process

    @staticmethod
    def close_session(process):
        if process.poll() is None:
            process.terminate()
        process.wait(timeout=3)
        process.stdin.close(); process.stdout.close()

    def test_all_languages_require_visible_atomic_commit_and_not_generation_timestamp(self):
        generated = self.sql("SELECT extract(epoch FROM clock_timestamp())")
        self.sql(self.generation_sql("und", generated))
        self.assertEqual(self.accept()["completed"], 0)
        transaction = self.session(self.generation_sql("en", generated))
        try:
            self.assertEqual(self.accept()["completed"], 0, "Uncommitted language must not complete a cycle")
            transaction.communicate(b"COMMIT;\n", timeout=3)
            self.assertEqual(transaction.returncode, 0)
        finally:
            self.close_session(transaction)
        complete = self.accept()
        self.assertEqual(complete["completed"], 1)
        self.assertGreater(evidence.timestamp(complete["new_cycles"][0]["first_observed_complete_at"]), evidence.timestamp(generated))
        self.assertEqual(self.accept()["completed"], 1)

    def test_authority_reacquisition_excludes_incomplete_old_segment_and_rejects_foreign_owner(self):
        generated = self.sql("SELECT extract(epoch FROM clock_timestamp())")
        self.sql(self.generation_sql("und", generated))
        self.assertEqual(self.accept()["completed"], 0)
        self.sql("UPDATE operations_role_leases SET released_at=clock_timestamp()")
        self.assertEqual(self.accept()["status"], "awaiting_authority")
        self.sql("UPDATE operations_role_leases SET acquired_at=clock_timestamp(), fencing_token=2, released_at=NULL")
        self.sql(self.generation_sql("en", generated))
        self.assertEqual(self.accept()["completed"], 0, "Late old-segment language cannot become owned new-fence work")
        self.sql("UPDATE wire_rank_generations SET status='superseded'")
        generated = self.sql("SELECT extract(epoch FROM clock_timestamp())")
        self.sql(self.generation_sql("und", generated) + self.generation_sql("en", generated))
        self.assertEqual(self.accept()["completed"], 1)
        self.sql("UPDATE operations_role_leases SET owner_id='foreign-owner', fencing_token=3")
        with self.assertRaises(evidence.RankingError): self.accept()

    def test_table_lock_hits_local_query_budget_without_changing_connection_defaults(self):
        transaction = self.session("LOCK TABLE wire_rank_generations IN ACCESS EXCLUSIVE MODE;")
        try:
            start = time.monotonic()
            with self.assertRaises(RuntimeError): self.observe()
            self.assertLess(time.monotonic() - start, 2)
        finally:
            self.close_session(transaction)
        self.assertEqual(self.sql("SHOW statement_timeout; SHOW lock_timeout"), "0\n0")
        self.assertEqual(self.accept()["completed"], 0)


if __name__ == "__main__": unittest.main()
