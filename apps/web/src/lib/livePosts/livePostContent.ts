import type { ArticleHost, ArticleRecord } from "@/lib/articles/articlePublishingTypes";

/** Append native nodes without round-tripping or replacing existing provider content. */
export function appendLiveArticleContent(host: ArticleHost, previous: ArticleRecord | undefined, timestamp: string, text: string): ArticleRecord {
  const addition: ArticleRecord = host === "markpub" || host === "unknown"
    ? { $type: "at.markpub.markdown", flavor: "gfm", text: { $type: "at.markpub.text", markdown: `## ${timestamp}\n\n${text.replace(/[\\`*_{}[\]()#+!<>|~&=.-]/g, "\\$&")}` } }
    : { $type: host === "leaflet" ? "pub.leaflet.content" : host === "offprint" ? "app.offprint.content" : "blog.pckt.content" };
  // Updates are literal text, rather than Markdown documents. Keep exactly one
  // timestamp heading and text block even when the user types Markdown syntax.
  if (host === "leaflet") addition.pages = [{ $type: "pub.leaflet.pages.linearDocument", blocks: [
    { $type: "pub.leaflet.pages.linearDocument#block", block: { $type: "pub.leaflet.blocks.header", level: 2, plaintext: timestamp } },
    { $type: "pub.leaflet.pages.linearDocument#block", block: { $type: "pub.leaflet.blocks.text", plaintext: text } },
  ] }];
  else if (host === "offprint" || host === "pckt") {
    const namespace = host === "offprint" ? "app.offprint.block" : "blog.pckt.block";
    addition.items = [{ $type: `${namespace}.heading`, level: 2, plaintext: timestamp }, { $type: `${namespace}.text`, plaintext: text }];
  }
  if (!previous) return addition;
  if (previous.$type !== addition.$type) throw new Error("The article's native format changed. Refresh before adding an update.");
  if (host === "markpub" || host === "unknown") {
    const old = previous.text as ArticleRecord | undefined;
    if (!old || typeof old.markdown !== "string" || old.textBlob) throw new Error("Blob-backed article content cannot be appended safely.");
    return { ...previous, text: { ...old, markdown: `${old.markdown}\n\n${(addition.text as ArticleRecord).markdown}` } };
  }
  if (host === "leaflet") {
    if (previous.blobPages || !Array.isArray(previous.pages)) throw new Error("Blob-backed article pages cannot be appended safely.");
    const pages = [...previous.pages] as ArticleRecord[];
    const last = pages.at(-1);
    if (!last || last.$type !== "pub.leaflet.pages.linearDocument" || !Array.isArray(last.blocks)) throw new Error("This article has no appendable native page.");
    pages[pages.length - 1] = { ...last, blocks: [...last.blocks, ...((addition.pages as ArticleRecord[])[0].blocks as unknown[])] };
    return { ...previous, pages };
  }
  if (previous.blob || !Array.isArray(previous.items)) throw new Error("Blob-backed article content cannot be appended safely.");
  return { ...previous, items: [...previous.items, ...(addition.items as unknown[])] };
}

export function livePostText(text: string, tags: string[]): string {
  return [text.trim(), tags.map(tag => `#${tag.replace(/^#/, "").replace(/\s+/g, "")}`).join(" ")].filter(Boolean).join("\n\n");
}
