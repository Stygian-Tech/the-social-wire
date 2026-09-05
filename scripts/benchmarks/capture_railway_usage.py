#!/usr/bin/env python3
"""Capture unconverted Railway usage for an explicit, bounded UTC interval."""

import argparse
from datetime import datetime, timedelta, timezone
import json
import math
import os
from pathlib import Path
import re
import subprocess
import uuid


MEASUREMENTS = ("CPU_USAGE", "MEMORY_USAGE_GB", "NETWORK_TX_GB", "DISK_USAGE_GB", "BACKUP_USAGE_GB")
QUERY = """query CostUsage($project: String!, $start: DateTime!, $end: DateTime!) {
  usage(projectId: $project, startDate: $start, endDate: $end,
    includeDeleted: true, groupBy: [SERVICE_ID, ENVIRONMENT_ID],
    measurements: [CPU_USAGE, MEMORY_USAGE_GB, NETWORK_TX_GB, DISK_USAGE_GB, BACKUP_USAGE_GB]) {
    measurement value
    tags { serviceId environmentId }
  }
}"""


class CaptureError(RuntimeError):
    pass


def utc_timestamp(value):
    if not re.fullmatch(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,6})?(?:Z|\+00:00)", value):
        raise CaptureError("Dates must be explicit UTC timestamps, for example 2026-09-05T00:00:00Z")
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        raise CaptureError("Invalid UTC date") from None


def capture(project, start, end):
    try:
        if str(uuid.UUID(project)) != project:
            raise ValueError()
    except (ValueError, AttributeError):
        raise CaptureError("Project must be a canonical Railway project UUID") from None
    start_date, end_date = utc_timestamp(start), utc_timestamp(end)
    if not timedelta(0) < end_date - start_date <= timedelta(days=31):
        raise CaptureError("Usage window must be positive and no longer than 31 days")
    if end_date > datetime.now(timezone.utc):
        raise CaptureError("Usage window must end in the past")
    variables = {"project": project, "start": start, "end": end}
    try:
        response = subprocess.run(
            ["railway", "api", QUERY, "--variables", json.dumps(variables), "--compact"],
            capture_output=True, text=True, timeout=60, check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        raise CaptureError("Railway CLI could not complete the read-only usage query") from None
    if response.returncode:
        # CLI diagnostics can include credentials; do not copy them into evidence.
        raise CaptureError("Railway usage query failed; no usage artifact was written")
    try:
        payload = json.loads(response.stdout)
    except (ValueError, TypeError):
        raise CaptureError("Railway did not return a JSON usage response") from None
    if not isinstance(payload, dict) or payload.get("errors"):
        raise CaptureError("Railway returned GraphQL errors; partial usage is not accepted")
    data = payload.get("data")
    rows = data.get("usage") if isinstance(data, dict) else None
    if not isinstance(rows, list):
        raise CaptureError("Railway response is missing the usage list")
    for row in rows:
        if not isinstance(row, dict):
            raise CaptureError("Railway returned an invalid usage row")
        value, tags = row.get("value"), row.get("tags")
        if (row.get("measurement") not in MEASUREMENTS
                or isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value)
                or not isinstance(tags, dict) or not {"serviceId", "environmentId"} <= tags.keys()
                or any(tags[key] is not None and not isinstance(tags[key], str) for key in ("serviceId", "environmentId"))):
            raise CaptureError("Railway returned an invalid usage measurement or grouping")
    return {
        "project_id": project, "requested_window_utc": {"start": start, "end": end},
        "captured_at_utc": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
        "include_deleted": True, "group_by": ["SERVICE_ID", "ENVIRONMENT_ID"],
        "requested_measurements": list(MEASUREMENTS),
        "raw_units": {name: "Railway " + name + " (unconverted)" for name in MEASUREMENTS},
        "interpretation": "Raw provider usage, not dollars or instantaneous resource metrics. Missing rows are not zero usage.",
        "usage": [{"measurement": row["measurement"], "value": row["value"],
                   "tags": {key: row["tags"][key] for key in ("serviceId", "environmentId")}} for row in rows],
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project", required=True)
    parser.add_argument("--start", required=True)
    parser.add_argument("--end", required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if args.output.exists():
        raise CaptureError("Output already exists; choose a new capture path")
    evidence = capture(args.project, args.start, args.end)
    # Exclusive creation protects earlier captures; credentials never enter this file.
    with open(args.output, "x", opener=lambda path, flags: os.open(path, flags, 0o600)) as output:
        json.dump(evidence, output, indent=2, allow_nan=False)
        output.write("\n")


if __name__ == "__main__":
    try:
        main()
    except (CaptureError, OSError) as error:
        raise SystemExit(str(error))
