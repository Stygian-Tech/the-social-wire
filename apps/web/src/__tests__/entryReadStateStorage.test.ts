import { describe, expect, it } from "bun:test";
import {
  parseReadStateJson,
  READ_STATE_STORAGE_KEY,
  loadReadState,
  saveReadState,
} from "@/lib/entryReadStateStorage";

describe("parseReadStateJson", () => {
  it("returns empty object for null or empty", () => {
    expect(parseReadStateJson(null)).toEqual({});
    expect(parseReadStateJson("")).toEqual({});
  });

  it("parses valid string map", () => {
    const uri = "at://did:plc:abc/site.standard.entry/xyz";
    expect(
      parseReadStateJson(JSON.stringify({ [uri]: "2026-01-01T00:00:00.000Z" }))
    ).toEqual({ [uri]: "2026-01-01T00:00:00.000Z" });
  });

  it("drops non-string values", () => {
    expect(
      parseReadStateJson(
        JSON.stringify({ ok: "2026-01-01T00:00:00.000Z", bad: 1, x: null })
      )
    ).toEqual({ ok: "2026-01-01T00:00:00.000Z" });
  });

  it("returns {} for invalid JSON", () => {
    expect(parseReadStateJson("not-json")).toEqual({});
  });
});

describe("loadReadState / saveReadState", () => {
  it("round-trips via Storage", () => {
    const mem = new Map<string, string>();
    const storage = {
      getItem: (k: string) => mem.get(k) ?? null,
      setItem: (k: string, v: string) => {
        mem.set(k, v);
      },
    };
    const uri = "at://did:plc:abc/site.standard.entry/xyz";
    saveReadState(storage, { [uri]: "2026-05-12T12:00:00.000Z" });
    expect(mem.get(READ_STATE_STORAGE_KEY)).toContain(uri);
    expect(loadReadState(storage)).toEqual({ [uri]: "2026-05-12T12:00:00.000Z" });
  });
});
