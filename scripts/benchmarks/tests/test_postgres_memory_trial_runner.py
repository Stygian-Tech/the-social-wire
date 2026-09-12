"""Local safety tests only. No HTTP, hosted service or representative load is run."""
import copy
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch
from test_postgres_memory_trial import configuration, probe

SPEC = importlib.util.spec_from_file_location("runner", Path(__file__).resolve().parents[1] / "postgres_memory_trial_runner.py")
m = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(m)


class RunnerTests(unittest.TestCase):
    def fixture(self, directory):
        c = configuration()
        token = directory / "token"; token.write_text("test-only"); token.chmod(0o600)
        adapter = directory / "adapter"; adapter.write_text("#!/bin/sh\nprintf '{}'\n"); adapter.chmod(0o700)
        adapters = {name: {"path": str(adapter), "sha256": m.digest(adapter)} for name in ("identity", "probe", "signer", "replay", "ranking", "restart")}
        binary = directory / "binary.json"; binary.write_text(json.dumps({"adapters": {name: value["sha256"] for name, value in adapters.items()}}))
        c["binary_manifest_sha256"] = m.digest(binary)
        c["runner"] = {"project_id": c["target"]["project_id"], "environment_id": c["target"]["environment_id"],
            "service_id": "00000005-0000-0000-0000-000000000000", "concurrency": 2, "request_timeout_seconds": 2,
            "token_file": str(token), "binary_manifest_file": str(binary), "adapters": adapters,
            "minimum_replay_per_minute": 10, "minimum_rankings_per_minute": 1, "throughput_window_seconds": 60}
        c["read_targets"] = {"gateway": {"origin": "http://tsw92-gateway.railway.internal:8080", "service_id": "00000006-0000-0000-0000-000000000000"}}
        trace = directory / "trace.json"; trace.write_text(json.dumps({"dataset": "reviewed_authenticated_trace", "source_evidence": "fixture-only",
            "rates": {"mixed": 1, "burst": 2, "recovery": 1}, "requests": [{"id": key, "target": "gateway", "category": key, "path": {"sidebar": "/v1/publications/sidebar", "bootstrap": "/v1/appview/bootstrap-stream", "pagination": "/v1/appview/entries?authorDid=did:plc:test", "detail": "/v1/appview/entry?entryId=entry-one", "language_feed": "/xrpc/app.thesocialwire.discovery.getWire?lang=en"}[key]} for key in sorted(m.CATEGORIES)]}))
        c["workload_sha256"] = m.digest(trace)
        env = {m.trial.IDENTITIES[key]: c["runner"][key] for key in ("project_id", "environment_id", "service_id")}
        return c, trace, env

    def test_identity_trace_adapter_and_token_fail_closed(self):
        with tempfile.TemporaryDirectory() as raw:
            directory = Path(raw); c, trace, env = self.fixture(directory)
            self.assertEqual(len(m.validate_inputs(c, trace, env)["requests"]), 5)
            mutations = [lambda x: x["runner"].update(service_id=c["target"]["service_id"]),
                lambda x: x.update(workload_sha256="f" * 64),
                lambda x: x["read_targets"]["gateway"].update(origin="https://api.thesocialwire.app"),
                lambda x: x["read_targets"]["gateway"].update(service_id="source-service"),
                lambda x: x["runner"]["adapters"]["probe"].update(sha256="f" * 64)]
            for mutate in mutations:
                invalid = copy.deepcopy(c); mutate(invalid)
                with self.assertRaises(m.Error): m.validate_inputs(invalid, trace, env)
            Path(c["runner"]["token_file"]).chmod(0o644)
            with self.assertRaises(m.Error): m.validate_inputs(c, trace, env)

    def test_incomplete_or_flat_workload_rejected_even_with_matching_hash(self):
        with tempfile.TemporaryDirectory() as raw:
            c, trace, env = self.fixture(Path(raw)); data = json.loads(trace.read_text())
            data["requests"].pop(); trace.write_text(json.dumps(data)); c["workload_sha256"] = m.digest(trace)
            with self.assertRaises(m.Error): m.validate_inputs(c, trace, env)
            c, trace, env = self.fixture(Path(raw)); data = json.loads(trace.read_text())
            data["rates"]["burst"] = 1; trace.write_text(json.dumps(data)); c["workload_sha256"] = m.digest(trace)
            with self.assertRaises(m.Error): m.validate_inputs(c, trace, env)

    def sidebar(self):
        return {"viewerDid": "did:plc:test", "refreshedAt": "2026-09-12T00:00:00Z",
                **{key: [] for key in ("folders", "publicationPrefs", "allPublicationRows", "myPublications",
                                       "subscribedUnfoldered", "followingTabPublications", "enrollAuthorDids")}}

    def entry(self):
        return {"entryId": "entry-one", "title": "A story", "publishedAt": "2026-09-12T00:00:00Z", "isRead": False}

    def wire(self):
        return {"generationId": "generation-one", "generatedAt": "2026-09-12T00:00:00Z", "language": "en",
                "source": "ranked", "degraded": False, "items": [{"itemId": "item-one", "canonicalUrl": "https://example.com/story",
                "title": "A story", "source": {"name": "Example", "domain": "example.com"}, "reasons": [], "provenance": []}]}

    def bootstrap(self):
        return [{"kind": "sidebarPriority", "sidebarPriority": self.sidebar()},
                {"kind": "selectedPublication", "selectedPublication": {"publicationId": "pub-one"}},
                {"kind": "entriesPage", "entriesPage": {"publicationId": "pub-one", "entries": [self.entry()], "source": "live_projection"}},
                {"kind": "done", "done": {"refreshedAt": "2026-09-12T00:00:00Z", "source": "live_projection"}}]

    def test_allowlist_matches_current_gateway_routes_and_category(self):
        for route, (contract, categories) in m.READ_ROUTES.items():
            with self.subTest(route=route):
                self.assertEqual(m.read_contract({"path": route + "?cursor=opaque%2Bcursor", "category": sorted(categories)[0]}), contract)
        for path in ("/v1/publications/refresh", "/xrpc/app.thesocialwire.appview.putReadMark", "/xrpc/test",
                     "//evil.test/xrpc/test", "https://evil.test/v1/appview/entry", "/v1/appview/entry/",
                     "/v1/appview/%65ntry", "/v1/appview/entry#fragment", "/v1/appview/entry\n"):
            with self.subTest(path=path), self.assertRaises(m.Error):
                m.read_contract({"path": path, "category": "detail"})
        with self.assertRaises(m.Error): m.read_contract({"path": "/v1/appview/entry", "category": "bootstrap"})
        with self.assertRaises(m.Error): m.read_contract({"path": "/v1/appview/entry", "category": "detail", "method": "POST"})

    def test_real_json_contracts_and_aliases_accept_complete_payloads(self):
        for route, (contract, categories) in m.READ_ROUTES.items():
            if contract == "bootstrap": continue
            value = {"sidebar": self.sidebar(), "detail": self.entry(), "entries": {"entries": [self.entry()], "cursor": "next"}, "wire": self.wire()}[contract]
            m.validate_response({"path": route, "category": sorted(categories)[0]}, json.dumps(value).encode(), "application/json; charset=utf-8")
        # Empty AppView pages are legitimate; this is contract validation, not a representativeness claim.
        m.validate_response({"path": "/v1/appview/feed", "category": "pagination"}, b'{"entries":[]}', "application/json")

    def test_http_200_error_malformed_and_wrong_payloads_do_not_pass(self):
        item = {"path": "/v1/appview/entries", "category": "pagination"}
        for raw in (b'{"error":"private server detail"}', b'{"errors":[]}', b'{}', b'[]', b'{"entries":',
                    b'{"entries":{},"cursor":123}', b'{"entries":[{}]}', b'{"entries":[],"entries":[]}', b'{"entries":[],"x":NaN}'):
            with self.subTest(raw=raw), self.assertRaises(m.Error) as error:
                m.validate_response(item, raw, "application/json")
            self.assertNotIn("private server detail", str(error.exception))
        with self.assertRaises(m.Error): m.validate_response(item, b'{"entries":[]}', "text/html")
        with self.assertRaises(m.Error):
            m.validate_response({"path": "/v1/appview/entry?entryId=wrong", "category": "detail"}, json.dumps(self.entry()).encode(), "application/json")

    def test_ranked_feed_requires_nonempty_matching_language_and_complete_items(self):
        item = {"path": "/xrpc/app.thesocialwire.discovery.getWire?lang=en", "category": "language_feed"}
        mutations = [lambda x: x.update(items=[]), lambda x: x.update(degraded=True), lambda x: x.update(source="stale_generation"),
                     lambda x: x.update(language="fr"), lambda x: x.pop("generationId"), lambda x: x.update(items=[{}]),
                     lambda x: x.update(generatedAt="not-a-date")]
        for mutate in mutations:
            value = self.wire(); mutate(value)
            with self.assertRaises(m.Error): m.validate_response(item, json.dumps(value).encode(), "application/json")

    def test_degraded_baseline_requires_explicit_pinned_expectations_and_exact_match(self):
        item = {"path": "/xrpc/app.thesocialwire.discovery.getWire?lang=en", "category": "language_feed",
                "expected_degraded": True, "expected_source": "ranked", "baseline_evidence": "reviewed-baseline-reference"}
        value = self.wire(); value["degraded"] = True
        m.validate_response(item, json.dumps(value).encode(), "application/json")
        for key in ("baseline_evidence", "expected_degraded", "expected_source"):
            invalid = dict(item); invalid.pop(key)
            with self.assertRaises(m.Error): m.read_contract(invalid)
        with self.assertRaises(m.Error): m.validate_response(item, json.dumps(self.wire()).encode(), "application/json")
        value["source"] = "simplified_fallback"
        with self.assertRaises(m.Error): m.validate_response(item, json.dumps(value).encode(), "application/json")
        invalid = dict(item); invalid["expected_degraded"] = "true"
        with self.assertRaises(m.Error): m.read_contract(invalid)

    def test_bootstrap_requires_complete_done_and_available_selected_entries(self):
        item = {"path": "/v1/appview/bootstrap-stream", "category": "bootstrap"}
        encode = lambda events: b"\n".join(json.dumps(event).encode() for event in events)
        m.validate_response(item, encode(self.bootstrap()), "application/x-ndjson")
        # A viewer with no selection may validly complete without an entries page.
        m.validate_response(item, encode([self.bootstrap()[0], self.bootstrap()[-1]]), "application/x-ndjson")
        variants = [self.bootstrap()[:-1], self.bootstrap()[1:], self.bootstrap() + [self.bootstrap()[-1]],
                    [self.bootstrap()[0], self.bootstrap()[1], self.bootstrap()[-1]],
                    self.bootstrap() + [{"kind": "warning", "warning": {"message": "private detail"}}]]
        unavailable = self.bootstrap(); unavailable[2]["entriesPage"]["source"] = "unavailable"; variants.append(unavailable)
        error = self.bootstrap(); error.insert(1, {"kind": "error", "error": {"message": "private detail"}}); variants.append(error)
        for events in variants:
            with self.assertRaises(m.Error): m.validate_response(item, encode(events), "application/x-ndjson")
        with self.assertRaises(m.Error): m.validate_response(item, encode(self.bootstrap()) + b'\n{"kind":', "application/x-ndjson")

    def test_request_checks_chunked_response_completeness_before_counting_success(self):
        item = {"path": "/v1/appview/entry?entryId=entry-one", "category": "detail", "id": "detail", "target": "gateway"}
        class Response:
            status = 200
            def __init__(self, raw, length=None):
                self.chunks = [raw[:7], raw[7:], b""]
                self.headers = {"Content-Type": "application/json"}
                if length is not None: self.headers["Content-Length"] = length
            def __enter__(self): return self
            def __exit__(self, *_): pass
            def read1(self, _): return self.chunks.pop(0)
        with tempfile.TemporaryDirectory() as raw:
            config, _, _ = self.fixture(Path(raw))
            from unittest.mock import Mock
            for body, length, passes in ((json.dumps(self.entry()).encode(), None, True),
                                         (b'{"error":"private detail"}', None, False),
                                         (json.dumps(self.entry()).encode(), "9999", False)):
                opener = Mock(); opener.open.return_value = Response(body, length)
                with patch.object(m, "invoke", return_value={"Authorization": "DPoP test", "DPoP": "test-proof"}), \
                     patch.object(m.urllib.request, "build_opener", return_value=opener):
                    if passes: self.assertEqual(m.request(item, config, m.Children(), {})["category"], "detail")
                    else:
                        with self.assertRaises(m.Error): m.request(item, config, m.Children(), {})

    def test_nonce_retry_validates_final_body_and_never_counts_an_oversized_response(self):
        from unittest.mock import Mock
        from urllib.error import HTTPError
        item = {"path": "/v1/appview/entries", "category": "pagination", "id": "page", "target": "gateway"}
        class Response:
            status = 200
            headers = {"Content-Type": "application/json"}
            def __init__(self, size=0): self.size = size; self.finished = False
            def __enter__(self): return self
            def __exit__(self, *_): pass
            def read1(self, maximum):
                if self.size:
                    count = min(maximum, self.size); self.size -= count
                    return b" " * count
                if self.finished: return b""
                self.finished = True
                return b'{"entries":[]}'
        with tempfile.TemporaryDirectory() as raw:
            config, _, _ = self.fixture(Path(raw))
            opener = Mock()
            opener.open.side_effect = [HTTPError("http://isolated", 401, "nonce", {"DPoP-Nonce": "test-nonce"}, None), Response()]
            with patch.object(m, "invoke", return_value={"Authorization": "DPoP test", "DPoP": "test-proof"}) as signer, \
                 patch.object(m.urllib.request, "build_opener", return_value=opener):
                self.assertEqual(m.request(item, config, m.Children(), {})["category"], "pagination")
                self.assertEqual(signer.call_args_list[1].args[3]["nonce"], "test-nonce")
                self.assertEqual(opener.open.call_count, 2)
            opener.open.side_effect = None; opener.open.return_value = Response(size=8 * 1024 * 1024 + 1)
            with patch.object(m, "invoke", return_value={"Authorization": "DPoP test", "DPoP": "test-proof"}), \
                 patch.object(m.urllib.request, "build_opener", return_value=opener):
                with self.assertRaises(m.Error): m.request(item, config, m.Children(), {})

    def test_preflight_requires_exact_railway_decimal_byte_cap(self):
        for cap in (16_000_000_000, 12_000_000_000, 8_000_000_000):
            config = configuration(cap)
            with self.subTest(cap=cap):
                m.initial_probe(probe(memory_limit_bytes=cap), config)
                for wrong in (cap + 1, cap - 1, (cap // 1_000_000_000) * 1024 ** 3, float(cap)):
                    with self.subTest(wrong=wrong), self.assertRaises(m.Error):
                        m.initial_probe(probe(memory_limit_bytes=wrong), config)

    def test_preflight_rejects_oom_wrong_snapshot_and_disk_before_work(self):
        c = configuration(); m.initial_probe(probe(), c)
        for mutate in (lambda p: p["memory_events"].update(oom_kill=1), lambda p: p.update(volume_free_bytes=1),
                       lambda p: p["restore"].update(snapshot_sha256="f" * 64)):
            sample = probe(); mutate(sample)
            with self.assertRaises(m.Error): m.initial_probe(sample, c)

    def test_throughput_is_a_delta_and_cannot_pass_on_an_old_burst(self):
        c = {"runner": {"minimum_replay_per_minute": 10, "minimum_rankings_per_minute": 1}}
        m.check_progress({"replay": 110, "ranking": 2}, {"replay": 100, "ranking": 1}, c)
        with self.assertRaises(m.Error): m.check_progress({"replay": 110, "ranking": 2}, {"replay": 110, "ranking": 2}, c)

    def test_cleanup_stops_only_owned_children_on_failure(self):
        children = m.Children()
        unrelated = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(30)"])
        owned = children.start([sys.executable, "-c", "import time; time.sleep(30)"])
        try:
            children.stop()
            self.assertIsNotNone(owned.poll())
            self.assertIsNone(unrelated.poll())
            with self.assertRaises(m.Error): children.start([sys.executable, "-c", "pass"])
        finally:
            unrelated.terminate(); unrelated.wait()

    def test_adapter_timeout_remains_owned_until_cleanup(self):
        with tempfile.TemporaryDirectory() as raw:
            path = Path(raw) / "slow"; path.write_text("#!/bin/sh\nsleep 30\n"); path.chmod(0o700)
            children = m.Children()
            try:
                with self.assertRaises(m.Error): m.invoke(children, {"path": str(path), "sha256": m.digest(path)}, {}, {}, .05)
                self.assertEqual(len(children.processes), 1)
            finally:
                children.stop()
            self.assertIsNotNone(children.processes[0].poll())

    def test_supervisor_failure_stops_started_workers_and_retains_failure(self):
        with tempfile.TemporaryDirectory() as raw:
            directory = Path(raw); c, trace, _ = self.fixture(directory)
            adapter = directory / "adapter"
            adapter.write_text("#!/bin/sh\nsleep 30\n")
            for value in c["runner"]["adapters"].values(): value["sha256"] = m.digest(adapter)
            config_path = directory / "config.json"; config_path.write_text(json.dumps(c))
            identity = {"target": c["target"], "runner": {key: c["runner"][key] for key in ("project_id", "environment_id", "service_id")},
                "read_targets": c["read_targets"], "snapshot_sha256": c["snapshot_sha256"]}
            children = m.Children()
            with patch.object(m, "validate_inputs", return_value=json.loads(trace.read_text())), \
                 patch.object(m, "invoke", side_effect=[identity, probe()]), \
                 patch.object(m, "Children", return_value=children), \
                 patch.object(m, "load_interval", side_effect=m.Error("simulated latency stop")):
                with self.assertRaises(m.Error): m.run(config_path, trace, directory / "evidence")
            self.assertEqual(len(children.processes), 2)
            self.assertTrue(all(process.poll() is not None for process in children.processes))
            self.assertEqual(json.loads((directory / "evidence/failure.json").read_text())["status"], "stopped")

    def test_redirect_never_forwards_authentication(self):
        with self.assertRaises(m.Error):
            m.NoRedirect().redirect_request(None, None, 302, "", {}, "https://api.thesocialwire.app")

    def test_private_evidence_refuses_overwrite(self):
        with tempfile.TemporaryDirectory() as raw:
            path = Path(raw) / "evidence"
            with m.private_file(path) as handle: handle.write("test")
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            with self.assertRaises(FileExistsError): m.private_file(path)


if __name__ == "__main__": unittest.main()
