import importlib.util
from pathlib import Path
import unittest


MODULE_PATH = Path(__file__).resolve().parents[1] / "metadata_claim_replay.py"
SPEC = importlib.util.spec_from_file_location("metadata_claim_replay", MODULE_PATH)
replay = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(replay)


class MetadataClaimReplayTests(unittest.TestCase):
    def test_accepts_explicit_local_disposable_targets(self):
        for host in ("127.0.0.1", "localhost", "[::1]"):
            with self.subTest(host=host):
                replay.validate_target(f"postgresql://user:pass@{host}:55414/tsw114_query")

    def test_rejects_application_remote_and_redirected_targets(self):
        targets = [
            "", "postgresql://localhost/postgres", "postgresql://localhost/socialwire",
            "postgresql://postgres.railway.internal/tsw114_query",
            "postgresql://example.com/tsw114_query",
            "postgresql://localhost/tsw114_query?host=example.com",
            "postgresql://localhost/tsw114_query?options=-csearch_path=public",
            "postgresql://localhost/tsw114_query#ignored",
            "postgresql://localhost/tsw114_", "postgresql://localhost/tsw114_a/other",
            "postgresql://localhost:0/tsw114_query",
            "postgresql://localhost:99999/tsw114_query",
            "file:///tsw114_query",
        ]
        for target in targets:
            with self.subTest(target=target):
                with self.assertRaises(ValueError):
                    replay.validate_target(target)

    def test_decodes_psql_multiline_json_documents(self):
        values = list(replay.json_documents('  [\n {"Plan": {"Node Type": "Sort"}}\n]\n["a", "b"]\n'))
        self.assertEqual(values[0][0]["Plan"]["Node Type"], "Sort")
        self.assertEqual(values[1], ["a", "b"])


if __name__ == "__main__":
    unittest.main()
