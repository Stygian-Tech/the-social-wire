import { AppBskyRichtextFacet, RichText, type AppBskyFeedPost } from "@atproto/api";
import type { ReactNode } from "react";
import { socialHttpsUrl, socialProfileUrl } from "./socialUrls";
import { socialMarkdownBlocks, socialMarkdownInline, type MarkdownRange, type SocialMarkdownInline } from "./socialMarkdown";

type FacetRange = MarkdownRange & { href?: string };
const linkClassName = "text-primary underline-offset-4 hover:underline";

export function SocialRichText({ record }: { record: AppBskyFeedPost.Record }) {
  // The SDK converts UTF-8 byte facets before Markdown is interpreted. Keeping
  // source positions lets formatting and emoji coexist with native facet links.
  const facets: FacetRange[] = [];
  let offset = 0;
  for (const segment of new RichText({ text: record.text, facets: record.facets }).segments()) {
    if (segment.facet) {
      const feature = segment.facet.features.find(value => AppBskyRichtextFacet.isLink(value) || AppBskyRichtextFacet.isMention(value) || AppBskyRichtextFacet.isTag(value));
      let href: string | undefined;
      if (AppBskyRichtextFacet.isLink(feature)) href = socialHttpsUrl(feature.uri);
      else if (AppBskyRichtextFacet.isMention(feature) && /^did:[a-z]+:[^\s/]+$/.test(feature.did)) href = socialProfileUrl(feature.did);
      else if (AppBskyRichtextFacet.isTag(feature)) href = `https://bsky.app/search?q=${encodeURIComponent(`#${feature.tag}`)}`;
      facets.push({ start: offset, end: offset + segment.text.length, href });
    }
    offset += segment.text.length;
  }
  const anchor = (href: string, children: ReactNode, key: number) => <a key={key} href={href} target="_blank" rel="noopener noreferrer" className={linkClassName}>{children}</a>;
  const textWithFacets = (node: Extract<SocialMarkdownInline, { kind: "text" | "code" }>): ReactNode => {
    const children: ReactNode[] = [];
    let cursor = node.start;
    for (const facet of facets.filter(range => range.href && range.end > node.start && range.start < node.end)) {
      const start = Math.max(cursor, facet.start);
      const end = Math.min(node.end, facet.end);
      if (start > cursor) children.push(node.text.slice(cursor - node.start, start - node.start));
      if (end > start) children.push(anchor(facet.href!, node.text.slice(start - node.start, end - node.start), start));
      cursor = Math.max(cursor, end);
    }
    if (cursor < node.end) children.push(node.text.slice(cursor - node.start));
    return children;
  };
  const renderInline = (nodes: SocialMarkdownInline[], suppressLinks = false): ReactNode => nodes.map(node => {
    switch (node.kind) {
      case "text": return <span key={node.start}>{suppressLinks ? node.text : textWithFacets(node)}</span>;
      case "code": return <code key={node.start} className="rounded bg-muted px-1 font-mono text-[0.9em]">{node.text}</code>;
      case "strong": return <strong key={node.start}>{renderInline(node.children, suppressLinks)}</strong>;
      case "emphasis": return <em key={node.start}>{renderInline(node.children, suppressLinks)}</em>;
      case "link": {
        const href = socialHttpsUrl(node.href);
        const children = renderInline(node.children, true);
        return href && !suppressLinks ? anchor(href, children, node.start) : <span key={node.start}>{children}</span>;
      }
    }
  });
  const inline = (text: string, start: number) => renderInline(socialMarkdownInline(text, start, facets));

  return <div className="flex flex-col gap-2 break-words text-sm leading-relaxed [overflow-wrap:anywhere]">
    {socialMarkdownBlocks(record.text).map(block => {
      switch (block.kind) {
        case "code": return <pre key={block.start} className="max-w-full overflow-x-auto whitespace-pre rounded-lg bg-muted p-3"><code>{block.text}</code></pre>;
        case "heading": {
          const Heading = `h${block.level}` as "h1" | "h2" | "h3" | "h4" | "h5" | "h6";
          return <Heading key={block.start} className="whitespace-pre-wrap font-semibold">{inline(block.text, block.contentStart)}</Heading>;
        }
        case "quote": return <blockquote key={block.start} className="whitespace-pre-wrap border-l-2 border-border pl-3 text-muted-foreground">{inline(block.text, block.contentStart)}</blockquote>;
        case "list": {
          const List = block.ordered ? "ol" : "ul";
          return <List key={block.start} className={block.ordered ? "list-decimal pl-5" : "list-disc pl-5"}>{block.items.map(item => <li key={item.start} className="whitespace-pre-wrap">{inline(item.text, item.start)}</li>)}</List>;
        }
        case "paragraph": return <p key={block.start} className="whitespace-pre-wrap">{inline(block.text, block.contentStart)}</p>;
      }
    })}
  </div>;
}
