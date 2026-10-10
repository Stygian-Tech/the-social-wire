import { parseMarkdownBlocks, type MarkdownBlock } from "@stygian/markdown-editor/model";
import type { ArticleHost, ArticleImageAsset, ArticleRecord } from "./articlePublishingTypes";

const bytes = (text: string) => new TextEncoder().encode(text).length;
const safeUrl = (value: string) => /^https?:\/\//i.test(value) && !/[\u0000-\u0020]/.test(value);

/** Native rich-text indices count UTF-8 bytes in the resulting plaintext. */
export function articleRichText(source: string, ns: string): ArticleRecord {
  let plaintext = "";
  const facets: ArticleRecord[] = [];
  const append = (text: string, depth = 0) => {
    const pattern = /(`+)([\s\S]*?)\1|\[([^\]]+)\]\(([^\s]+)\)|(\*\*|__|~~|\+\+|\*|_)([^\n]+?)\5/g;
    let start = 0;
    for (const match of text.matchAll(pattern)) {
      plaintext += text.slice(start, match.index).replace(/\\([\\`*_\[\]])/g, "$1");
      const byteStart = bytes(plaintext);
      const kind = match[1] ? "code" : match[3] ? "link" : match[5] === "~~" ? "strikethrough" : match[5] === "++" ? "underline" : match[5].length === 2 ? "bold" : "italic";
      const inner = match[2] ?? match[3] ?? match[6];
      if (kind === "code" || depth >= 8) plaintext += inner;
      else append(inner, depth + 1);
      const byteEnd = bytes(plaintext);
      if (byteEnd > byteStart && (kind !== "link" || safeUrl(match[4]))) {
        facets.push({ index: { byteStart, byteEnd }, features: [{ $type: `${ns}#${kind}`, ...(kind === "link" ? { uri: match[4] } : {}) }] });
      }
      start = match.index! + match[0].length;
    }
    plaintext += text.slice(start).replace(/\\([\\`*_\[\]])/g, "$1");
  };
  append(source);
  return { plaintext, ...(facets.length ? { facets } : {}) };
}

export function buildArticleNativeContent(host: ArticleHost, markdown: string, assets: ArticleImageAsset[], description = ""): { content: ArticleRecord; textContent: string } {
  const lookup = new Map(assets.map(asset => [`article-asset://${asset.id}`, asset]));
  const resolve = (url: string) => {
    const asset = lookup.get(url);
    if (url.startsWith("article-asset://") && !asset) throw new Error("An article image has not been uploaded.");
    if (!asset && !safeUrl(url)) throw new Error("Article media must use an uploaded image or an HTTP(S) URL.");
    return asset;
  };
  const blocks = parseMarkdownBlocks(markdown);
  const plainBlock = (b: MarkdownBlock): string => {
    if (b.kind === "image") return b.alt;
    if (b.kind === "embed") return b.url;
    if (b.kind === "thematic-break" || b.kind === "empty") return "";
    if (b.kind === "code") return b.source.replace(/^\s*`{3,}[^\n]*\n?/, "").replace(/\n?\s*`{3,}\s*$/, "");
    const source = b.kind === "heading" ? b.source.replace(/^\s*#{1,6}\s+/, "") : b.kind === "quote" ? b.source.split("\n").map(line => line.replace(/^\s*>\s?/, "")).join("\n") : b.kind === "unordered-list" || b.kind === "ordered-list" ? b.source.replace(/^\s*(?:[-*+]|\d+\.)\s*(?:\[[ xX]\]\s*)?/, "") : b.source;
    return String(articleRichText(source, "at.markpub.richtext.facet").plaintext);
  };
  const textContent = blocks.map(plainBlock).filter(Boolean).join("\n\n");
  if (host === "markpub" || host === "unknown") {
    const text = markdown.replace(/article-asset:\/\/[^\s)]+/g, url => resolve(url)!.url).replace(/@\[embed\]\((https?:\/\/[^\s)]+)\)/g, "[$1]($1)");
    return { content: { $type: "at.markpub.markdown", flavor: "gfm", text: { $type: "at.markpub.text", markdown: text } }, textContent };
  }
  const ns = host === "leaflet" ? "pub.leaflet" : host === "offprint" ? "app.offprint" : "blog.pckt";
  const blockNs = host === "leaflet" ? `${ns}.blocks` : `${ns}.block`;
  const rich = (text: string) => articleRichText(text, `${ns}.richtext.facet`);
  const text = (source: string) => ({ $type: `${blockNs}.text`, ...rich(source) });
  const convert = (b: MarkdownBlock): ArticleRecord => {
    switch (b.kind) {
      case "heading": return { $type: `${blockNs}.${host === "leaflet" ? "header" : "heading"}`, level: host === "offprint" ? Math.min(3, b.headingLevel) : b.headingLevel, ...rich(b.source.replace(/^\s*#{1,6}\s+/, "")) };
      case "quote": {
        const lines = b.source.split("\n").map(line => line.replace(/^\s*>\s?/, ""));
        return host === "leaflet" ? { $type: `${blockNs}.blockquote`, ...rich(lines.join("\n")) } : { $type: `${blockNs}.blockquote`, content: lines.map(text) };
      }
      case "code": {
        const value = b.source.replace(/^\s*`{3,}[^\n]*\n?/, "").replace(/\n?\s*`{3,}\s*$/, "");
        let language = b.language?.trim().toLowerCase();
        while (language && bytes(language) > 50) language = language.slice(0, -1);
        return { $type: `${blockNs}.${host === "leaflet" ? "code" : "codeBlock"}`, [host === "offprint" ? "code" : "plaintext"]: value, ...(language ? { language } : {}) };
      }
      case "image": {
        const asset = resolve(b.url);
        // These native lexicons require blobs, rather than remote-image strings.
        if (!asset) throw new Error("Upload remote images before publishing native article content.");
        const aspectRatio = { width: asset.width, height: asset.height };
        if (host === "pckt") return { $type: `${blockNs}.image`, attrs: { src: `blob:${asset.blob.ref.$link}`, blob: asset.blob, alt: b.alt || asset.alt, align: "center", aspectRatio } };
        return { $type: `${blockNs}.image`, image: asset.blob, alt: b.alt || asset.alt, aspectRatio, ...(host === "offprint" ? { width: "100%", alignment: "center" } : {}) };
      }
      case "embed":
        resolve(b.url);
        return { $type: `${blockNs}.${host === "offprint" ? "webEmbed" : "website"}`, [host === "offprint" ? "href" : "src"]: b.url, title: b.url, ...(host === "offprint" ? { width: "100%", alignment: "center" } : {}) };
      case "thematic-break": return { $type: `${blockNs}.horizontalRule` };
      default: return text(b.source);
    }
  };
  const items: ArticleRecord[] = [];
  // The editor emits one list block per item. Group adjacent items and retain nesting.
  const listStack: { level: number; list: ArticleRecord; children: ArticleRecord[]; last?: ArticleRecord; ordered: boolean }[] = [];
  for (const b of blocks) {
    if (b.kind !== "unordered-list" && b.kind !== "ordered-list") { listStack.length = 0; items.push(convert(b)); continue; }
    const ordered = b.kind === "ordered-list";
    const source = b.source.replace(/^\s*(?:[-*+]|\d+\.)\s*/, "");
    const task = /^\[([ xX])\]\s*(.*)$/s.exec(source);
    const taskMode = !!task && host !== "leaflet";
    const level = b.listLevel;
    while (listStack.length && listStack.at(-1)!.level > level) listStack.pop();
    let group = listStack.at(-1);
    const type = taskMode ? "taskList" : ordered ? "orderedList" : host === "leaflet" ? "unorderedList" : "bulletList";
    if (!group || group.level !== level || group.ordered !== ordered || group.list.$type !== `${blockNs}.${type}`) {
      const children: ArticleRecord[] = [];
      const list: ArticleRecord = { $type: `${blockNs}.${type}`, [host === "pckt" ? "content" : "children"]: children, ...(ordered && b.listStart !== 1 ? { [host === "leaflet" ? "startIndex" : "start"]: b.listStart } : {}) };
      if (group?.last && level > group.level) {
        if (host === "pckt") (group.last.content as ArticleRecord[]).push(list);
        else if (host === "leaflet" && group.ordered !== ordered) group.last[ordered ? "orderedListChildren" : "unorderedListChildren"] = list;
        else group.last.children = children;
      } else items.push(list);
      group = { level, list, children, ordered };
      listStack.push(group);
    }
    const itemText = text(task ? task[2] : source);
    const item: ArticleRecord = host === "pckt" ? { $type: `${blockNs}.${taskMode ? "taskItem" : "listItem"}`, content: [itemText] } : { content: itemText };
    if (task) item.checked = task[1].toLowerCase() === "x";
    group.children.push(item); group.last = item;
  }
  if (host === "leaflet") return { content: { $type: "pub.leaflet.content", pages: [{ $type: "pub.leaflet.pages.linearDocument", blocks: items.map(block => ({ $type: "pub.leaflet.pages.linearDocument#block", block })) }] }, textContent };
  if (host === "pckt") {
    if (description.trim() && description.trim() !== items[0]?.plaintext) items.unshift({ $type: `${blockNs}.heading`, level: 3, ...rich(description.trim()) });
    if (items.at(-1)?.$type !== `${blockNs}.text`) items.push(text(""));
  }
  return { content: { $type: `${ns}.content`, items }, textContent };
}
