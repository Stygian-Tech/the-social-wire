#!/usr/bin/env python3
"""Offline, complementary memory-step gates; submitted evidence is not capacity proof."""
import argparse
from decimal import Decimal
import json
import importlib.util
import math
from pathlib import Path
import re
import sys

SPEC = importlib.util.spec_from_file_location("memory_trial", Path(__file__).with_name("postgres_memory_trial.py"))
trial = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(trial)

CAPS = {13_000_000_000, 12_000_000_000, 11_000_000_000, 10_000_000_000}
COMPARISON_KEYS = ("workload_sha256", "non_memory_settings_sha256", "binary_manifest_sha256")


class EvidenceError(ValueError):
    pass


def require(condition, message):
    if not condition:
        raise EvidenceError(message)


def number(value, label, minimum=0):
    require(type(value) in (int, float) and math.isfinite(value) and value >= minimum,
            f"{label}: finite number >= {minimum} required")
    return value


def integer(value, label, minimum=0):
    require(type(value) is int and value >= minimum, f"{label}: integer >= {minimum} required")
    return value


def object_value(value, label):
    require(type(value) is dict, f"{label}: object required")
    return value


def names(value, label):
    require(type(value) is list and value and all(type(x) is str and x.strip() for x in value)
            and len(set(value)) == len(value), f"{label}: unique nonempty names required")
    return value


def available(value, label):
    value = object_value(value, label)
    require(value.get("available") is True, f"{label}: evidence unavailable")
    require(type(value.get("evidence_ref")) is str and value["evidence_ref"].strip(),
            f"{label}: evidence reference required")
    return value


def period(value, label):
    start = number(value.get("started_at"), f"{label}.started_at")
    end = number(value.get("ended_at"), f"{label}.ended_at")
    require(end > start, f"{label}: positive observation interval required")
    return start, end


def matching(value, config, label):
    require(value.get("comparison") == config["comparison"],
            f"{label}: workload, binaries and non-memory settings must match")


def validate_latency(value, config, label):
    value = available(value, label)
    matching(value, config, label)
    require(value.get("method") == "raw_request_percentile", f"{label}: raw-request percentile required")
    p95 = object_value(value.get("p95_ms"), f"{label}.p95_ms")
    counts = object_value(value.get("request_counts"), f"{label}.request_counts")
    require(set(p95) == set(config["latency_groups"]) == set(counts),
            f"{label}: every configured latency group required")
    for key in config["latency_groups"]:
        number(p95[key], f"{label}.{key}.p95_ms", minimum=0.000001)
        integer(counts[key], f"{label}.{key}.request_count", minimum=1)
    return period(value, label)


def validate(document, *, allow_production=True):
    """Return measured summary or fail closed. Does not inspect referenced artifacts."""
    document = object_value(document, "document")
    require(document.get("schema_version") == 1 and type(document.get("schema_version")) is int,
            "schema_version: expected integer 1")
    config = object_value(document.get("config"), "config")
    stage = config.get("stage")
    require(stage in ("development", "production") and (allow_production or stage == "development"),
            "stage: expected development or production; prerequisites must be development")
    cap = integer(config.get("memory_limit_bytes"), "memory_limit_bytes")
    require(cap in CAPS, "memory_limit_bytes: exact decimal 13, 12, 11 or 10 GB step required")
    require("memory_gib" not in config, "memory_gib: legacy binary-unit configuration rejected")
    for key in ("supported_languages", "queue_names", "latency_groups"):
        names(config.get(key), key)
    comparison = object_value(config.get("comparison"), "comparison")
    require(set(comparison) == set(COMPARISON_KEYS), "comparison: all three fingerprints required")
    for key, value in comparison.items():
        require(type(value) is str and re.fullmatch(r"[0-9a-f]{64}", value), f"comparison.{key}: SHA-256 required")
    assessed_at = number(document.get("assessed_at"), "assessed_at")
    start, end = period(document, "trial")
    require(end <= assessed_at <= end + 60, "trial: assessment is stale or precedes completion")

    baseline = object_value(document.get("baseline"), "baseline")
    baseline_start, baseline_end = validate_latency(baseline, config, "baseline")
    require(type(baseline.get("memory_limit_bytes")) is int and baseline["memory_limit_bytes"] == 16_000_000_000,
            "baseline: exact 16 GB comparison cap required")
    require(trial.memory_limit_matches(baseline["memory_limit_bytes"], baseline.get("memory_max", baseline["memory_limit_bytes"]), baseline.get("page_size_bytes")),
            "baseline: observed memory cap mismatch")
    require(baseline_end <= start and baseline_end - baseline_start >= 3600,
            "baseline: at least one prior measured hour required")
    max_baseline_age = number(config.get("maximum_baseline_age_seconds"), "maximum_baseline_age_seconds", 1)
    require(max_baseline_age <= 7 * 86400 and start - baseline_end <= max_baseline_age,
            "baseline: stale comparison evidence")
    latency = object_value(document.get("latency"), "latency")
    require(validate_latency(latency, config, "latency") == (start, end),
            "latency: request evidence must cover the assessed window")
    for key in config["latency_groups"]:
        require(Decimal(str(latency["p95_ms"][key])) <= Decimal(str(baseline["p95_ms"][key])) * Decimal("1.10"),
                f"latency.{key}: p95 regression exceeds 10 percent")

    restart = document.get("restart")
    pause = None
    if restart is not None:
        restart = available(restart, "restart")
        requested = number(restart.get("requested_at"), "restart.requested_at")
        ready = number(restart.get("database_ready_at"), "restart.database_ready_at")
        paused = number(restart.get("observation_paused_at"), "restart.observation_paused_at")
        resumed = number(restart.get("observation_resumed_at"), "restart.observation_resumed_at")
        require(start <= paused <= requested < ready <= resumed <= end and resumed - paused <= 3600,
                "restart: ordered, bounded, in-window receipt required")
        require(restart.get("termination_reason") == "operator_restart" and restart.get("oom_killed") is False,
                "restart: independently sourced operator restart and no OOM required")
        pause = (paused, resumed)
    require(stage != "development" or pause is not None, "development: controlled restart receipt required")

    samples = document.get("samples")
    require(type(samples) is list and samples, "samples: nonempty minute evidence required")
    cursor = start
    observed_seconds = 0
    pause_consumed = False
    streaks = dict.fromkeys(config["queue_names"], 0)
    lease_losses = 0
    memory_observation = None
    for index, sample in enumerate(samples):
        label = f"sample[{index}]"
        sample = available(sample, label)
        sample_start, sample_end = period(sample, label)
        if pause and cursor == pause[0]:
            cursor = pause[1]
            pause_consumed = True
            streaks = dict.fromkeys(streaks, 0)
        require(sample_start == cursor and sample_end - sample_start == 60 and sample_end <= end,
                f"{label}: missing, overlapping or non-minute coverage")
        require(not pause or sample_end <= pause[0] or sample_start >= pause[1],
                f"{label}: restart blackout cannot count as measured workload")
        observed_at = number(sample.get("observed_at"), f"{label}.observed_at")
        collected_at = number(sample.get("collected_at"), f"{label}.collected_at")
        require(sample_start < observed_at <= sample_end and observed_at <= collected_at <= assessed_at
                and collected_at - observed_at <= 60 and sample_end - observed_at < 60,
                f"{label}: stale or invalid observation timestamps")
        require(type(sample.get("memory_limit_bytes")) is int and sample["memory_limit_bytes"] == cap,
                f"{label}: requested memory cap mismatch")
        observed_memory = (sample.get("memory_max", sample["memory_limit_bytes"]), sample.get("page_size_bytes"))
        require(trial.memory_limit_matches(cap, *observed_memory), f"{label}: observed memory cap mismatch")
        require(memory_observation is None or memory_observation == observed_memory,
                f"{label}: memory cap or page-size evidence changed within the step")
        memory_observation = observed_memory
        for counter in ("oom_events", "oom_kills", "avoidable_coordinator_restarts"):
            require(integer(sample.get(counter), f"{label}.{counter}") == 0, f"{label}: {counter} observed")
        lease_losses += integer(sample.get("lease_loss_events"), f"{label}.lease_loss_events")
        require(lease_losses < 2, "lease_loss_events: repeated authority loss during step")
        generations = object_value(sample.get("generations"), f"{label}.generations")
        require(set(generations) == set(config["supported_languages"]), f"{label}: supported language coverage missing")
        for language, publication in generations.items():
            publication = number(publication, f"{label}.generations.{language}")
            require(publication <= observed_at and sample_end - publication <= 720,
                    f"{label}: language {language} generation exceeds 720 seconds or is future-dated")
        queues = object_value(sample.get("actionable_queue_age_seconds"), f"{label}.queues")
        require(set(queues) == set(streaks), f"{label}: actionable queue coverage missing")
        for queue, age in queues.items():
            streaks[queue] = streaks[queue] + 1 if number(age, f"{label}.queues.{queue}") > 60 else 0
            require(streaks[queue] < 3, f"{label}: {queue} actionable age above 60 seconds for three consecutive minutes")
        cursor = sample_end
        observed_seconds += 60
    require(cursor == end and (not pause or pause_consumed), "samples: incomplete window or restart evidence")
    for language, publication in samples[-1]["generations"].items():
        require(assessed_at - publication <= 720,
                f"latest language {language} generation is stale at assessment time")
    minimum = 3600 if stage == "development" else 86400
    require(observed_seconds >= minimum, f"{stage}: at least {minimum} measured seconds required, excluding restart")

    bursts = document.get("bursts")
    require(type(bursts) is list, "bursts: explicit list required")
    require(stage != "development" or bursts, "development: representative burst evidence required")
    for index, burst in enumerate(bursts):
        burst = available(burst, f"burst[{index}]")
        burst_start, burst_end = period(burst, f"burst[{index}]")
        drained = number(burst.get("drained_at"), f"burst[{index}].drained_at")
        require(start <= burst_start < burst_end <= drained <= end and drained - burst_end <= 300,
                f"burst[{index}]: complete drainage within 300 seconds required")
        require(not pause or drained <= pause[0] or burst_start >= pause[1],
                f"burst[{index}]: restart cannot hide drainage time")
        require(integer(burst.get("remaining_actionable_rows"), "burst.remaining_actionable_rows") == 0,
                f"burst[{index}]: actionable backlog remains")

    if stage == "development" or restart:
        discovery = available(document.get("discovery_rebuild"), "discovery_rebuild")
        discovery_start, discovery_end = period(discovery, "discovery_rebuild")
        require(start <= discovery_start <= restart["requested_at"] < discovery_end <= end
                and discovery_end - discovery_start <= 3600,
                "discovery_rebuild: restart recovery within 3600 seconds required")
        require(discovery.get("durable_state_verified") is True and discovery.get("complete") is True,
                "discovery_rebuild: complete discovery and durable-state evidence required")
    if stage == "production":
        development = object_value(document.get("development_evidence"), "development_evidence")
        development_result = validate(development, allow_production=False)
        development_config = development["config"]
        for key in ("memory_limit_bytes", "supported_languages", "queue_names", "latency_groups", "comparison"):
            require(development_config[key] == config[key], f"development_evidence: {key} differs from Production step")
        require(development["ended_at"] <= start, "development_evidence: prerequisite must precede Production")
        require(start - development["ended_at"] <= max_baseline_age, "development_evidence: stale prerequisite")
        require(development_result["stage"] == "development", "development_evidence: invalid stage")
    return {"stage": stage, "memory_limit_bytes": cap, "memory_max": memory_observation[0],
            "page_size_bytes": memory_observation[1], "observed_seconds": observed_seconds,
            "window_started_at": start, "window_ended_at": end, "assessed_at": assessed_at,
            "lease_loss_events": lease_losses, "supported_languages": config["supported_languages"]}


def assess(document):
    result = {"overall_trial_status": "not_proven_by_this_validator",
              "evidence_proof": "submitted_values_only_references_not_independently_verified"}
    try:
        result.update(validate(document))
        result.update(gates_status="passed", readiness="ready_for_operator_review", issues=[])
    except EvidenceError as error:
        result.update(gates_status="blocked", readiness="blocked", issues=[str(error)])
    return result


def reject_nonfinite(value):
    raise ValueError(f"nonfinite JSON number: {value}")


def reject_duplicate_keys(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("evidence", type=Path, help="collected JSON evidence; no network or database calls")
    args = parser.parse_args(argv)
    try:
        with args.evidence.open("r", encoding="utf-8") as source:
            content = source.read(32 * 1024 * 1024 + 1)
        if len(content) > 32 * 1024 * 1024:
            raise ValueError("evidence document exceeds 32 MiB character limit")
        document = json.loads(content, parse_constant=reject_nonfinite, object_pairs_hook=reject_duplicate_keys)
        result = assess(document)
    except (OSError, ValueError) as error:
        result = assess(None)
        result["issues"] = [f"evidence file unavailable or invalid JSON: {type(error).__name__}"]
    print(json.dumps(result, sort_keys=True, allow_nan=False))
    return 0 if result["gates_status"] == "passed" else 1


if __name__ == "__main__":
    sys.exit(main())
