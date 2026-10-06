#!/usr/bin/env python3
"""Compare complete Swift/Go edition JSON using fixed-clock, seeded snapshots."""

import argparse
import json
import random
import subprocess

argument_parser = argparse.ArgumentParser()
argument_parser.add_argument("--swift", required=True)
argument_parser.add_argument("--go", required=True)
args = argument_parser.parse_args()
randomizer = random.Random(2049)
for case in range(35):
    items = []
    for item_index in range(0 if case == 0 else randomizer.randrange(1, 90)):
        item = {
            "itemId": str(randomizer.randrange(1, 60)),
            "canonicalUrl": f"https://example.com/{item_index}",
            "title": f"Story {item_index}",
            "source": {
                "name": f"Publisher {item_index % 9}",
                "domain": f"publisher-{item_index % 9}.example",
            },
            "reasons": randomizer.sample(
                [
                    "breaking_story",
                    "widely_discussed",
                    "shared_across_communities",
                    "resurfacing",
                    "fresh_publication",
                ],
                randomizer.randrange(0, 4),
            ),
            "provenance": ["direct_share"] * 12,
        }
        if item_index % 7 == 0:
            item["representativeUri"] = (
                f"at://did:plc:a/site.standard.document/{item_index}"
            )
        if item_index % 3 == 0:
            item["source"]["publicationKey"] = f" Publication {item_index % 11} "
        items.append(item)
    accounts = [
        {
            "account": {"did": f"did:plc:{randomizer.randrange(1, 12)}"},
            "distinctStoryCount": randomizer.randrange(0, 12),
            "distinctSpeakerCount": randomizer.randrange(0, 12),
            "bestStoryRank": randomizer.randrange(0, 20),
        }
        for _ in range(30)
    ]
    data = json.dumps(
        {"items": items, "accounts": accounts, "asOf": "2026-10-05T12:00:00Z"}
    ).encode()

    def run(binary):
        return json.loads(
            subprocess.run([binary], input=data, check=True, capture_output=True).stdout
        )

    expected, actual = (run(args.swift), run(args.go))
    if expected != actual:
        raise AssertionError(
            f"edition case {case} differs: Swift={json.dumps(expected)} Go={json.dumps(actual)}"
        )
print("Swift/Go edition parity passed: 35 snapshots")
