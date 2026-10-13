import importlib.util
from pathlib import Path
import unittest

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


if __name__ == "__main__":
    unittest.main()
