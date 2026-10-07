import { decodeHtmlEntities } from "@/lib/decodeHtmlEntities";

export function podcastNotesExcerpt(description: string): string {
  const text = description.replace(/<(script|style)\b[^>]*>[\s\S]*?<\/\1>/gi, "")
    .replace(/<[^>]*>/g, " ");
  try { return decodeHtmlEntities(text).replace(/\s+/g, " ").trim(); }
  catch { return text.replace(/\s+/g, " ").trim(); }
}

export function parsePodcastTimecode(text: string, duration?: number): number | null {
  const match = /^(?:(\d{1,3}):)?(\d{1,4}):(\d{2})$/.exec(text.trim());
  if (!match) return null;
  const hours = match[1] === undefined ? 0 : Number(match[1]);
  const minutes = Number(match[2]);
  const seconds = Number(match[3]);
  if (seconds >= 60 || (match[1] !== undefined && minutes >= 60)) return null;
  const total = hours * 3600 + minutes * 60 + seconds;
  return duration !== undefined && Number.isFinite(duration) && duration > 0 && total > duration ? null : total;
}

function anchorTimecode(anchor: HTMLAnchorElement, duration?: number): number | null {
  const labelTime = parsePodcastTimecode(anchor.textContent ?? "", duration);
  if (labelTime === null) return null;
  const href = anchor.getAttribute("href") ?? "";
  if (href.startsWith("#") && parsePodcastTimecode(href.slice(1), duration) === labelTime) return labelTime;
  try {
    const url = new URL(href, "https://podcast.invalid/");
    if (url.protocol !== "https:" && url.protocol !== "http:") return null;
    const fragment = url.hash.slice(1).replace(/^t=/, "");
    const candidate = url.searchParams.get("t") ?? url.searchParams.get("start") ?? url.searchParams.get("time") ?? fragment;
    const time = /^\d+(?:s)?$/.test(candidate) ? Number(candidate.replace(/s$/, "")) : parsePodcastTimecode(candidate, duration);
    return time === labelTime ? labelTime : null;
  } catch { return null; }
}

/** Transforms already-sanitized notes. Only text nodes and recognized time links are replaced. */
export function linkPodcastTimecodes(safeHTML: string, duration?: number): string {
  if (typeof document === "undefined") return safeHTML;
  const container = document.createElement("div");
  container.innerHTML = safeHTML;
  const makeButton = (label: string, time: number) => {
    const button = document.createElement("button");
    button.type = "button";
    button.textContent = label;
    button.dataset.podcastTimecode = String(time);
    button.setAttribute("aria-label", `Seek to ${label}`);
    button.className = "rounded px-0.5 font-medium underline underline-offset-4 hover:bg-accent focus-visible:outline-2 focus-visible:outline-ring";
    return button;
  };
  container.querySelectorAll("a").forEach(anchor => {
    const time = anchorTimecode(anchor, duration);
    if (time !== null) anchor.replaceWith(makeButton(anchor.textContent ?? "", time));
  });
  const walker = document.createTreeWalker(container, 4);
  const nodes: Text[] = [];
  while (walker.nextNode()) {
    const node = walker.currentNode as Text;
    if (!node.parentElement?.closest("a, button, script, style, code, pre")) nodes.push(node);
  }
  for (const node of nodes) {
    const fragment = document.createDocumentFragment();
    let offset = 0;
    const pattern = /(?<![\w:./-])(?:\d{1,3}:)?\d{1,4}:\d{2}(?![\w:./-])/g;
    for (const match of node.data.matchAll(pattern)) {
      const time = parsePodcastTimecode(match[0], duration);
      if (time === null) continue;
      fragment.append(document.createTextNode(node.data.slice(offset, match.index)), makeButton(match[0], time));
      offset = match.index + match[0].length;
    }
    if (offset) { fragment.append(document.createTextNode(node.data.slice(offset))); node.replaceWith(fragment); }
  }
  return container.innerHTML;
}
