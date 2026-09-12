"""Bounded observations of the real Coordinator's atomic Wire publication records."""
from decimal import Decimal, InvalidOperation
import math


class RankingError(RuntimeError):
    pass


ROLES = ("indexing.appview-coordinator", "indexing.wire-materializer")
MAX_GENERATIONS = 2048


def timestamp(value):
    try:
        result = Decimal(str(value))
    except (InvalidOperation, ValueError):
        raise RankingError("Invalid database observation timestamp") from None
    if not result.is_finite() or result < 0:
        raise RankingError("Invalid database observation timestamp")
    return result


def observation_sql(after):
    # The sole interpolated value is a finite decimal timestamp, never SQL from config.
    after = timestamp(after)
    return f"""WITH instant AS MATERIALIZED (SELECT clock_timestamp() AS observed_at),
      generations AS MATERIALIZED (
        SELECT g.generation_id::text, left(g.language_bucket, 32) AS language_bucket,
          left(g.config_version, 128) AS config_version, g.status,
          extract(epoch FROM g.generated_at)::text AS generated_at,
          extract(epoch FROM g.expires_at)::text AS expires_at, g.ranked_count,
          g.committed_at IS NOT NULL AS has_commit,
          (g.status = 'superseded' OR EXISTS (SELECT 1 FROM wire_feed_state s
            WHERE s.feed_key = 'wire' AND s.language_bucket = g.language_bucket
              AND s.active_generation_id = g.generation_id)) AS published,
          EXISTS (SELECT 1 FROM wire_ranked_items i WHERE i.generation_id = g.generation_id LIMIT 1) AS has_items
        FROM wire_rank_generations g
        WHERE g.feed_key = 'wire' AND g.generated_at >= to_timestamp({after})
        ORDER BY g.generated_at, g.language_bucket, g.generation_id LIMIT {MAX_GENERATIONS + 1}
      )
      SELECT json_build_object(
        'observed_at', extract(epoch FROM instant.observed_at)::text,
        'database', current_database(),
        'system_identifier', (SELECT system_identifier::text FROM pg_control_system()),
        'postmaster_started', pg_postmaster_start_time(),
        'leases', (SELECT coalesce(json_agg(row_to_json(l)), '[]'::json) FROM (
          SELECT role, owner_id, fencing_token, extract(epoch FROM acquired_at)::text AS acquired_at,
            extract(epoch FROM lease_expires_at)::text AS expires_at, released_at IS NOT NULL AS released
          FROM operations_role_leases WHERE environment = 'dev'
            AND role IN ('indexing.appview-coordinator', 'indexing.wire-materializer') LIMIT 3) l),
        'generations', (SELECT coalesce(json_agg(row_to_json(g)), '[]'::json) FROM generations g)) FROM instant"""


class RankingEvidence:
    """Counts observations, never predicted completions or pre-trial generations."""
    def __init__(self, config, owner, baseline, monotonic):
        self.languages = set(config["ranking"]["supported_languages"])
        self.version = config["ranking"]["config_version"]
        self.database = config["target"]["database"]
        self.maximum_stale = config["ranking"]["maximum_stale_seconds"]
        self.owner, self.started, self.last_complete = owner, monotonic, monotonic
        self.after = timestamp(baseline["observed_at"])
        self.last_observed = self.after
        self.system = baseline["system_identifier"]
        self.fences = None
        self.completed = 0
        self.counted = set()
        self.validate_snapshot(baseline)
        if any(not row["released"] and timestamp(row["expires_at"]) > self.after for row in baseline["leases"]):
            raise RankingError("Another Coordinator owns the isolated database")

    def validate_snapshot(self, sample):
        if (sample["database"] != self.database or sample["system_identifier"] != self.system
                or not isinstance(sample["generations"], list) or len(sample["generations"]) > MAX_GENERATIONS
                or not isinstance(sample["leases"], list) or len(sample["leases"]) > len(ROLES)):
            raise RankingError("Ranking database identity or bounded observation changed")
        observed = timestamp(sample["observed_at"])
        if observed < self.last_observed:
            raise RankingError("Database observation clock regressed")
        return observed

    def check_stale(self, monotonic):
        if not math.isfinite(monotonic) or monotonic - self.last_complete > self.maximum_stale:
            raise RankingError("No fresh complete all-language ranking cycle within its deadline")

    def accept(self, sample, monotonic):
        self.check_stale(monotonic)
        observed = self.validate_snapshot(sample)
        self.last_observed = observed
        leases = {}
        for row in sample["leases"]:
            role = row["role"]
            if role not in ROLES or role in leases or type(row["fencing_token"]) is not int or row["fencing_token"] < 1:
                raise RankingError("Invalid Coordinator lease observation")
            if not row["released"] and timestamp(row["expires_at"]) > observed:
                if row["owner_id"] != self.owner:
                    raise RankingError("Another Coordinator took ownership during the trial")
                leases[role] = row
        if set(leases) != set(ROLES):
            # No authority means no count. The real supervisor may reacquire after DB restart.
            return self.event("awaiting_authority", observed)
        fences = tuple(leases[role]["fencing_token"] for role in ROLES)
        if self.fences is not None and any(new < old for new, old in zip(fences, self.fences)):
            raise RankingError("Coordinator fence regressed")
        self.fences = fences
        acquired = max(self.after, timestamp(leases[ROLES[1]]["acquired_at"]))
        groups = {}
        for row in sample["generations"]:
            generated = timestamp(row["generated_at"])
            if generated < acquired:
                continue
            if generated > observed + 5:
                raise RankingError("Generation clock is ahead of the database observation")
            if row["language_bucket"] not in self.languages or row["config_version"] != self.version:
                raise RankingError("Coordinator language or algorithm differs from reviewed workload")
            group = groups.setdefault(generated, {})
            if row["language_bucket"] in group:
                raise RankingError("Ambiguous language publication in one cycle")
            group[row["language_bucket"]] = row
        receipts = []
        for generated, rows in sorted(groups.items()):
            if generated in self.counted or set(rows) != self.languages:
                continue
            if any(row["status"] not in {"committed", "superseded"} or not row["has_commit"]
                   or not row["published"] or not row["has_items"] or type(row["ranked_count"]) is not int
                   or row["ranked_count"] <= 0 or timestamp(row["expires_at"]) <= observed for row in rows.values()):
                continue
            if observed - generated > self.maximum_stale:
                continue
            self.counted.add(generated)
            self.completed += 1
            self.last_complete = monotonic
            receipts.append({"generated_at": str(generated), "first_observed_complete_at": str(observed),
                "wire_fencing_token": fences[1],
                "generation_ids": {language: rows[language]["generation_id"] for language in sorted(rows)}})
        return self.event("observed", observed) | {"new_cycles": receipts}

    def event(self, status, observed=None):
        return {"completed": self.completed, "status": status,
            "observed_at": None if observed is None else str(observed),
            "supported_languages": sorted(self.languages)}
