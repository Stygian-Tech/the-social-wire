"""Trial-only committed acknowledgement evidence. Never a Production migration.

This module installs instrumentation only after live provider/restore verification.
It does not launch or impersonate replay/drain workers.
"""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import sys
import urllib.parse

SPEC = importlib.util.spec_from_file_location("railway_receipt_provider", Path(__file__).with_name("railway_memory_adapters.py"))
provider = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(provider)
Error = provider.Error
SCHEMA = "tsw92_trial_receipts"
MAXIMUM_SEQUENCE_SPAN = 10_000_000


def literal(value):
    return "'" + str(value).replace("'", "''") + "'"


def scope(config):
    value = config["replay_receipts"]
    if value.get("module_sha256") != hashlib.sha256(Path(__file__).read_bytes()).hexdigest():
        raise Error("Receipt module differs from its reviewed hash")
    if (value.get("environment") != "dev"
            or not re.fullmatch(r"tsw92-replay-[a-f0-9]{12}", value.get("source_generation", ""))):
        raise Error("Receipt source must be a fresh isolated replay generation in dev")
    after, before = value.get("after_seq"), value.get("before_seq")
    maximum = value.get("maximum_receipts")
    if (type(after) is not int or type(before) is not int or type(maximum) is not int
            or not 0 <= after < before < 2**63 or not 1 <= maximum <= MAXIMUM_SEQUENCE_SPAN
            or before - after > maximum):
        raise Error("Bound sequence span and worst-case receipt rows explicitly (at most ten million)")
    byte_limit = value.get("maximum_receipt_bytes")
    if type(byte_limit) is not int or not 8192 <= byte_limit <= 2_000_000_000:
        raise Error("Bound measured receipt relation bytes explicitly (at most two GB)")
    if value.get("semantics") != "unique_committed_acknowledged_events":
        raise Error("Receipts prove acknowledgements, not changed content rows")
    if value.get("instrumentation_in_both_rounds") is not True:
        raise Error("Identical receipt instrumentation must be included in both measured rounds")
    return value


def installation_sql(config):
    value = scope(config)
    env, generation = literal(value["environment"]), literal(value["source_generation"])
    lower, upper = value["after_seq"], value["before_seq"]
    # Fresh namespace and source are required. No IF NOT EXISTS, reset, or backfill:
    # an already running/completed source cannot acquire fabricated historical receipts.
    return f"""BEGIN;
SET LOCAL statement_timeout='5s';
SET LOCAL lock_timeout='2s';
LOCK TABLE public.wire_ingestion_inbox, public.wire_recommendation_journal,
 public.appview_jetstream_checkpoints, public.wire_recommendation_dependency_recovery IN SHARE ROW EXCLUSIVE MODE;
DO $check$ BEGIN
 IF EXISTS(SELECT 1 FROM public.wire_ingestion_inbox WHERE environment={env} AND source_generation={generation})
 OR EXISTS(SELECT 1 FROM public.wire_recommendation_journal WHERE environment={env} AND source_generation={generation})
 OR EXISTS(SELECT 1 FROM public.appview_jetstream_checkpoints WHERE environment={env} AND source_generation={generation})
 OR EXISTS(SELECT 1 FROM public.wire_recommendation_dependency_recovery WHERE environment={env} AND source_generation={generation})
 THEN RAISE EXCEPTION 'Receipt source must be fresh before intake'; END IF;
END $check$;
CREATE SCHEMA {SCHEMA};
REVOKE ALL ON SCHEMA {SCHEMA} FROM PUBLIC;
CREATE TABLE {SCHEMA}.scope (
 singleton BOOLEAN PRIMARY KEY CHECK(singleton), environment TEXT NOT NULL,
 source_generation TEXT NOT NULL, after_seq BIGINT NOT NULL, before_seq BIGINT NOT NULL,
 maximum_receipts BIGINT NOT NULL, installed_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp());
INSERT INTO {SCHEMA}.scope VALUES(TRUE,{env},{generation},{lower},{upper},{value['maximum_receipts']},clock_timestamp());
CREATE TABLE {SCHEMA}.applied (
 environment TEXT NOT NULL CHECK(environment={env}),
 source_generation TEXT NOT NULL CHECK(source_generation={generation}),
 seq BIGINT NOT NULL CHECK(seq>{lower} AND seq<={upper}),
 PRIMARY KEY(environment,source_generation,seq));
CREATE FUNCTION {SCHEMA}.acknowledge() RETURNS trigger LANGUAGE plpgsql AS $receipt$
BEGIN
 IF NEW.environment <> {env} OR NEW.source_generation <> {generation} THEN RETURN NEW; END IF;
 IF TG_TABLE_NAME='wire_ingestion_inbox' THEN
   IF NEW.status <> 'applied' OR NEW.applied_at IS NULL THEN RETURN NEW; END IF;
 ELSIF NEW.status NOT IN ('resolved','deleted') THEN RETURN NEW;
 END IF;
 INSERT INTO {SCHEMA}.applied(environment,source_generation,seq)
 VALUES(NEW.environment,NEW.source_generation,NEW.seq) ON CONFLICT DO NOTHING;
 RETURN NEW;
END $receipt$;
CREATE TRIGGER tsw92_trial_inbox_ack AFTER INSERT OR UPDATE OF status ON public.wire_ingestion_inbox
 FOR EACH ROW EXECUTE FUNCTION {SCHEMA}.acknowledge();
CREATE TRIGGER tsw92_trial_journal_ack AFTER INSERT OR UPDATE OF status ON public.wire_recommendation_journal
 FOR EACH ROW EXECUTE FUNCTION {SCHEMA}.acknowledge();
COMMIT;"""


def progress_sql(config):
    value = scope(config)
    env, generation = literal(value["environment"]), literal(value["source_generation"])
    return f"""SELECT json_build_object(
 'completed',(SELECT count(*) FROM {SCHEMA}.applied),
 'snapshot_complete',EXISTS(SELECT 1 FROM public.appview_jetstream_checkpoints
   WHERE environment={env} AND source_generation={generation}
    AND replay_state='snapshot_complete' AND replay_after_seq={value['after_seq']}
    AND replay_before_seq={value['before_seq']} AND replay_sealed_seq={value['before_seq']}),
 'drain_complete',NOT EXISTS(SELECT 1 FROM public.wire_ingestion_inbox
   WHERE environment={env} AND source_generation={generation}
    AND (status IN ('pending','retry','leased','dead_letter')
      OR (status IN ('deferred','superseded') AND NOT EXISTS(
       SELECT 1 FROM public.wire_recommendation_journal j
       WHERE j.environment={env} AND j.source_generation={generation} AND j.seq=wire_ingestion_inbox.seq))))
   AND NOT EXISTS(SELECT 1 FROM public.wire_recommendation_journal
    WHERE environment={env} AND source_generation={generation} AND status IN ('pending','conflict'))
   AND NOT EXISTS(SELECT 1 FROM public.wire_recommendation_dependency_recovery
    WHERE environment={env} AND source_generation={generation}
     AND status IN ('pending','leased','unavailable','unsupported')),
 'receipt_bytes',pg_total_relation_size('{SCHEMA}.applied'),
 'scope_matches',EXISTS(SELECT 1 FROM {SCHEMA}.scope WHERE environment={env}
   AND source_generation={generation} AND after_seq={value['after_seq']}
   AND before_seq={value['before_seq']} AND maximum_receipts={value['maximum_receipts']}),
 'instrumentation_valid',(SELECT count(*)=2 FROM pg_trigger
   WHERE ((tgname='tsw92_trial_inbox_ack' AND tgrelid='public.wire_ingestion_inbox'::regclass)
     OR (tgname='tsw92_trial_journal_ack' AND tgrelid='public.wire_recommendation_journal'::regclass))
    AND tgenabled='O' AND tgtype=21
    AND tgfoid='{SCHEMA}.acknowledge()'::regprocedure)
   AND (SELECT count(*)=2 FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
    WHERE n.nspname='{SCHEMA}' AND c.relname IN ('scope','applied') AND c.relpersistence='p'))"""


def validated_progress(config, observed):
    value = scope(config)
    if (type(observed.get("completed")) is not int or not 0 <= observed["completed"] <= value["maximum_receipts"]
            or type(observed.get("snapshot_complete")) is not bool
            or type(observed.get("drain_complete")) is not bool
            or observed.get("scope_matches") is not True or observed.get("instrumentation_valid") is not True
            or type(observed.get("receipt_bytes")) is not int
            or not 0 <= observed["receipt_bytes"] <= value["maximum_receipt_bytes"]):
        raise Error("Receipt evidence lost its exact source, bounds, or instrumentation")
    return {key: observed[key] for key in ("completed", "snapshot_complete", "drain_complete", "receipt_bytes")}


def verified_connection(config, environment=os.environ):
    # This does real provider/private-origin/restore verification before any DDL.
    provider.execute("identity", config, environment)
    value = scope(config)
    path = provider.private_path(value["runtime_environment_file"])
    if hashlib.sha256(path.read_bytes()).hexdigest() != value["runtime_environment_sha256"]:
        raise Error("Receipt runtime file differs from its reviewed hash")
    runtime = json.loads(path.read_text())
    url = runtime["DATABASE_URL"]
    parsed = provider.trial.replay.validate_target(url)
    if (parsed.hostname != config["target"]["host"] or parsed.path != "/" + config["target"]["database"]
            or runtime.get("APP_ENV") != value["environment"]
            or runtime.get("WIRE_INBOX_SOURCE_GENERATIONS") != value["source_generation"]):
        raise Error("Receipt database or worker source differs from isolated target")
    return provider.trial.replay.Postgres(value.get("psql", "psql")), url


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("install", "sample"))
    parser.add_argument("config", type=Path)
    args = parser.parse_args()
    try:
        config = json.loads(args.config.read_text())
        pg, url = verified_connection(config)
        if args.mode == "install":
            pg.run(url, installation_sql(config), statement_timeout_seconds=5)
            print(json.dumps({"installed": True, "semantics": scope(config)["semantics"]}))
        else:
            print(json.dumps(validated_progress(config, pg.query(url, progress_sql(config)))))
    except Exception:
        print("Trial receipt operation failed; retain evidence and check isolated configuration.", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
