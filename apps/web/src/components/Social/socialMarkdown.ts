export type MarkdownRange = { start: number; end: number };
export type SocialMarkdownInline = MarkdownRange & (
  | { kind: "text" | "code"; text: string }
  | { kind: "strong" | "emphasis"; children: SocialMarkdownInline[] }
  | { kind: "link"; href: string; children: SocialMarkdownInline[] }
);
export type SocialMarkdownBlock = MarkdownRange & (
  | { kind: "paragraph" | "quote"; text: string; contentStart: number }
  | { kind: "heading"; text: string; contentStart: number; level: number }
  | { kind: "code"; text: string }
  | { kind: "list"; ordered: boolean; items: { text: string; start: number }[] }
);

function emphasisEnd(text: string, marker: string, start: number): number {
  let index = text.indexOf(marker, start);
  while (index >= 0) {
    const run = new RegExp(`^\\${marker[0]}+`).exec(text.slice(index))![0].length;
    if (text[index - 1] !== "\\") {
      if (run === marker.length) return index;
      // A closing *** can close nested strong and emphasis in either order.
      if (run === 3 && marker.length < 3) return index + 3 - marker.length;
    }
    index = text.indexOf(marker, index + run);
  }
  return -1;
}

/** A deliberately small Markdown subset. Offsets always refer to the original
 * UTF-16 source; no text rewriting can shift AT Protocol facet positions. */
export function socialMarkdownInline(text: string, offset = 0, protectedRanges: MarkdownRange[] = [], depth = 0): SocialMarkdownInline[] {
  const nodes: SocialMarkdownInline[] = [];
  let index = 0;
  const addText = (start: number, end: number, value = text.slice(start, end)) => {
    const previous = nodes.at(-1);
    if (previous?.kind === "text" && previous.end === offset + start && previous.text.length === previous.end - previous.start && value.length === end - start) {
      previous.text += value;
      previous.end = offset + end;
    } else nodes.push({ kind: "text", text: value, start: offset + start, end: offset + end });
  };
  while (index < text.length) {
    const start = index;
    // Code wins over facets: URLs and mentions in examples must remain literal.
    if (text[index] === "`") {
      const marker = /^`+/.exec(text.slice(index))![0];
      const end = text.indexOf(marker, index + marker.length);
      if (end >= 0) {
        nodes.push({ kind: "code", text: text.slice(index + marker.length, end), start: offset + start, end: offset + end + marker.length });
        index = end + marker.length;
        continue;
      }
    }
    const protectedRange = protectedRanges.find(range => range.start <= offset + index && range.end > offset + index);
    if (protectedRange) {
      index = Math.min(text.length, protectedRange.end - offset);
      addText(start, index);
      continue;
    }
    if (text[index] === "\\" && /[\\`*_\[\]()]/.test(text[index + 1] ?? "")) {
      addText(index, index + 2, text[index + 1]);
      index += 2;
      continue;
    }
    if (depth < 8 && text[index] === "[" && text[index - 1] !== "!") {
      const labelEnd = text.indexOf("](", index + 1);
      if (labelEnd >= 0) {
        let end = labelEnd + 2;
        let balance = 1;
        while (end < text.length && balance > 0) {
          if (text[end] === "(") balance++;
          if (text[end] === ")") balance--;
          if (balance > 0) end++;
        }
        if (balance === 0) {
          nodes.push({ kind: "link", href: text.slice(labelEnd + 2, end).trim(), children: socialMarkdownInline(text.slice(index + 1, labelEnd), offset + index + 1, [], depth + 1), start: offset + start, end: offset + end + 1 });
          index = end + 1;
          continue;
        }
      }
    }
    if (depth < 8 && (text[index] === "*" || text[index] === "_")) {
      const marker = text.slice(index, index + Math.min(3, new RegExp(`^\\${text[index]}+`).exec(text.slice(index))![0].length));
      const contentStart = index + marker.length;
      const end = emphasisEnd(text, marker, contentStart);
      const insideWord = text[index] === "_" && /[\p{L}\p{N}]/u.test(text[index - 1] ?? "");
      if (!insideWord && end > contentStart && !/\s/.test(text[contentStart]) && !/\s/.test(text[end - 1])) {
        const children = socialMarkdownInline(text.slice(contentStart, end), offset + contentStart, protectedRanges, depth + 1);
        nodes.push({ kind: marker.length >= 2 ? "strong" : "emphasis", children: marker.length === 3 ? [{ kind: "emphasis", children, start: offset + contentStart, end: offset + end }] : children, start: offset + start, end: offset + end + marker.length });
        index = end + marker.length;
        continue;
      }
    }
    addText(index, index + 1);
    index++;
  }
  return nodes;
}

export function socialMarkdownBlocks(text: string): SocialMarkdownBlock[] {
  const lines = Array.from(text.matchAll(/[^\n]*(?:\n|$)/g)).filter(match => match[0]);
  const blocks: SocialMarkdownBlock[] = [];
  const lineText = (index: number) => lines[index][0].replace(/\r?\n$/, "");
  const listItem = (line: string) => /^(?:([-+*])|(\d+)\.)[ \t]+(.+)$/.exec(line);
  const special = (line: string) => /^(?:#{1,6}[ \t]+|>[ \t]?|`{3,}|~{3,})/.test(line) || !!listItem(line);
  for (let index = 0; index < lines.length;) {
    const start = lines[index].index!;
    const line = lineText(index);
    if (!line.trim()) { index++; continue; }
    const fence = /^(`{3,}|~{3,})[^`~]*$/.exec(line);
    if (fence) {
      const contentStart = start + lines[index][0].length;
      index++;
      while (index < lines.length && !(lineText(index).trim().startsWith(fence[1]) && new RegExp(`^${fence[1][0]}{${fence[1].length},}\\s*$`).test(lineText(index).trim()))) index++;
      const contentEnd = index < lines.length ? lines[index].index! : text.length;
      const end = index < lines.length ? lines[index].index! + lines[index++][0].length : text.length;
      blocks.push({ kind: "code", text: text.slice(contentStart, contentEnd).replace(/\r?\n$/, ""), start, end });
      continue;
    }
    const heading = /^(#{1,6})[ \t]+(.+)$/.exec(line);
    if (heading) {
      blocks.push({ kind: "heading", level: heading[1].length, text: heading[2], contentStart: start + line.indexOf(heading[2], heading[1].length), start, end: start + line.length });
      index++;
      continue;
    }
    const item = listItem(line);
    if (item) {
      const ordered = !!item[2];
      const items: { text: string; start: number }[] = [];
      while (index < lines.length) {
        const match = listItem(lineText(index));
        if (!match || !!match[2] !== ordered) break;
        items.push({ text: match[3], start: lines[index].index! + lineText(index).length - match[3].length });
        index++;
      }
      blocks.push({ kind: "list", ordered, items, start, end: items.at(-1)!.start + items.at(-1)!.text.length });
      continue;
    }
    const quote = /^>[ \t]?(.*)$/.exec(line);
    if (quote) {
      blocks.push({ kind: "quote", text: quote[1], contentStart: start + line.length - quote[1].length, start, end: start + line.length });
      index++;
      continue;
    }
    index++;
    while (index < lines.length && lineText(index).trim() && !special(lineText(index))) index++;
    const end = index < lines.length ? lines[index].index! : text.length;
    blocks.push({ kind: "paragraph", text: text.slice(start, end).replace(/\r?\n$/, ""), contentStart: start, start, end });
  }
  return blocks;
}
