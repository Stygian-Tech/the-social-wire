import { RichText, type AppBskyFeedPost } from "@atproto/api";
import { financeTickerSymbols, type FinanceTickerSymbol } from "@/lib/financeTickerSymbols";
import { socialMarkdownBlocks, socialMarkdownInline, type MarkdownRange, type SocialMarkdownInline } from "@/components/Social/socialMarkdown";

/** Cashtags reuse reviewed provider symbols; unsupported tickers stay ordinary text. */
export function socialCashtagSymbols(record: AppBskyFeedPost.Record): FinanceTickerSymbol[] {
  const excluded: MarkdownRange[] = [];
  const facets: MarkdownRange[] = [];
  let offset = 0;
  for (const segment of new RichText({ text: record.text, facets: record.facets }).segments()) {
    if (segment.facet) facets.push({ start: offset, end: offset + segment.text.length });
    offset += segment.text.length;
  }
  const inspect = (nodes: SocialMarkdownInline[]) => {
    for (const node of nodes) {
      if (node.kind === "code") excluded.push(node);
      else if (node.kind === "link") {
        inspect(node.children);
        const textEnd = node.children.at(-1)?.end ?? node.start;
        excluded.push({ start: textEnd, end: node.end });
      } else if (node.kind === "strong" || node.kind === "emphasis") inspect(node.children);
    }
  };
  for (const block of socialMarkdownBlocks(record.text)) {
    if (block.kind === "code") excluded.push(block);
    else if (block.kind === "list") for (const item of block.items) inspect(socialMarkdownInline(item.text, item.start, facets));
    else inspect(socialMarkdownInline(block.text, block.contentStart, facets));
  }
  const reviewed = new Map(financeTickerSymbols().map(symbol => [symbol.proName.split(":")[1], symbol]));
  const seen = new Set<string>();
  const result: FinanceTickerSymbol[] = [];
  for (const match of record.text.matchAll(/(?<![\w/$\\])\$([A-Za-z][A-Za-z0-9]*(?:\.[A-Za-z]+)?)(?!\w)/g)) {
    const start = match.index;
    if (excluded.some(range => range.start <= start && range.end > start)) continue;
    const symbol = reviewed.get(match[1].toUpperCase());
    if (!symbol || seen.has(symbol.proName)) continue;
    seen.add(symbol.proName);
    result.push(symbol);
    if (result.length === 3) break;
  }
  return result;
}
