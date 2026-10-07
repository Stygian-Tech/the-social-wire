"""The disposable benchmark must reject unsafe targets before invoking Docker."""

import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

HARNESS = Path(__file__).resolve().parents[1] / "wire-rollup-benchmark.py"


class WireRollupBenchmarkSafetyTests(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory(prefix="wire-rollup-safety-")
        self.addCleanup(self.scratch.cleanup)
        self.root = Path(self.scratch.name)
        self.marker = self.root / "docker-called"
        self.output = self.root / "output"
        binary = self.root / "docker"
        binary.write_text(
            '#!/bin/sh\nprintf "called\\n" >> "$DOCKER_CALL_SENTINEL"\nexit 91\n'
        )
        binary.chmod(0o755)
        self.environment = dict(os.environ)
        self.environment.pop("DOCKER_HOST", None)
        self.environment.pop("DOCKER_CONTEXT", None)
        self.environment["PATH"] = str(self.root)
        self.environment["DOCKER_CALL_SENTINEL"] = str(self.marker)

    def rejected_before_docker(self, arguments, expected_message, environment=None):
        result = subprocess.run(
            [
                sys.executable,
                str(HARNESS),
                "query",
                "--container",
                "tsw92-safety-test",
                "--output",
                str(self.output),
                *arguments,
            ],
            capture_output=True,
            text=True,
            env=environment or self.environment,
            timeout=10,
        )
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn(expected_message, result.stderr)
        self.assertFalse(self.marker.exists(), "Unsafe input reached Docker")
        self.assertFalse(self.output.exists(), "Unsafe input created output")

    def test_rejects_non_disposable_targets(self):
        for arguments, message in [
            (["--container", "production"], "disposable tsw92- prefix"),
            (["--container", "tsw92-test;touch"], "disposable tsw92- prefix"),
            (["--database", "postgres"], "disposable tsw92_ prefix"),
            (["--database", "tsw92_test;drop"], "disposable tsw92_ prefix"),
        ]:
            with self.subTest(arguments=arguments):
                self.rejected_before_docker(arguments, message)

    def test_rejects_invalid_key_counts(self):
        for value, message in [
            ("-1", "between 0 and 10000"),
            ("10001", "between 0 and 10000"),
            ("invalid", "comma-separated integers"),
            ("1,1", "must be unique"),
            (",".join(str(value) for value in range(11)), "one to ten key counts"),
        ]:
            with self.subTest(value=value):
                self.rejected_before_docker([f"--key-counts={value}"], message)

    def test_rejects_unbounded_repetitions(self):
        for value in ["0", "21"]:
            with self.subTest(value=value):
                self.rejected_before_docker(
                    ["--repetitions", value], "Repetitions must be between 1 and 20"
                )

    def test_rejects_invalid_combined_key_counts(self):
        for value in ["-1", "10001"]:
            with self.subTest(value=value):
                self.rejected_before_docker(
                    [f"--combined-key-count={value}"],
                    "Combined key count must be between 0 and 10000",
                )

    def test_rejects_unbounded_paired_workloads(self):
        for arguments, message in [
            (["--duration-seconds", "4"], "Duration must be between 5 and 60"),
            (["--duration-seconds", "61"], "Duration must be between 5 and 60"),
            (["--transactions-per-second", "0"], "Transaction rate must be between 1 and 10000"),
            (["--transactions-per-second", "10001"], "Transaction rate must be between 1 and 10000"),
            (["--pairs", "1"], "Pairs must be between 2 and 10"),
            (["--pairs", "11"], "Pairs must be between 2 and 10"),
        ]:
            with self.subTest(arguments=arguments):
                self.rejected_before_docker(arguments, message)

    def test_rejects_remote_docker_before_connecting(self):
        environment = dict(self.environment, DOCKER_HOST="tcp://example.invalid:2375")
        self.rejected_before_docker(
            [], "require a local Docker Unix socket", environment
        )

    def test_preserves_completed_evidence(self):
        self.output.mkdir()
        marker = self.output / "query-summary.json"
        marker.write_text('{"preserve":true}')
        result = subprocess.run(
            [
                sys.executable,
                str(HARNESS),
                "query",
                "--container",
                "tsw92-safety-test",
                "--output",
                str(self.output),
            ],
            capture_output=True,
            text=True,
            env=self.environment,
            timeout=10,
        )
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn("already contains a completed run", result.stderr)
        self.assertEqual(marker.read_text(), '{"preserve":true}')
        self.assertFalse(self.marker.exists())


if __name__ == "__main__":
    unittest.main()


class GoRollupSQLContractTests(unittest.TestCase):
    def module(self):
        import importlib.util
        spec = importlib.util.spec_from_file_location("rollup_sql", HARNESS.with_name("rollup_sql.py"))
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module

    def test_actual_go_sql_and_window_bindings(self):
        import datetime
        module = self.module()
        root = HARNESS.parents[2]
        statements = module.load(root)
        at = datetime.datetime(2026, 9, 13, 12, tzinfo=datetime.timezone.utc)
        for incremental in (False, True):
            query = module.aggregate(statements, incremental, at)
            self.assertTrue(query.startswith(("SELECT", "WITH")), query[:100])
            self.assertNotIn("$1", query)
            for hours in (0, -1, -24, -168):
                self.assertIn((at + datetime.timedelta(hours=hours)).isoformat(), query)
            refresh = module.refresh(statements, incremental, at)
            self.assertIn(statements["rollupUpdateSQL"], refresh)
            self.assertIn(statements["rollupInsertSQL"], refresh)
            self.assertTrue(refresh.endswith("COMMIT;"))

    def test_rejects_missing_constants_and_changed_runtime_bindings(self):
        module = self.module()
        root = HARNESS.parents[2]
        with tempfile.TemporaryDirectory() as directory:
            from shutil import copyfile
            scratch = Path(directory)
            target = scratch / "packages/go/wireworkercore"
            target.mkdir(parents=True)
            for name in ("signal_rollup_sql.go", "signal_rollup_store.go"):
                copyfile(root / "packages/go/wireworkercore" / name, target / name)
            path = target / "signal_rollup_store.go"
            original = path.read_text()
            path.write_text(original.replace('at.Add(-24*time.Hour)', 'at.Add(-12*time.Hour)'))
            with self.assertRaisesRegex(ValueError, 'bind'):
                module.load(scratch)
            path.write_text(original)
            path = target / "signal_rollup_sql.go"
            path.write_text(path.read_text().replace('const rollupStageFullSQL', 'const renamedStageFullSQL'))
            with self.assertRaisesRegex(ValueError, 'constants'):
                module.load(scratch)
            with self.assertRaisesRegex(ValueError, 'placeholders'):
                module.render('SELECT $2', ['value'])
