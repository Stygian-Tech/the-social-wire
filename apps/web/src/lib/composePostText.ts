import { AppBskyRichtextFacet, RichText, type Agent } from "@atproto/api";
import { socialMarkdownBlocks, socialMarkdownInline, type SocialMarkdownInline } from "@/components/Social/socialMarkdown";

type ByteRange = { byteStart: number; byteEnd: number };

/** Keep draft Markdown separate from the native text and UTF-8 facets we publish. */
export function compilePostText(source: string) {
  let text = "";
  const links: AppBskyRichtextFacet.Main[] = [];
  const protectedRanges: ByteRange[] = [];
  const byteLength = () => new TextEncoder().encode(text).length;
  const inline = (nodes: SocialMarkdownInline[], insideLink = false) => {
    for (const node of nodes) {
      const byteStart = byteLength();
      if (node.kind === "text" || node.kind === "code") text += node.text;
      else if ("children" in node) inline(node.children, insideLink || node.kind === "link");
      const index = { byteStart, byteEnd: byteLength() };
      if (node.kind === "code" || node.kind === "link") protectedRanges.push(index);
      if (node.kind === "link" && !insideLink && index.byteEnd > byteStart) {
        try {
          const destination = /^[\p{L}\p{N}](?:[\p{L}\p{N}.-]*\.)[\p{L}]{2,}(?::\d+)?(?:[/?#]|$)/u.test(node.href) ? `https://${node.href}` : node.href;
          const url = new URL(destination);
          if (["http:", "https:"].includes(url.protocol) && !url.username && !url.password) {
            links.push({ index, features: [{ $type: "app.bsky.richtext.facet#link", uri: url.href }] });
          }
        } catch { /* An unsafe or unfinished destination remains plain label text. */ }
      }
    }
  };
  const parseInline = (value: string) => {
    const rich = new RichText({ text: value });
    rich.detectFacetsWithoutResolution();
    let offset = 0;
    const ranges: { start: number; end: number }[] = [];
    for (const segment of rich.segments()) {
      if (segment.facet) ranges.push({ start: offset, end: offset + segment.text.length });
      offset += segment.text.length;
    }
    return socialMarkdownInline(value, 0, ranges);
  };
  let cursor = 0;
  for (const block of socialMarkdownBlocks(source)) {
    text += source.slice(cursor, block.start);
    if (block.kind === "code") {
      const byteStart = byteLength();
      text += block.text;
      protectedRanges.push({ byteStart, byteEnd: byteLength() });
      // The block parser includes the closing fence's newline in its range.
      if (source.slice(block.start, block.end).endsWith("\n")) text += "\n";
    } else if (block.kind === "list") {
      let itemCursor = block.start;
      for (const item of block.items) {
        text += source.slice(itemCursor, item.start);
        inline(parseInline(item.text));
        itemCursor = item.start + item.text.length;
      }
      text += source.slice(itemCursor, block.end);
    } else {
      if (block.kind === "quote") text += source.slice(block.start, block.contentStart);
      inline(parseInline(block.text));
      text += source.slice(block.contentStart + block.text.length, block.end);
    }
    cursor = block.end;
  }
  text += source.slice(cursor);
  const mergeFacets = (detected: AppBskyRichtextFacet.Main[] = []) => [
    ...links,
    ...detected.filter(facet => !protectedRanges.some(range => facet.index.byteStart < range.byteEnd && facet.index.byteEnd > range.byteStart))
      .map(facet => ({ ...facet, features: facet.features.filter(feature => !AppBskyRichtextFacet.isMention(feature) || feature.did.startsWith("did:")) }))
      .filter(facet => facet.features.length),
  ].sort((a, b) => a.index.byteStart - b.index.byteStart);
  // Mask protected bytes before detection to keep code and explicit labels
  // from triggering handle resolution or competing facets. Offsets stay stable.
  const detectionBytes = new TextEncoder().encode(text);
  for (const range of protectedRanges) detectionBytes.fill(32, range.byteStart, range.byteEnd);
  const detectionText = new TextDecoder().decode(detectionBytes);
  const rich = new RichText({ text: detectionText });
  rich.detectFacetsWithoutResolution();
  return { text, detectionText, facets: mergeFacets(rich.facets), mergeFacets };
}

export async function resolvePostText(source: string, agent: Agent) {
  const compiled = compilePostText(source);
  const rich = new RichText({ text: compiled.detectionText });
  await rich.detectFacets(agent);
  return { text: compiled.text, facets: compiled.mergeFacets(rich.facets) };
}
