import { describe, expect, it } from "bun:test";
import { Lexicons } from "@atproto/lexicon";
import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";

const LEXICON_ROOT = join(import.meta.dir, "..");
const manifest = JSON.parse(
  readFileSync(join(LEXICON_ROOT, "../spec/endpoint-manifest.json"), "utf8")
) as { entries: Array<{ classification: string; xrpcNsid?: string }> };

function fileForNsid(nsid: string): string {
  return join(LEXICON_ROOT, ...nsid.split(".").slice(0, 2), `${nsid.split(".").slice(2).join("/")}.json`);
}

describe("Social Wire XRPC lexicons", () => {
  const nsids = [...new Set(manifest.entries
    .filter((entry) => entry.classification === "xrpc-migration")
    .map((entry) => entry.xrpcNsid!))];

  it("has one lexicon whose id matches every migration NSID", () => {
    for (const nsid of nsids) {
      const file = fileForNsid(nsid);
      expect(existsSync(file), nsid).toBe(true);
      const lexicon = JSON.parse(readFileSync(file, "utf8"));
      expect(lexicon.id).toBe(nsid);
      expect(lexicon.defs.main).toBeDefined();
    }
  });

  it("loads through the AT Protocol Lexicon validator", () => {
    const documents = ["app.thesocialwire.defs", ...nsids].map((nsid) =>
      JSON.parse(readFileSync(fileForNsid(nsid), "utf8"))
    );
    expect(() => new Lexicons(documents)).not.toThrow();
  });

  it("uses GET-compatible queries and POST-compatible procedures", () => {
    for (const nsid of nsids) {
      const lexicon = JSON.parse(readFileSync(fileForNsid(nsid), "utf8"));
      const method = nsid.split(".").at(-1)!;
      const expectedType = /^(get|list)/.test(method) ? "query" : "procedure";
      expect(lexicon.defs.main.type, nsid).toBe(expectedType);
      if (expectedType === "query") expect(lexicon.defs.main.parameters?.type).toBe("params");
      else expect(lexicon.defs.main.input?.encoding).toBe("application/json");
      expect(lexicon.defs.main.output.encoding).toBe("application/json");
      expect(lexicon.defs.main.errors.length).toBeGreaterThan(0);
    }
  });

  it("declares bounded identifiers for item methods", () => {
    for (const nsid of [
      "app.thesocialwire.appview.getEntry",
      "app.thesocialwire.operations.getBackfill",
      "app.thesocialwire.operations.getGapInvestigation",
      "app.thesocialwire.operations.getTrace",
    ]) {
      const lexicon = JSON.parse(readFileSync(fileForNsid(nsid), "utf8"));
      const params = lexicon.defs.main.parameters;
      expect(params.required).toHaveLength(1);
      expect(params.properties[params.required[0]].maxLength).toBeGreaterThan(0);
    }
  });

  it("matches the deployed AppView request field names", () => {
    const getFeed = JSON.parse(readFileSync(fileForNsid("app.thesocialwire.appview.getFeed"), "utf8"));
    expect(Object.keys(getFeed.defs.main.parameters.properties)).toEqual(["kind", "id", "filter", "cursor", "limit"]);
    expect(getFeed.defs.main.parameters.required).toEqual(["kind"]);

    const entries = JSON.parse(readFileSync(fileForNsid("app.thesocialwire.appview.listEntries"), "utf8"));
    expect(entries.defs.main.parameters.required).toEqual(["authorDid"]);
    expect(entries.defs.main.parameters.properties.publicationScopeAtUris.type).toBe("string");
    expect(entries.defs.main.parameters.properties.publicationSiteUrls.type).toBe("string");

    const put = JSON.parse(readFileSync(fileForNsid("app.thesocialwire.appview.putReadMark"), "utf8"));
    expect(put.defs.main.input.schema.required).toEqual(["subjectUri"]);
    expect(put.defs.main.input.schema.properties.readAt.format).toBe("datetime");

    const enroll = JSON.parse(readFileSync(fileForNsid("app.thesocialwire.appview.enrollSources"), "utf8"));
    expect(Object.keys(enroll.defs.main.input.schema.properties)).toEqual(["authorDids", "feedUrls"]);

    const markAll = JSON.parse(readFileSync(fileForNsid("app.thesocialwire.appview.markAllRead"), "utf8"));
    expect(markAll.defs.main.input.schema.required).toEqual(["scope"]);
    expect(markAll.defs.scope.properties.kind.knownValues).toEqual(["publication", "folder", "subscribed", "following"]);
  });

  it("requires concurrency fields on Operations mutations", () => {
    for (const name of ["updateGap", "pauseBackfill", "resumeBackfill", "cancelBackfill", "acknowledgeAlert", "resolveAlert", "retryAlert"]) {
      const lexicon = JSON.parse(readFileSync(fileForNsid(`app.thesocialwire.operations.${name}`), "utf8"));
      expect(lexicon.defs.main.input.schema.required, name).toContain("id");
      expect(lexicon.defs.main.input.schema.required, name).toContain("idempotencyKey");
      expect(lexicon.defs.main.input.schema.required, name).toContain("expectedVersion");
    }
  });

  it("keeps Operations metric filters and gap statuses aligned with the service contract", () => {
    const metrics = JSON.parse(
      readFileSync(fileForNsid("app.thesocialwire.operations.listMetrics"), "utf8")
    );
    expect(metrics.defs.main.parameters.properties.metric.maxLength).toBe(160);
    expect(metrics.defs.main.parameters.properties.collection.maxLength).toBe(256);

    const updateGap = JSON.parse(
      readFileSync(fileForNsid("app.thesocialwire.operations.updateGap"), "utf8")
    );
    expect(updateGap.defs.main.input.schema.properties.status.knownValues).toEqual([
      "suspected",
      "confirmed",
      "backfill_queued",
      "backfilling",
      "verification_required",
      "resolved",
      "ignored",
    ]);
  });
});
