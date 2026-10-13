import importlib.util
from pathlib import Path
import unittest
from tempfile import TemporaryDirectory
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("feed_loading", Path(__file__).parents[1] / "feed_loading.py")
benchmark = importlib.util.module_from_spec(spec)
spec.loader.exec_module(benchmark)


class FeedLoadingTests(unittest.TestCase):
    def test_phase_capture_excludes_credentials_and_invalid_durations(self):
        headers = "HTTP/2 200\nAuthorization: secret\nSet-Cookie: private\nServer-Timing: auth;dur=0.4, source;dur=12.3, bad;dur=NaN\n"
        self.assertEqual(benchmark.phase_timings(headers), {"auth": 0.4, "source": 12.3})
        self.assertEqual(benchmark.phase_timings("server-timing: source-cache-hit;dur=0"), {"source-cache-hit": 0})

    def test_percentiles_use_nearest_rank_and_do_not_mutate_observations(self):
        values = list(range(100, 0, -1))
        self.assertEqual(benchmark.percentile(values, 50), 50)
        self.assertEqual(benchmark.percentile(values, 95), 95)
        self.assertEqual(values[0], 100)
        self.assertIsNone(benchmark.percentile([], 95))

    def test_continuation_paces_seed_before_first_measured_request(self):
        events = []
        sample = {"status": 200, "transport_failed": False, "transport_exit_code": 0, "total_ms": 10}

        def probe(origin, feed, cursor=None):
            events.append(("probe", cursor))
            return sample.copy(), "continuation-token"

        with TemporaryDirectory() as directory:
            output = Path(directory) / "report.json"
            argv = ["feed_loading.py", "--origin", "https://example.com", "--feed", "sports", "--samples", "2", "--continuation", "--interval", "1.1", "--output", str(output)]
            with patch("sys.argv", argv), patch.object(benchmark, "probe", side_effect=probe), patch.object(benchmark.time, "sleep", side_effect=lambda interval: events.append(("sleep", interval))), patch("builtins.print"):
                benchmark.main()
            self.assertTrue(output.exists())
        self.assertEqual(events, [("probe", None), ("sleep", 1.1), ("probe", "continuation-token"), ("sleep", 1.1), ("probe", "continuation-token")])

    def test_missing_continuation_stops_without_sleep_or_measurements(self):
        with TemporaryDirectory() as directory:
            output = Path(directory) / "report.json"
            argv = ["feed_loading.py", "--origin", "https://example.com", "--feed", "sports", "--continuation", "--output", str(output)]
            with patch("sys.argv", argv), patch.object(benchmark, "probe", return_value=({"status": 503}, None)) as probe, patch.object(benchmark.time, "sleep") as sleep, patch("sys.stderr"):
                with self.assertRaises(SystemExit) as stopped:
                    benchmark.main()
            self.assertEqual(stopped.exception.code, 2)
            probe.assert_called_once_with("https://example.com", "sports")
            sleep.assert_not_called()
            self.assertFalse(output.exists())


if __name__ == "__main__":
    unittest.main()
