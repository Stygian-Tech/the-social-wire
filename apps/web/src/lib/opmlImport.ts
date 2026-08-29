import {
  normalizeRssFeedUrlInput,
  validateRssFeedFetchUrl,
} from "@/lib/rssFeedCore";

export const MAX_OPML_FILE_BYTES = 2 * 1024 * 1024;
export const MAX_OPML_FEEDS = 5_000;
export const MAX_OPML_OUTLINES = 10_000;
const MAX_FEED_URL_LENGTH = 2_048;
const MAX_FEED_TITLE_LENGTH = 512;
const MAX_CATEGORY_LABEL_LENGTH = 128;

export interface ParsedOpmlFeed {
  feedUrl: string;
  title: string;
  htmlUrl?: string;
  categoryPath: string[];
  sourceIndex: number;
}

export interface OpmlImportCandidate extends ParsedOpmlFeed {
  status: "available" | "already-subscribed";
}

export interface OpmlImportReview {
  candidates: OpmlImportCandidate[];
  duplicateCount: number;
}

export interface OpmlImportProgress {
  completed: number;
  total: number;
  feed: ParsedOpmlFeed;
  status: "imported" | "already-subscribed" | "failed";
}

export interface OpmlImportFailure {
  feed: ParsedOpmlFeed;
  message: string;
}

export interface OpmlImportBatchResult {
  imported: ParsedOpmlFeed[];
  skippedExisting: ParsedOpmlFeed[];
  failed: OpmlImportFailure[];
}

function attributeValue(element: Element, name: string): string {
  const match = [...element.attributes].find(
    (attribute) => attribute.name.toLowerCase() === name.toLowerCase()
  );
  return match?.value.trim() ?? "";
}

function outlineLabel(element: Element): string {
  return (
    attributeValue(element, "title") || attributeValue(element, "text")
  ).slice(0, MAX_FEED_TITLE_LENGTH);
}

function childElementsNamed(element: Element, localName: string): Element[] {
  return [...element.children].filter(
    (child) => child.localName.toLowerCase() === localName
  );
}

/**
 * Canonical feed identity used by OPML preview and the fresh pre-write dedupe.
 * Query parameters are intentionally preserved because they can select a feed format or account.
 */
export function normalizeOpmlFeedUrl(raw: string): string | null {
  const normalized = normalizeRssFeedUrlInput(raw);
  const validation = validateRssFeedFetchUrl(normalized);
  if (!validation.ok) return null;

  const url = new URL(validation.url.href);
  url.hash = "";
  const canonical = normalizeRssFeedUrlInput(url.href);
  return canonical.length <= MAX_FEED_URL_LENGTH ? canonical : null;
}

function normalizeOptionalSiteUrl(raw: string): string | undefined {
  if (!raw.trim()) return undefined;
  const normalized = normalizeRssFeedUrlInput(raw);
  const validation = validateRssFeedFetchUrl(normalized);
  if (!validation.ok) return undefined;
  const url = new URL(validation.url.href);
  url.hash = "";
  const canonical = normalizeRssFeedUrlInput(url.href);
  return canonical.length <= MAX_FEED_URL_LENGTH ? canonical : undefined;
}

function fallbackFeedTitle(feedUrl: string): string {
  try {
    return new URL(feedUrl).hostname;
  } catch {
    return "RSS Feed";
  }
}

/** Parse valid RSS/Atom outlines from an OPML document in document order. */
export function parseOpmlFeeds(xml: string): ParsedOpmlFeed[] {
  if (/<!DOCTYPE\b/i.test(xml)) {
    throw new Error("OPML files with DOCTYPE declarations are not supported.");
  }
  const Parser = globalThis.DOMParser ?? globalThis.window?.DOMParser;
  if (!Parser) {
    throw new Error("This browser cannot read OPML files.");
  }
  const document = new Parser().parseFromString(xml, "application/xml");
  if (document.querySelector("parsererror")) {
    throw new Error("This file is not valid XML.");
  }

  const root = document.documentElement;
  if (root.localName.toLowerCase() !== "opml") {
    throw new Error("This XML file is not an OPML document.");
  }

  const body = childElementsNamed(root, "body")[0];
  if (!body) {
    throw new Error("This OPML document is missing its body.");
  }

  const feeds: ParsedOpmlFeed[] = [];
  let sourceIndex = 0;
  let outlineCount = 0;
  const stack = childElementsNamed(body, "outline")
    .toReversed()
    .map((outline) => ({ outline, categoryPath: [] as string[] }));

  while (stack.length > 0) {
    const frame = stack.pop();
    if (!frame) break;
    const { outline, categoryPath } = frame;
    outlineCount += 1;
    if (outlineCount > MAX_OPML_OUTLINES) {
      throw new Error(
        `This OPML file contains more than ${MAX_OPML_OUTLINES.toLocaleString()} outlines.`
      );
    }

    const xmlUrl = attributeValue(outline, "xmlUrl");
    const feedUrl = xmlUrl ? normalizeOpmlFeedUrl(xmlUrl) : null;
    const label = outlineLabel(outline);

    if (feedUrl) {
      const htmlUrl = normalizeOptionalSiteUrl(attributeValue(outline, "htmlUrl"));
      feeds.push({
        feedUrl,
        title: label || fallbackFeedTitle(feedUrl),
        ...(htmlUrl ? { htmlUrl } : {}),
        categoryPath,
        sourceIndex,
      });
      sourceIndex += 1;
      if (feeds.length > MAX_OPML_FEEDS) {
        throw new Error(`This OPML file contains more than ${MAX_OPML_FEEDS.toLocaleString()} feeds.`);
      }
    }

    const children = childElementsNamed(outline, "outline");
    const childCategoryPath =
      children.length > 0 && label
        ? [...categoryPath, label.slice(0, MAX_CATEGORY_LABEL_LENGTH)]
        : categoryPath;
    for (let index = children.length - 1; index >= 0; index -= 1) {
      stack.push({ outline: children[index]!, categoryPath: childCategoryPath });
    }
  }

  return feeds;
}

/** Build the visible, file-deduped review list and mark fresh PDS matches. */
export function buildOpmlImportReview(
  parsedFeeds: readonly ParsedOpmlFeed[],
  existingFeedUrls: readonly string[]
): OpmlImportReview {
  const existing = new Set(
    existingFeedUrls
      .map(normalizeOpmlFeedUrl)
      .filter((feedUrl): feedUrl is string => feedUrl !== null)
  );
  const seen = new Set<string>();
  const candidates: OpmlImportCandidate[] = [];
  let duplicateCount = 0;

  for (const feed of parsedFeeds) {
    const feedUrl = normalizeOpmlFeedUrl(feed.feedUrl);
    if (!feedUrl) continue;
    if (seen.has(feedUrl)) {
      duplicateCount += 1;
      continue;
    }
    seen.add(feedUrl);
    candidates.push({
      ...feed,
      feedUrl,
      status: existing.has(feedUrl) ? "already-subscribed" : "available",
    });
  }

  return { candidates, duplicateCount };
}

/**
 * Sequential, partial-failure-safe import. Callers must pass a freshly loaded existing-feed list.
 */
export async function importOpmlFeedBatch(args: {
  feeds: readonly ParsedOpmlFeed[];
  existingFeedUrls: readonly string[];
  createSubscription: (feed: ParsedOpmlFeed) => Promise<void>;
  onProgress?: (progress: OpmlImportProgress) => void;
}): Promise<OpmlImportBatchResult> {
  const existing = new Set(
    args.existingFeedUrls
      .map(normalizeOpmlFeedUrl)
      .filter((feedUrl): feedUrl is string => feedUrl !== null)
  );
  const selected = buildOpmlImportReview(args.feeds, []).candidates.map(
    (candidate): ParsedOpmlFeed => ({
      feedUrl: candidate.feedUrl,
      title: candidate.title,
      ...(candidate.htmlUrl ? { htmlUrl: candidate.htmlUrl } : {}),
      categoryPath: candidate.categoryPath,
      sourceIndex: candidate.sourceIndex,
    })
  );
  const result: OpmlImportBatchResult = {
    imported: [],
    skippedExisting: [],
    failed: [],
  };

  for (const [index, feed] of selected.entries()) {
    if (existing.has(feed.feedUrl)) {
      result.skippedExisting.push(feed);
      args.onProgress?.({
        completed: index + 1,
        total: selected.length,
        feed,
        status: "already-subscribed",
      });
      continue;
    }

    try {
      await args.createSubscription(feed);
      existing.add(feed.feedUrl);
      result.imported.push(feed);
      args.onProgress?.({
        completed: index + 1,
        total: selected.length,
        feed,
        status: "imported",
      });
    } catch (error) {
      result.failed.push({
        feed,
        message: error instanceof Error ? error.message : "Could not import this feed.",
      });
      args.onProgress?.({
        completed: index + 1,
        total: selected.length,
        feed,
        status: "failed",
      });
    }
  }

  return result;
}
