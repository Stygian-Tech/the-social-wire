const NAMED_HTML_ENTITIES: Record<string, string> = {
  amp: "&",
  lt: "<",
  gt: ">",
  quot: '"',
  apos: "'",
  nbsp: "\u00A0",
  ndash: "–",
  mdash: "—",
  hellip: "…",
  lsquo: "\u2018",
  rsquo: "\u2019",
  ldquo: "\u201C",
  rdquo: "\u201D",
};

/** Decodes HTML entities and strips markup from plain-text titles and summaries. */
export function decodeHtmlEntities(text: string): string {
  const trimmed = text.trim();
  if (!trimmed) return trimmed;

  const withoutTags = trimmed.includes("<")
    ? trimmed.replace(/<[^>]+>/g, "")
    : trimmed;
  if (!withoutTags.includes("&")) return withoutTags;

  return withoutTags
    .replace(/&#(\d+);/g, (_, code: string) =>
      String.fromCodePoint(Number(code))
    )
    .replace(/&#x([0-9a-fA-F]+);/g, (_, hex: string) =>
      String.fromCodePoint(parseInt(hex, 16))
    )
    .replace(/&([a-z]+);/gi, (match, name: string) => {
      const decoded = NAMED_HTML_ENTITIES[name.toLowerCase()];
      return decoded ?? match;
    });
}
