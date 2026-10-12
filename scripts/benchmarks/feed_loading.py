#!/usr/bin/env python3
"""Bounded public API benchmarks; repeated requests do not prove server cache warmth."""

import argparse
import json
import math
import subprocess
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import urlencode, urlparse

METHODS = {"wire": "getWire", "finance": "getFinance", "sports": "getSports"}


def percentile(values, percent):
    ordered = sorted(values)
    return ordered[max(0, math.ceil(len(ordered) * percent / 100) - 1)] if ordered else None


def probe(origin, feed, cursor=None):
    query = {"lang": "en", "limit": "30"}
    if cursor:
        query["cursor"] = cursor
    target = origin.rstrip("/") + "/xrpc/app.thesocialwire.discovery." + METHODS[feed] + "?" + urlencode(query)
    with tempfile.TemporaryDirectory(prefix="tsw-feed-probe-") as directory:
        body = Path(directory) / "response.json"
        result = subprocess.run([
            "curl", "--silent", "--show-error", "--max-time", "35", "--max-filesize", str(8 << 20),
            "--output", str(body), "--write-out", "%{json}", target,
        ], capture_output=True, text=True, check=False)
        try:
            metrics = json.loads(result.stdout)
        except json.JSONDecodeError:
            metrics = {}
        try:
            response = json.loads(body.read_text())
        except (OSError, json.JSONDecodeError):
            response = {}
        sample = {
            "at": datetime.now(timezone.utc).isoformat(),
            "status": metrics.get("http_code", 0),
            "ttfb_ms": metrics.get("time_starttransfer", 0) * 1000,
            "total_ms": metrics.get("time_total", 0) * 1000,
            "bytes": metrics.get("size_download", 0),
            "transport_failed": result.returncode != 0,
            "transport_exit_code": result.returncode,
            "item_count": len(response.get("items", [])),
            "degraded": response.get("degraded"),
            "source": response.get("source"),
        }
        return sample, response.get("cursor")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--origin", required=True)
    parser.add_argument("--feed", choices=METHODS, required=True)
    parser.add_argument("--samples", type=int, default=100)
    parser.add_argument("--continuation", action="store_true")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--interval", type=float, default=1.1, help="Seconds between samples; respects the anonymous one-request-per-second limiter.")
    args = parser.parse_args()
    origin = urlparse(args.origin)
    if origin.scheme != "https" or origin.username or origin.password or origin.path not in ("", "/") or origin.query or origin.fragment:
        parser.error("origin must be a credential-free HTTPS origin")
    if not 1 <= args.samples <= 1000:
        parser.error("samples must be between 1 and 1000")
    if args.interval < 1:
        parser.error("interval must be at least one second")
    samples = []
    report = {"origin": args.origin, "feed": args.feed, "auth": "public", "cache_state": "unverified", "page": "continuation" if args.continuation else "first", "samples": samples}
    cursor = None
    if args.continuation:
        _, cursor = probe(args.origin, args.feed)
        if not cursor:
            parser.error("feed has no continuation; no pagination measurements were recorded")
    for index in range(args.samples):
        sample, _ = probe(args.origin, args.feed, cursor)
        samples.append(sample)
        # Save progress so failures or interruptions never turn into missing evidence.
        good = [row["total_ms"] for row in samples if row["status"] == 200 and not row["transport_failed"]]
        report["summary"] = {"count": len(samples), "errors": len(samples) - len(good), "p50_ms": percentile(good, 50), "p95_ms": percentile(good, 95), "percentiles_exclude_errors": True}
        args.output.write_text(json.dumps(report, indent=2) + "\n")
        if sample["transport_exit_code"] in (5, 6, 7, 60):
            raise SystemExit("Benchmark transport unavailable; stopped without treating infrastructure failures as feed acceptance evidence.")
        if sample["status"] == 429:
            raise SystemExit("Benchmark rate limited; stopped to avoid load-distorted acceptance measurements.")
        if index + 1 < args.samples:
            time.sleep(args.interval)
    print(json.dumps({"feed": args.feed, **report["summary"]}))


if __name__ == "__main__":
    main()
