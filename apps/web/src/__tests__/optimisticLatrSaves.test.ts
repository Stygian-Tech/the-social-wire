import { describe, expect, it } from "bun:test";

import {
  applyLatrSaveArchive,
  applyLatrSaveDelete,
  applyLatrSaveUnarchive,
  upsertLatrSaveRow,
} from "@/lib/optimisticLatrSaves";
import type { MergedLatrSave } from "@/lib/pdsClient";

const externalRow = (
  itemRkey: string,
  normalizedUrl: string,
  savedAt: string
): MergedLatrSave => ({
  kind: "external",
  normalizedUrl,
  url: normalizedUrl,
  savedAt,
  externalRkey: "EXT",
  itemRkey,
  externalUri: `at://did/com.latr.saved.external/EXT`,
  itemUri: `at://${itemRkey}`,
  subjectUri: `at://did/com.latr.saved.external/EXT`,
});

describe("optimisticLatrSaves", () => {
  it("removes a row from both active and archived caches on delete", () => {
    const active = [externalRow("A", "https://a.test", "2026-01-02T00:00:00.000Z")];
    const archived = [externalRow("A", "https://a.test", "2026-01-02T00:00:00.000Z")];
    const next = applyLatrSaveDelete(active, archived, "A");
    expect(next.active).toEqual([]);
    expect(next.archived).toEqual([]);
  });

  it("moves a row from active to archived", () => {
    const active = [externalRow("A", "https://a.test", "2026-01-02T00:00:00.000Z")];
    const next = applyLatrSaveArchive(active, [], "A");
    expect(next?.active).toEqual([]);
    expect(next?.archived[0]?.state).toBe("archived");
  });

  it("moves a row from archived back to active", () => {
    const archived = [
      {
        ...externalRow("A", "https://a.test", "2026-01-02T00:00:00.000Z"),
        state: "archived" as const,
      },
    ];
    const next = applyLatrSaveUnarchive([], archived, "A");
    expect(next?.archived).toEqual([]);
    expect(next?.active[0]?.state).toBe("unread");
  });

  it("inserts newest saves first", () => {
    const existing = [externalRow("OLD", "https://old.test", "2026-01-01T00:00:00.000Z")];
    const inserted = upsertLatrSaveRow(
      existing,
      externalRow("NEW", "https://new.test", "2026-01-03T00:00:00.000Z")
    );
    expect(inserted.map((row) => row.itemRkey)).toEqual(["NEW", "OLD"]);
  });
});
