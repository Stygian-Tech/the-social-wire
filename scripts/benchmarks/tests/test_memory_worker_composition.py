"""Both real adapter validators compose one isolated scope/runtime; fixtures are not load evidence."""
import json
from pathlib import Path
import tempfile
import unittest
import test_trial_replay_adapter as replay_tests
import test_memory_ranking_adapter as ranking_tests

replay = replay_tests.m
ranking = ranking_tests.ranking


class WorkerCompositionTests(unittest.TestCase):
    def test_same_runtime_passes_both_adapters_and_five_ports_do_not_collide(self):
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw); (root / "replay").mkdir(); (root / "ranking").mkdir()
            config, rank_runtime, identity = ranking_tests.RankingAdapterTests().fixture(root / "ranking")
            replay_config, drain_runtime = replay_tests.ReplayAdapterTests().fixture(root / "replay")
            for key in ("observation_seconds", "restart_grace_seconds", "sample_seconds", "maximum_queue_rows"):
                config[key] = replay_config[key]
            config["runner"]["throughput_window_seconds"] = replay_config["runner"]["throughput_window_seconds"]
            config["replay"] = replay_config["replay"]
            config["replay_receipts"] = replay_config["replay_receipts"]
            runtime = drain_runtime | rank_runtime
            runtime_file = Path(config["ranking"]["runtime_environment_file"])
            def pin():
                runtime_file.write_text(json.dumps(runtime))
                ranking_tests.RankingAdapterTests().repin(config)
                manifest = Path(config["runner"]["binary_manifest_file"])
                data = json.loads(manifest.read_text())
                data["adapters"]["replay"] = replay.digest(replay.__file__)
                data["workers"] = {"replay_" + key: config["replay"][key]["sha256"] for key in ("ingest", "drain")}
                manifest.write_text(json.dumps(data))
                config["binary_manifest_sha256"] = replay.digest(manifest)
            pin()
            _, replay_runtime = replay.validate(config)
            coordinator_runtime = ranking.load_runtime(config)
            ingest, drain = replay.child_environments(config, replay_runtime, identity)
            coordinator = ranking.child_environment(coordinator_runtime, "owned-trial", identity)
            self.assertEqual(len({int(ingest["PORT"]), int(drain["PORT"]), int(coordinator["PORT"]),
                                  int(coordinator["INDEXING_APPVIEW_HEALTH_PORT"]), int(coordinator["INDEXING_WIRE_HEALTH_PORT"])}), 5)
            self.assertEqual(ingest["JETSTREAM_SOURCE_GENERATION"], coordinator["WIRE_INBOX_SOURCE_GENERATIONS"])
            self.assertEqual(drain["DATABASE_URL"], coordinator["DATABASE_URL"])
            self.assertNotIn("JETSTREAM_API_KEY", coordinator)
            self.assertNotIn("JETSTREAM_API_KEY", drain)
            runtime["INDEXING_WIRE_HEALTH_PORT"] = str(config["replay"]["ingest_port"])
            pin()
            with self.assertRaises(replay.Error): replay.validate(config)
            with self.assertRaises(ranking.RankingError): ranking.load_runtime(config)
