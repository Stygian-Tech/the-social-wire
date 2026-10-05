import { describe, expect, test, spyOn } from "bun:test";
import type { OAuthSession } from "@atproto/oauth-client-browser";
import * as Gateway from "@/lib/socialWireGatewayClient";
import {
  getStandardReaderLists,
  mergeStandardReaderListsPage,
  searchStandardReaderLists,
  resolveStandardReaderList,
  refreshStandardReaderLists,
} from "@/lib/standardReaderListsClient";
import { parseNdjsonLinesForTest } from "@/lib/bootstrapStreamClient";
const oauth = {} as OAuthSession;
const list = {
  uri: "at://did:plc:creator/app.standard-reader.list/tech",
  name: "Tech",
  creatorDid: "did:plc:creator",
  publications: [],
  users: [],
  owned: false,
  saved: true,
};
describe("Standard Reader Lists contracts", () => {
  test("shows the resolver's actionable error for an unsupported list URL", async () => {
    const fetch = spyOn(Gateway, "gatewayFetch").mockResolvedValue(
      Response.json(
        { error: { message: "Enter a Standard Reader list URL or AT URI." } },
        { status: 400 },
      ),
    );
    try {
      await expect(resolveStandardReaderList(oauth, "https://example.com/list"))
        .rejects.toThrow("Enter a Standard Reader list URL or AT URI.");
    } finally {
      fetch.mockRestore();
    }
  });
  test("resolves a pasted share URL through AppView into a canonical list reference", async () => {
    const input = "https://standard-reader.app/l/did:plc:zu7vdjfbiijes5rjcaaqtzke/3mwwy7lufik34";
    const canonical = {
      ...list,
      uri: "at://did:plc:zu7vdjfbiijes5rjcaaqtzke/app.standard-reader.list/3mwwy7lufik34",
      creatorDid: "did:plc:zu7vdjfbiijes5rjcaaqtzke",
    };
    const fetch = spyOn(Gateway, "gatewayFetch").mockImplementation(
      async (session, path, init) => {
        expect(session).toBe(oauth);
        expect(path).toBe("/v1/lists/resolve");
        expect(init?.method).toBe("POST");
        expect(JSON.parse(init?.body as string)).toEqual({ input });
        return Response.json({ list: canonical });
      },
    );
    try {
      expect(await resolveStandardReaderList(oauth, input)).toEqual(canonical);
    } finally {
      fetch.mockRestore();
    }
  });
  test("uses authenticated projection and creator-only search without PDS proxy writes", async () => {
    const calls: { path: string; method?: string; body?: BodyInit | null }[] =
      [];
    const fetch = spyOn(Gateway, "gatewayFetch").mockImplementation(
      async (_oauth, path, init) => {
        calls.push({ path, method: init?.method, body: init?.body });
        return Response.json(
          path.endsWith("resolve")
            ? { list }
            : { lists: [list], refreshedAt: "now" },
        );
      },
    );
    try {
      expect((await getStandardReaderLists(oauth)).lists).toHaveLength(1);
      await searchStandardReaderLists(oauth, "creator.example");
      expect((await resolveStandardReaderList(oauth, list.uri)).uri).toBe(
        list.uri,
      );
      await refreshStandardReaderLists(oauth);
      expect(calls.map((call) => call.path)).toEqual([
        "/v1/lists",
        "/v1/lists/search?creator=creator.example",
        "/v1/lists/resolve",
        "/v1/lists/refresh",
      ]);
      expect(calls.map((call) => call.method)).toEqual([
        "GET",
        "GET",
        "POST",
        "POST",
      ]);
      expect(JSON.parse(calls[2]!.body as string)).toEqual({ input: list.uri });
    } finally {
      fetch.mockRestore();
    }
  });
  test("bootstrap lists event preserves completeness evidence", () => {
    const events = parseNdjsonLinesForTest(
      JSON.stringify({
        kind: "lists",
        lists: { lists: [list], refreshedAt: "now", complete: true },
      }),
    );
    expect(events).toEqual([
      {
        kind: "lists",
        payload: { lists: [list], refreshedAt: "now", complete: true },
      },
    ]);
    expect(
      parseNdjsonLinesForTest(
        JSON.stringify({
          kind: "lists",
          lists: { lists: [list], refreshedAt: "now" },
        }),
      ),
    ).toEqual([]);
  });
  test("partial provider reconciliation retains cached saves until a complete projection arrives", () => {
    const prior = { lists: [list], refreshedAt: "previous" };
    expect(
      mergeStandardReaderListsPage(prior, {
        lists: [],
        refreshedAt: "now",
        complete: false,
      }).lists,
    ).toEqual([list]);
    expect(
      mergeStandardReaderListsPage(prior, {
        lists: [],
        refreshedAt: "now",
        complete: true,
      }).lists,
    ).toEqual([]);
  });
});
