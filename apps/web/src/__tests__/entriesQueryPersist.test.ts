import { expect, test } from "bun:test";
import type { Query } from "@tanstack/react-query";
import { shouldPersistEntriesQuery } from "@/lib/entriesQueryPersist";

function query(key: unknown[], counts = [1], status: Query["state"]["status"] = "success") {
  return {
    queryKey: key,
    state: { status, data: { pages: counts.map(count => ({ entries: Array(count).fill(null) })) } },
  };
}

test("persists private feeds only with a nonempty viewer key", () => {
  for (const kind of ["entries", "aggregateEntries"]) {
    expect(shouldPersistEntriesQuery(query([kind, "did:plc:viewer"]))).toBe(true);
    for (const viewer of [undefined, null, "", 42]) {
      expect(shouldPersistEntriesQuery(query([kind, viewer]))).toBe(false);
    }
  }
});

test("allows public Wire feeds without a viewer but rejects unknown query kinds", () => {
  for (const kind of ["wireEntries", "wireEditionMore"]) {
    expect(shouldPersistEntriesQuery(query([kind]))).toBe(true);
  }
  expect(shouldPersistEntriesQuery(query(["blueskySocial", "did:plc:viewer"]))).toBe(false);
});

test("persists only successful nonempty feeds within both cache bounds", () => {
  expect(shouldPersistEntriesQuery(query(["wireEntries"], [50, 50, 50]))).toBe(true);
  expect(shouldPersistEntriesQuery(query(["wireEntries"], [51, 50, 50]))).toBe(false);
  expect(shouldPersistEntriesQuery(query(["wireEntries"], [1, 1, 1, 1]))).toBe(false);
  expect(shouldPersistEntriesQuery(query(["wireEntries"], []))).toBe(false);
  for (const status of ["pending", "error"] as const) {
    expect(shouldPersistEntriesQuery(query(["wireEntries"], [1], status))).toBe(false);
  }
});
