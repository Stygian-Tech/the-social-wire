import { describe, expect, it } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { parseStandardSiteEmbed, type StandardSiteEmbed } from "@/lib/standardSiteEmbedClient";
import { StandardSiteArticleCard } from "@/components/Social/StandardSiteArticleCard";

const metadata: StandardSiteEmbed = {
  documentUri: "at://did:plc:qtapiembzpxlzsiagnc7eyy3/site.standard.document/3mdvrts2y7s25",
  publicationUri: "at://did:plc:qtapiembzpxlzsiagnc7eyy3/site.standard.publication/3m6apyszppk23",
  publicationName: "Babesky Blog", publicationUrl: "https://babesky.leaflet.pub",
  articleUrl: "https://babesky.leaflet.pub/3mdvrts2y7s25",
  title: "Lifestyles of the Burntout and Struggling", authorDid: "did:plc:qtapiembzpxlzsiagnc7eyy3", description: "Article summary",
};

describe("Standard.site Social article card", () => {
  it("accepts the shared verified document/publication contract", () => {
    expect(parseStandardSiteEmbed(metadata)).toEqual(metadata);
  });
  it("rejects missing identities, wrong collections and unsafe destinations", () => {
    for (const patch of [
      { documentUri: metadata.publicationUri }, { publicationUri: metadata.documentUri },
      { articleUrl: "javascript:alert(1)" }, { publicationUrl: "https://user:pass@evil.test" },
      { title: null }, { authorDid: undefined }, { description: {} },
    ]) expect(parseStandardSiteEmbed({ ...metadata, ...patch })).toBeNull();
  });
  it("keeps article and publication destinations distinct and actions outside links", () => {
    const root = document.createElement("div");
    root.innerHTML = renderToStaticMarkup(<StandardSiteArticleCard metadata={metadata} thumb="https://example.com/cover.jpg"><button>Subscribe</button><button>Recommend</button></StandardSiteArticleCard>);
    const links = [...root.querySelectorAll("a")];
    expect(links.find(link => link.textContent === "Read Article")?.getAttribute("href")).toBe(metadata.articleUrl);
    expect(links.find(link => link.textContent === "View Publication")?.getAttribute("href")).toBe(metadata.publicationUrl);
    expect(root.textContent).toContain(metadata.publicationName);
    expect(root.textContent).toContain(metadata.title);
    for (const button of root.querySelectorAll("button")) expect(button.closest("a")).toBeNull();
    for (const link of links) expect(link.rel).toBe("noopener noreferrer");
  });
  it("omits unsafe thumbnail URLs and escapes publisher text", () => {
    const html = renderToStaticMarkup(<StandardSiteArticleCard metadata={{ ...metadata, title: "<script>bad()</script>" }} thumb="javascript:alert(1)" />);
    expect(html).not.toContain("<script>");
    expect(html).not.toContain("<img");
  });
});

describe("article actions", () => {
  it("uses freshly loaded records and deletes all matching duplicates only", async () => {
    const { performStandardSiteArticleAction } = await import("@/lib/standardSiteEmbedActions");
    const calls: string[] = [];
    await performStandardSiteArticleAction({
      kind: "recommendation", metadata, remove: true, assertSession: () => {},
      readViewer: async () => ({ subscriptions: [], recommendations: [
        { uri: "first", value: { document: metadata.documentUri } },
        { uri: "second", value: { document: metadata.documentUri } },
        { uri: "other", value: { document: "other" } },
      ] }),
      subscribe: async () => { calls.push("subscribe"); }, unsubscribe: async () => { calls.push("unsubscribe"); },
      recommend: async () => { calls.push("create"); }, unrecommend: async uri => { calls.push(uri); },
    });
    expect(calls).toEqual(["first", "second"]);
  });
  it("does not write after an account change during the viewer read", async () => {
    const { performStandardSiteArticleAction } = await import("@/lib/standardSiteEmbedActions");
    let active = true;
    let writes = 0;
    const write = async () => { writes += 1; };
    await expect(performStandardSiteArticleAction({
      kind: "subscription", metadata, remove: false,
      assertSession: () => { if (!active) throw new Error("Account changed"); },
      readViewer: async () => { active = false; return { subscriptions: [], recommendations: [] }; },
      subscribe: write, unsubscribe: write, recommend: write, unrecommend: write,
    })).rejects.toThrow("Account changed");
    expect(writes).toBe(0);
  });
});

it("preserves Subscribe intent when another surface already subscribed", async () => {
  const { performStandardSiteArticleAction } = await import("@/lib/standardSiteEmbedActions");
  let writes = 0;
  const write = async () => { writes += 1; };
  await performStandardSiteArticleAction({
    kind: "subscription", metadata, remove: false, assertSession: () => {},
    readViewer: async () => ({ subscriptions: [{ uri: "existing", value: { publication: metadata.publicationUri } }], recommendations: [] }),
    subscribe: write, unsubscribe: write, recommend: write, unrecommend: write,
  });
  expect(writes).toBe(0);
});
