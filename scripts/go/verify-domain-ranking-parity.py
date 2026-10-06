#!/usr/bin/env python3
"""Compare Swift/Go Finance and Sports ranked IDs; this does not test resolver or catalog parity."""

import argparse
import json
import random
import subprocess

argument_parser = argparse.ArgumentParser()
argument_parser.add_argument("--swift", required=True)
argument_parser.add_argument("--go", required=True)
args = argument_parser.parse_args()
randomizer = random.Random(640)
entities = [
    {
        "id": kind,
        "name": kind,
        "kind": kind,
        "competitionIDs": [],
        "aliases": [],
        "providerIDs": {},
        "active": True,
    }
    for kind in ["sport", "team", "athlete", "competition", "classification"]
]
for case in range(45):
    finance, sports = ([], [])
    for item_index in range(0 if case == 0 else randomizer.randrange(1, 140)):
        item = {
            "itemId": str(randomizer.randrange(1, 120)),
            "canonicalUrl": f"https://example.com/{randomizer.randrange(1, 130)}",
            "title": randomizer.choice(
                [
                    f"Story {item_index}",
                    "The earnings announcement has further coverage",
                    "MÜNCHEN team wins a championship",
                ]
            ),
            "source": {
                "name": "Publication",
                "domain": f"publisher-{randomizer.randrange(0, 5)}.example",
            },
            "reasons": [],
            "provenance": [],
        }
        if item_index % 3 == 0:
            item["publishedAt"] = f"2026-10-05T{randomizer.randrange(0, 24):02}:00:00Z"
        base = round(randomizer.random() * 10, 8)
        finance.append(
            {
                "item": item,
                "analysis": {
                    "eligible": randomizer.random() > 0.1,
                    "materiality": randomizer.choice(
                        [
                            "earnings",
                            "filing",
                            "merger",
                            "regulation",
                            "leadership",
                            "price-chatter",
                            "reporting",
                        ]
                    ),
                    "associations": [
                        {
                            "instrumentID": randomizer.choice(["a", "b", "c"]),
                            "confidence": 1,
                            "evidence": [],
                            "prominence": 0,
                            "resolverVersion": "finance-resolver-v3.4",
                        }
                    ],
                    "sectorIDs": [randomizer.choice(["s", "other"])],
                },
                "baseScore": base,
                "majorGlobal": randomizer.random() > 0.7,
            }
        )
        version = randomizer.choice(["sports-resolver-v14"] * 8 + ["old"])
        sports.append(
            {
                "item": item,
                "analysis": {
                    "resolverVersion": version,
                    "eligible": randomizer.random() > 0.1,
                    "materiality": randomizer.choice(
                        [
                            "championship",
                            "record",
                            "transfer",
                            "injury",
                            "routine-chatter",
                            "reporting",
                        ]
                    ),
                    "associations": [
                        {
                            "entityID": randomizer.choice(
                                ["team", "athlete", "competition", "classification"]
                            ),
                            "confidence": randomizer.choice([1, 0.95, 0.8]),
                            "evidence": [],
                            "prominence": 0,
                            "resolverVersion": version,
                        }
                    ],
                    "sportIDs": [randomizer.choice(["sport", "other"])],
                    "competitionIDs": ["competition"],
                },
                "baseScore": base,
                "majorGlobal": randomizer.random() > 0.7,
            }
        )
    request = {
        "finance": finance,
        "sports": sports,
        "instrumentIDs": randomizer.sample(["a", "b", "c"], randomizer.randrange(0, 4)),
        "sectorIDs": randomizer.sample(["s", "other"], randomizer.randrange(0, 3)),
        "followIDs": randomizer.sample(
            ["team", "sport", "competition"], randomizer.randrange(0, 4)
        ),
        "muteIDs": randomizer.sample(
            ["team", "sport", "classification"], randomizer.randrange(0, 4)
        ),
        "entities": entities,
        "reserveGlobal": bool(case % 2),
    }
    data = json.dumps(request).encode()

    def run(binary):
        return json.loads(
            subprocess.run([binary], input=data, check=True, capture_output=True).stdout
        )

    expected, actual = (run(args.swift), run(args.go))
    if expected != actual:
        raise AssertionError(
            f"domain ranking case {case} differs: Swift={expected} Go={actual}"
        )
print("Swift/Go Finance and Sports ranking parity passed: 45 snapshots")
