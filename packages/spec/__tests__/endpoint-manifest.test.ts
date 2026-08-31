import { describe, expect, it } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";

const SPEC_ROOT = join(import.meta.dir, "..");
const manifest = JSON.parse(readFileSync(join(SPEC_ROOT, "endpoint-manifest.json"), "utf8")) as {
  version: number;
  entries: Array<{ surface: string; method: string; path: string; classification: string; xrpcNsid?: string }>;
};
const openapi = Bun.YAML.parse(readFileSync(join(SPEC_ROOT, "openapi.yaml"), "utf8")) as {
  paths: Record<string, Record<string, unknown>>;
  "x-tsw-endpoint-manifest": string;
};

describe("endpoint transport manifest", () => {
  it("is linked from OpenAPI and classifies every OpenAPI operation exactly once", () => {
    expect(openapi["x-tsw-endpoint-manifest"]).toBe("./endpoint-manifest.json");
    const documented = Object.entries(openapi.paths).flatMap(([path, item]) =>
      ["get", "post", "put", "patch", "delete"]
        .filter((method) => item[method])
        .map((method) => `${method.toUpperCase()} ${path}`)
    );
    const classified = manifest.entries
      .filter((entry) => entry.surface === "openapi")
      .map((entry) => `${entry.method} ${entry.path}`);
    expect(new Set(classified).size).toBe(classified.length);
    expect(classified.sort()).toEqual(documented.sort());
  });

  it("maps XRPC migrations to valid method-specific NSIDs and verbs", () => {
    const migrations = manifest.entries.filter((entry) => entry.classification === "xrpc-migration");
    expect(migrations.length).toBeGreaterThan(30);
    for (const entry of migrations) {
      expect(entry.xrpcNsid).toMatch(/^app\.thesocialwire\.(appview|publication|sync|operations|discovery)\.[a-z][A-Za-z0-9]*$/);
      const verb = entry.xrpcNsid!.split(".").at(-1)!;
      const query = /^(get|list)/.test(verb);
      expect(query ? entry.method : ["POST", "PATCH", "DELETE"].includes(entry.method)).toBeTruthy();
    }
  });

  it("keeps protocol-incompatible and externally owned transports explicit", () => {
    const byPath = new Map(manifest.entries.map((entry) => [`${entry.method} ${entry.path}`, entry.classification]));
    expect(byPath.get("GET /v1/appview/bootstrap-stream")).toBe("stream");
    expect(byPath.get("GET /v1/operations/events/stream")).toBe("stream");
    expect(byPath.get("GET /api/bluesky-card-thumb")).toBe("media-proxy");
    expect(byPath.get("GET /xrpc/link.latr.bookmarks.listBookmarks")).toBe("foreign-xrpc");
    expect(byPath.get("GET /xrpc/link.latr.bookmarks.listTags")).toBe("foreign-xrpc");
    expect(byPath.get("POST /xrpc/link.latr.bookmarks.setTags")).toBe("foreign-xrpc");
    expect(byPath.get("POST /xrpc/link.latr.bookmarks.renameTag")).toBe("foreign-xrpc");
    expect(byPath.get("POST /xrpc/link.latr.bookmarks.deleteTag")).toBe("foreign-xrpc");
    expect(byPath.get("GET /v1/semble/collections")).toBe("foreign-rest");
    expect(byPath.get("GET /v1/semble/collection")).toBe("foreign-rest");
    expect(byPath.get("GET /v1/semble/connections")).toBe("foreign-rest");
    expect(byPath.has("POST /channel")).toBe(false);
    expect(manifest.entries.some((entry) => entry.surface === "tap")).toBe(false);
  });

  it("uses GET for foreign XRPC queries and POST for foreign XRPC procedures", () => {
    const methods = manifest.entries.filter(
      (entry) => entry.classification === "foreign-xrpc"
    );
    for (const entry of methods) {
      const lexiconPath = join(
        SPEC_ROOT,
        "../lexicons",
        `${entry.xrpcNsid!.replaceAll(".", "/")}.json`
      );
      const lexicon = JSON.parse(readFileSync(lexiconPath, "utf8")) as {
        defs: { main: { type: "query" | "procedure" } };
      };
      expect(entry.method, entry.xrpcNsid).toBe(
        lexicon.defs.main.type === "query" ? "GET" : "POST"
      );
    }
  });
});
