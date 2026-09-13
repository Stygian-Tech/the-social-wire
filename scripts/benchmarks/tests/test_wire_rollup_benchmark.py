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
