"""Usage capture safety tests; all Railway CLI responses are fake."""

import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch


MODULE_PATH = Path(__file__).resolve().parents[1] / "capture_railway_usage.py"
SPEC = importlib.util.spec_from_file_location("capture_railway_usage", MODULE_PATH)
usage = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(usage)
PROJECT = "19eba29f-9229-4f8d-8b3c-44cbb839d656"
START, END = "2026-01-01T00:00:00Z", "2026-01-08T00:00:00Z"
ROWS = [{"measurement": "CPU_USAGE", "value": 2.125,
         "tags": {"serviceId": "deleted-service", "environmentId": "dev"}},
        {"measurement": "BACKUP_USAGE_GB", "value": 0,
         "tags": {"serviceId": None, "environmentId": "production"}}]


def cli_response(payload=None, status=0, stdout=None):
    return subprocess.CompletedProcess(["railway"], status,
        stdout=json.dumps(payload if payload is not None else {"data": {"usage": ROWS}}) if stdout is None else stdout,
        stderr="private CLI diagnostic must not escape")


class UsageCaptureTests(unittest.TestCase):
    def test_fixed_read_only_query_preserves_window_grouping_deleted_usage_and_values(self):
        with patch.object(usage.subprocess, "run", return_value=cli_response()) as run:
            result = usage.capture(PROJECT, START, END)
        command = run.call_args.args[0]
        self.assertEqual(command[:2], ["railway", "api"])
        self.assertEqual(command[2], usage.QUERY)
        self.assertTrue(command[2].startswith("query CostUsage("))
        self.assertIn("includeDeleted: true", command[2])
        self.assertIn("groupBy: [SERVICE_ID, ENVIRONMENT_ID]", command[2])
        self.assertEqual(json.loads(command[4]), {"project": PROJECT, "start": START, "end": END})
        self.assertEqual(run.call_args.kwargs["timeout"], 60)
        self.assertNotIn("shell", run.call_args.kwargs)
        self.assertEqual(result["usage"], ROWS)
        self.assertEqual(result["requested_window_utc"], {"start": START, "end": END})
        self.assertEqual(set(result["raw_units"]), set(usage.MEASUREMENTS))
        self.assertTrue(all("unconverted" in unit for unit in result["raw_units"].values()))
        self.assertIsNotNone(usage.utc_timestamp(result["captured_at_utc"]))

    def test_invalid_or_unbounded_inputs_never_call_cli(self):
        cases = [("not-a-project", START, END), (PROJECT, END, START), (PROJECT, START, START),
                 (PROJECT, START, "2026-02-02T00:00:00Z"), (PROJECT, "2026-01-01", END),
                 (PROJECT, "2026-01-01T00:00:00-06:00", END), (PROJECT, "2026-02-30T00:00:00Z", END),
                 (PROJECT, "2999-01-01T00:00:00Z", "2999-01-02T00:00:00Z")]
        for args in cases:
            with self.subTest(args=args), patch.object(usage.subprocess, "run") as run:
                with self.assertRaises(usage.CaptureError):
                    usage.capture(*args)
                run.assert_not_called()

    def test_utc_precision_and_maximum_window_are_preserved(self):
        start, end = "2026-01-01T00:00:00.123456+00:00", "2026-02-01T00:00:00.123456+00:00"
        with patch.object(usage.subprocess, "run", return_value=cli_response()):
            result = usage.capture(PROJECT, start, end)
        self.assertEqual(result["requested_window_utc"], {"start": start, "end": end})

    def test_graphql_partial_errors_and_cli_failures_do_not_leak_diagnostics(self):
        for response in (cli_response(status=1), cli_response({"errors": [{"message": "private-token"}], "data": {"usage": ROWS}}),
                         cli_response(stdout="invalid private-token")):
            with self.subTest(response=response), patch.object(usage.subprocess, "run", return_value=response):
                with self.assertRaises(usage.CaptureError) as raised:
                    usage.capture(PROJECT, START, END)
                self.assertNotIn("private", str(raised.exception))
        for error in (FileNotFoundError("private-path"), subprocess.TimeoutExpired("private-token", 60)):
            with patch.object(usage.subprocess, "run", side_effect=error):
                with self.assertRaises(usage.CaptureError) as raised:
                    usage.capture(PROJECT, START, END)
                self.assertNotIn("private", str(raised.exception))

    def test_missing_and_invalid_measurements_fail_instead_of_becoming_zero(self):
        for payload in ({}, {"data": {"usage": None}}, {"data": {"usage": [None]}},
                        {"data": {"usage": [dict(ROWS[0], value=True)]}},
                        {"data": {"usage": [dict(ROWS[0], value=float("nan"))]}},
                        {"data": {"usage": [dict(ROWS[0], measurement="UNKNOWN")]}},
                        {"data": {"usage": [dict(ROWS[0], tags={"serviceId": "a"})]}}):
            with self.subTest(payload=payload), patch.object(usage.subprocess, "run", return_value=cli_response(payload)):
                with self.assertRaises(usage.CaptureError):
                    usage.capture(PROJECT, START, END)
        with patch.object(usage.subprocess, "run", return_value=cli_response({"data": {"usage": []}})):
            self.assertEqual(usage.capture(PROJECT, START, END)["usage"], [])

    def test_output_is_private_new_file_and_omits_unrequested_response_data(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "usage.json"
            argv = [str(MODULE_PATH), "--project", PROJECT, "--start", START, "--end", END, "--output", str(output)]
            payload = {"data": {"usage": ROWS}, "extensions": {"private-token": "must-not-escape"}}
            with patch("sys.argv", argv), patch.object(usage.subprocess, "run", return_value=cli_response(payload)) as run:
                usage.main()
                self.assertEqual(output.stat().st_mode & 0o777, 0o600)
                self.assertNotIn("private-token", output.read_text())
                original = output.read_bytes()
                with self.assertRaisesRegex(usage.CaptureError, "already exists"):
                    usage.main()
                self.assertEqual(run.call_count, 1)
                self.assertEqual(output.read_bytes(), original)

    def test_failure_leaves_no_output_artifact(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "usage.json"
            argv = [str(MODULE_PATH), "--project", PROJECT, "--start", START, "--end", END, "--output", str(output)]
            with patch("sys.argv", argv), patch.object(usage.subprocess, "run", return_value=cli_response(status=1)):
                with self.assertRaises(usage.CaptureError):
                    usage.main()
            self.assertFalse(output.exists())


if __name__ == "__main__":
    unittest.main()
