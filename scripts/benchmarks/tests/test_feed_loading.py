import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("feed_loading", Path(__file__).parents[1] / "feed_loading.py")
benchmark = importlib.util.module_from_spec(spec)
spec.loader.exec_module(benchmark)


class FeedLoadingTests(unittest.TestCase):
    def test_percentiles_use_nearest_rank_and_do_not_mutate_observations(self):
        values = list(range(100, 0, -1))
        self.assertEqual(benchmark.percentile(values, 50), 50)
        self.assertEqual(benchmark.percentile(values, 95), 95)
        self.assertEqual(values[0], 100)
        self.assertIsNone(benchmark.percentile([], 95))


if __name__ == "__main__":
    unittest.main()
