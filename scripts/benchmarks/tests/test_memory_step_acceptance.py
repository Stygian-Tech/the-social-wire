"""Synthetic unit fixtures only: these are not observations or memory-capacity evidence."""
import copy
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location("memory_step", Path(__file__).resolve().parents[1] / "memory_step_acceptance.py")
m = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(m)


def fixture(stage="development", cap=13_000_000_000):
    start = 10_000 if stage == "development" else 20_000
    config = {"stage": stage, "memory_limit_bytes": cap, "supported_languages": ["en", "es"],
              "queue_names": ["wire", "appview"], "latency_groups": ["wire", "edition", "bootstrap"],
              "maximum_baseline_age_seconds": 7 * 86400,
              "comparison": {key: character * 64 for key, character in zip(m.COMPARISON_KEYS, "abc")}}
    seconds = 3600 if stage == "development" else 86400
    restart = None
    if stage == "development":
        restart = {"available": True, "evidence_ref": "synthetic/provider-receipt",
                   "requested_at": start + 1800, "database_ready_at": start + 1860,
                   "observation_paused_at": start + 1800, "observation_resumed_at": start + 1920,
                   "termination_reason": "operator_restart", "oom_killed": False}
    end = start + seconds + (120 if restart else 0)
    def latency(begin, finish):
        return {"available": True, "evidence_ref": "synthetic/request-log",
                "comparison": dict(config["comparison"]), "method": "raw_request_percentile",
                "started_at": begin, "ended_at": finish,
                "p95_ms": dict.fromkeys(config["latency_groups"], 100),
                "request_counts": dict.fromkeys(config["latency_groups"], 1000)}
    baseline = latency(start - 4000, start - 400)
    baseline["memory_limit_bytes"] = 16_000_000_000
    samples = []
    cursor = start
    while cursor < end:
        if restart and cursor == restart["observation_paused_at"]:
            cursor = restart["observation_resumed_at"]
        samples.append({"available": True, "evidence_ref": f"synthetic/minute/{len(samples)}",
                        "started_at": cursor, "ended_at": cursor + 60,
                        "observed_at": cursor + 60, "collected_at": cursor + 60,
                        "memory_limit_bytes": cap, "oom_events": 0, "oom_kills": 0,
                        "avoidable_coordinator_restarts": 0, "lease_loss_events": 0,
                        "generations": dict.fromkeys(config["supported_languages"], cursor + 60 - 300),
                        "actionable_queue_age_seconds": dict.fromkeys(config["queue_names"], 0)})
        cursor += 60
    value = {"schema_version": 1, "config": config, "assessed_at": end,
             "started_at": start, "ended_at": end, "baseline": baseline, "latency": latency(start, end),
             "samples": samples, "restart": restart, "bursts": []}
    if restart:
        value["bursts"] = [{"available": True, "evidence_ref": "synthetic/burst-log",
                            "started_at": start + 300, "ended_at": start + 600,
                            "drained_at": start + 900, "remaining_actionable_rows": 0}]
        value["discovery_rebuild"] = {"available": True, "evidence_ref": "synthetic/recovery-report",
                                      "started_at": start + 1800, "ended_at": start + 2400,
                                      "durable_state_verified": True, "complete": True}
    else:
        value["development_evidence"] = fixture(cap=cap)
    return value


class MemoryStepAcceptanceTests(unittest.TestCase):
    def blocked(self, evidence, reason):
        result = m.assess(evidence)
        self.assertEqual(result["gates_status"], "blocked", result)
        self.assertEqual(result["readiness"], "blocked")
        self.assertIn(reason, result["issues"][0])
        return result

    def test_passing_evidence_never_claims_overall_trial_or_hosted_proof(self):
        for stage, seconds in (("development", 3600), ("production", 86400)):
            result = m.assess(fixture(stage))
            self.assertEqual(result["gates_status"], "passed", result)
            self.assertEqual(result["observed_seconds"], seconds)
            self.assertEqual(result["readiness"], "ready_for_operator_review")
            self.assertEqual(result["overall_trial_status"], "not_proven_by_this_validator")
            self.assertIn("not_independently_verified", result["evidence_proof"])

    def test_exact_byte_caps_and_no_implicit_baseline_or_unit_conversion(self):
        for cap in m.CAPS:
            self.assertEqual(m.assess(fixture(cap=cap))["gates_status"], "passed")
        for cap in (13 * 1024**3, 13_000_000_001, 13_000_000_000.0, True, "13000000000", 16_000_000_000):
            item = fixture(); item["config"]["memory_limit_bytes"] = cap
            self.blocked(item, "memory_limit_bytes")
        item = fixture(); item["config"]["memory_gib"] = 13
        self.blocked(item, "memory_gib")
        for cap in (13_000_000_001, 13_000_000_000.0, None):
            item = fixture(); item["samples"][10]["memory_limit_bytes"] = cap
            self.blocked(item, "memory cap mismatch")

    def test_generation_freshness_boundary_and_explicit_supported_language_coverage(self):
        item = fixture(); sample = item["samples"][4]
        sample["generations"]["es"] = sample["ended_at"] - 720
        self.assertEqual(m.assess(item)["gates_status"], "passed")
        sample["generations"]["es"] -= 0.001
        self.blocked(item, "language es")
        for mutation in (lambda s: s["generations"].pop("es"),
                         lambda s: s["generations"].update(es=s["observed_at"] + 1),
                         lambda s: s["generations"].update(es=None)):
            item = fixture(); mutation(item["samples"][4]); self.blocked(item, "sample[4]")
        item = fixture(); item["config"]["supported_languages"] = []
        self.blocked(item, "supported_languages")

    def test_queue_threshold_requires_three_consecutive_minutes_per_queue(self):
        item = fixture()
        for sample in item["samples"][2:5]: sample["actionable_queue_age_seconds"]["wire"] = 60
        self.assertEqual(m.assess(item)["gates_status"], "passed")
        for sample in item["samples"][2:4]: sample["actionable_queue_age_seconds"]["wire"] = 60.001
        self.assertEqual(m.assess(item)["gates_status"], "passed")
        item["samples"][4]["actionable_queue_age_seconds"]["wire"] = 60.001
        self.blocked(item, "three consecutive minutes")
        item["samples"][3]["actionable_queue_age_seconds"]["wire"] = 60
        self.assertEqual(m.assess(item)["gates_status"], "passed")
        item["samples"][3]["actionable_queue_age_seconds"]["appview"] = 61
        self.assertEqual(m.assess(item)["gates_status"], "passed")

    def test_oom_avoidable_restarts_and_repeated_authority_loss(self):
        for key in ("oom_events", "oom_kills", "avoidable_coordinator_restarts"):
            item = fixture(); item["samples"][4][key] = 1
            self.blocked(item, key)
        item = fixture(); item["samples"][4]["lease_loss_events"] = 1
        self.assertEqual(m.assess(item)["gates_status"], "passed")
        item["samples"][9]["lease_loss_events"] = 1
        self.blocked(item, "repeated authority loss")
        item = fixture(); item["samples"][4]["lease_loss_events"] = 2
        self.blocked(item, "repeated authority loss")

    def test_missing_stale_unavailable_and_duplicate_minute_samples_fail_closed(self):
        for mutation in (lambda x: x["samples"].pop(10),
                         lambda x: x["samples"].insert(10, copy.deepcopy(x["samples"][10])),
                         lambda x: x["samples"][10].update(available=False),
                         lambda x: x["samples"][10].pop("oom_kills"),
                         lambda x: x["samples"][10].update(collected_at=x["samples"][10]["observed_at"] + 60.001),
                         lambda x: x["samples"][10].update(observed_at=x["samples"][10]["started_at"]),
                         lambda x: x["samples"][10]["actionable_queue_age_seconds"].pop("appview"),
                         lambda x: x["samples"][10].update(evidence_ref="")):
            item = fixture(); mutation(item); self.blocked(item, "sample[")
        item = fixture(); item["assessed_at"] += 60
        self.assertEqual(m.assess(item)["gates_status"], "passed")
        item["assessed_at"] += 0.001
        self.blocked(item, "assessment is stale")
        item = fixture()
        item["samples"][-1]["generations"]["en"] = item["ended_at"] - 720
        item["assessed_at"] += 1
        self.blocked(item, "stale at assessment time")

    def test_matching_raw_latency_at_ten_percent_boundary(self):
        item = fixture(); item["latency"]["p95_ms"]["bootstrap"] = 110
        self.assertEqual(m.assess(item)["gates_status"], "passed")
        item["latency"]["p95_ms"]["bootstrap"] = 110.000001
        self.blocked(item, "p95 regression")
        for target in ("baseline", "latency"):
            for mutation in (lambda x: x.update(available=False),
                             lambda x: x.update(method="mean_of_interval_p95"),
                             lambda x: x["p95_ms"].pop("wire"),
                             lambda x: x["request_counts"].update(wire=0),
                             lambda x: x["comparison"].update(workload_sha256="d" * 64)):
                item = fixture(); mutation(item[target]); self.blocked(item, target)
        item = fixture(); item["config"]["maximum_baseline_age_seconds"] = 399
        self.blocked(item, "stale comparison")

    def test_restart_pause_is_explicit_and_never_counts_toward_duration(self):
        item = fixture(); item["restart"] = None
        self.blocked(item, "restart receipt required")
        for mutation, reason in ((lambda r: r.update(available=False), "restart"),
                                 (lambda r: r.update(oom_killed=True), "restart"),
                                 (lambda r: r.update(termination_reason="oom"), "restart"),
                                 (lambda r: r.update(observation_resumed_at=r["observation_resumed_at"] - 1), "coverage")):
            item = fixture(); mutation(item["restart"]); self.blocked(item, reason)

    def test_burst_boundary_and_missing_or_partial_drainage(self):
        self.assertEqual(m.assess(fixture())["gates_status"], "passed")
        for mutation, reason in ((lambda x: x.update(drained_at=x["drained_at"] + 0.001), "300"),
                                 (lambda x: x.update(available=False), "unavailable"),
                                 (lambda x: x.update(remaining_actionable_rows=1), "backlog remains")):
            item = fixture(); mutation(item["bursts"][0]); self.blocked(item, reason)
        item = fixture(); item["bursts"] = []
        self.blocked(item, "burst evidence required")

    def test_recovery_boundary_and_durable_state_cannot_be_omitted(self):
        item = fixture()
        item["discovery_rebuild"].update(started_at=item["started_at"], ended_at=item["started_at"] + 3600)
        self.assertEqual(m.assess(item)["gates_status"], "passed")
        item["discovery_rebuild"]["ended_at"] += 0.001
        self.blocked(item, "3600")
        for key in ("complete", "durable_state_verified", "available"):
            item = fixture(); item["discovery_rebuild"][key] = False
            self.blocked(item, "discovery_rebuild")

    def test_short_hour_or_production_day_cannot_pass(self):
        for stage in ("development", "production"):
            item = fixture(stage); item["samples"].pop()
            item["ended_at"] -= 60; item["latency"]["ended_at"] -= 60; item["assessed_at"] -= 60
            self.blocked(item, "measured seconds required")

    def test_production_requires_same_cap_and_configuration_development_evidence(self):
        item = fixture("production"); item.pop("development_evidence")
        self.blocked(item, "development_evidence")
        item = fixture("production"); item["development_evidence"] = fixture(cap=12_000_000_000)
        self.blocked(item, "memory_limit_bytes differs")
        item = fixture("production"); item["development_evidence"]["samples"][0]["oom_events"] = 1
        self.blocked(item, "oom_events")

    def test_malformed_numeric_data_and_missing_document_are_blocked(self):
        for value in (None, True, [], {}, {"schema_version": True}):
            self.blocked(value, "document" if type(value) is not dict else "schema_version")
        for value in (float("nan"), float("inf"), -1, True, "60"):
            item = fixture(); item["samples"][3]["actionable_queue_age_seconds"]["wire"] = value
            self.blocked(item, "sample[3]")

    def test_cli_reads_only_local_json_and_returns_nonzero_for_invalid_json(self):
        from contextlib import redirect_stdout
        from io import StringIO
        with tempfile.TemporaryDirectory() as raw:
            path = Path(raw) / "evidence.json"
            for text, expected in ((json.dumps(fixture()), 0), ("{broken", 1), ('{"value":NaN}', 1), ('{"value":0,"value":1}', 1)):
                path.write_text(text); output = StringIO()
                with redirect_stdout(output): self.assertEqual(m.main([str(path)]), expected)
                result = json.loads(output.getvalue())
                self.assertIn("overall_trial_status", result)


if __name__ == "__main__":
    unittest.main()
