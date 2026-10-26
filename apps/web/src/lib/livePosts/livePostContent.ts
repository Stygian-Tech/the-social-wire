import type { ArticleHost, ArticleRecord } from "@/lib/articles/articlePublishingTypes";
import type { PreparedLivePostMedia } from "./livePostMedia";

/** Append native nodes without round-tripping or replacing existing provider content. */
export function appendLiveArticleContent(host: ArticleHost, previous: ArticleRecord | undefined, timestamp: string, text: string, media?: PreparedLivePostMedia, authorDid?: string): ArticleRecord {
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
  if (media) {
    const urlFor = (cid: string) => {
      if (!authorDid) throw new Error("The article author is required to reference uploaded media.");
      if (!media.pdsUrl || !media.pdsUrl.startsWith("https://")) throw new Error("The article media requires its original PDS endpoint.");
      return `${media.pdsUrl}/xrpc/com.atproto.sync.getBlob?${new URLSearchParams({ did: authorDid, cid })}`;
    };
    const escape = (value: string) => value.replace(/[\\`*_{}[\]()#+!<>|~&=.-]/g, "\\$&");
    if (host === "markpub" || host === "unknown") {
      const blocks: string[] = [];
      for (const image of media.images ?? []) blocks.push(`![${escape(image.alt)}](${urlFor(image.blob.ref.$link)})`);
      if (media.video) blocks.push(`[${escape(media.video.alt || "Video")}](${urlFor(media.video.blob.ref.$link)})`);
      if (media.gif) blocks.push(`![${escape(media.gif.alt)}](${media.gif.url.replace(/\)/g, "%29")})`);
      if (media.external) blocks.push(`[${escape(media.external.external.title || media.external.external.uri)}](${media.external.external.uri.replace(/\)/g, "%29")})`);
      const body = addition.text as ArticleRecord;
      if (blocks.length) body.markdown = `${body.markdown}\n\n${blocks.join("\n\n")}`;
    } else {
      const namespace = host === "leaflet" ? "pub.leaflet.blocks" : host === "offprint" ? "app.offprint.block" : "blog.pckt.block";
      const blocks: ArticleRecord[] = (media.images ?? []).map(image => {
        const aspectRatio = image.aspectRatio ?? { width: 1, height: 1 };
        return host === "pckt"
          ? { $type: `${namespace}.image`, attrs: { src: `blob:${image.blob.ref.$link}`, blob: image.blob, alt: image.alt, align: "center", aspectRatio } }
          : { $type: `${namespace}.image`, image: image.blob, alt: image.alt, aspectRatio, ...(host === "offprint" ? { width: "100%", alignment: "center" } : {}) };
      });
      const embed = (url: string, title: string): ArticleRecord => ({ $type: `${namespace}.${host === "offprint" ? "webEmbed" : "website"}`, [host === "offprint" ? "href" : "src"]: url, title, ...(host === "offprint" ? { width: "100%", alignment: "center" } : {}) });
      // Preserve remote GIFs and processed videos with native website blocks.
      if (media.video) blocks.push(embed(urlFor(media.video.blob.ref.$link), media.video.alt || "Video"));
      if (media.gif) blocks.push(embed(media.gif.url, media.gif.alt || "GIF"));
      if (media.external) blocks.push(embed(media.external.external.uri, media.external.external.title));
      if (host === "leaflet") ((addition.pages as ArticleRecord[])[0].blocks as ArticleRecord[]).push(...blocks.map(block => ({ $type: "pub.leaflet.pages.linearDocument#block", block })));
      else (addition.items as ArticleRecord[]).push(...blocks);
    }
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
