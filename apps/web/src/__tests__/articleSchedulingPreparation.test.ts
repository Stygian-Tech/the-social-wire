import { describe, expect, test } from "bun:test";
import { prepareScheduledArticle } from "../lib/articles/articleSchedulingPreparation";
import type { ArticlePublishInput } from "../lib/articles/articlePublishingTypes";
import { setupGoPreparationService } from "./support/anypubService";

const scheduledAt = "2099-01-01T12:00:00.000Z";
function input(host: ArticlePublishInput["publication"]["host"] = "markpub"): ArticlePublishInput {
  return { publication: { uri: "at://did:plc:author/site.standard.publication/publication", cid: "publication-cid", name: "Publication", url: "https://example.com", host, record: {} }, title: "Scheduled Article", path: "/my-article", tags: ["test", "test"], markdown: "# A Heading\n\nA paragraph.", recordKey: "3m234567abcde" };
}
describe("scheduled article preparation with the real pinned AnyPubKit service", () => {
  setupGoPreparationService();
  test.each(["markpub", "leaflet", "unknown"] as const)("prepares %s content with stable identity and publication timestamps", async host => {
    const prepared = await prepareScheduledArticle(input(host), scheduledAt);
    expect(prepared.publishRkey).toBe("3m234567abcde");
    expect(prepared.url).toBe("https://example.com/my-article");
    expect(prepared.record).toMatchObject({ $type: "site.standard.document", site: input().publication.uri, title: "Scheduled Article", publishedAt: scheduledAt, updatedAt: scheduledAt, path: "/my-article", tags: ["test"] });
    expect(prepared.record.content).toBeTruthy();
  });
  test("rejects offloaded text without uploading or writing a record", async () => {
    await expect(prepareScheduledArticle({ ...input(), markdown: "a".repeat(103_000) }, scheduledAt)).rejects.toThrow("Deferred Asset Uploads");
  });
});

test("rejects unsupported inputs before contacting any service", async () => {
  const original = globalThis.fetch;
  let calls = 0;
  globalThis.fetch = (async () => { calls++; throw new Error("Unexpected network request"); }) as unknown as typeof fetch;
  try {
    for (const candidate of [input("offprint"), input("pckt"), { ...input(), markdown: "![image](https://example.com/image.png)" }, { ...input(), markdown: "article-asset://image" }, { ...input(), markdown: "blob:cid" }, { ...input(), recordKey: undefined }, { ...input(), path: "/../secret" }, { ...input(), existing: { uri: "at://old", cid: "old", record: {} } }]) {
      await expect(prepareScheduledArticle(candidate, scheduledAt)).rejects.toThrow();
    }
    expect(calls).toBe(0);
  } finally { globalThis.fetch = original; }
});
