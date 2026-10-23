import { buildArticleNativeContent, buildDocumentRecord, prepareContentOffload } from "@stygian/anypub-kit";
import { markdownCodeText, markdownHeadingText, parseMarkdownBlocks } from "@stygian/markdown-editor/model";
import type { ArticlePublishInput, ArticleRecord } from "./articlePublishingTypes";

export type ScheduledArticleDocument = ArticleRecord & { $type: "site.standard.document"; title: string; site: string; publishedAt: string };
export type PreparedScheduledArticle = { record: ScheduledArticleDocument; publishRkey: string; title: string; url: string };

/** Prepare private editor content without uploading assets or creating public PDS records. */
export async function prepareScheduledArticle(input: ArticlePublishInput, scheduledAt: string, signal?: AbortSignal): Promise<PreparedScheduledArticle> {
  signal?.throwIfAborted();
  if (input.existing) throw new Error("Only New Articles Can Be Scheduled.");
  if (["offprint", "pckt"].includes(input.publication.host)) throw new Error("Scheduling for This Publication Requires Native Wrapper Support.");
  if (input.cover || input.bodyAssets?.length || /article-asset:|blob:|data:/i.test(input.markdown)) throw new Error("Scheduled Articles Cannot Include Uploaded Images Yet.");
  const blocks = parseMarkdownBlocks(input.markdown);
  if (blocks.some(block => block.kind === "image")) throw new Error("Scheduled Articles Cannot Include Images Yet.");
  if (!input.title.trim() || !input.markdown.trim()) throw new Error("An Article Needs a Title and Content.");
  if (new TextEncoder().encode(input.markdown).length > 1_000_000) throw new Error("Article Markdown Exceeds 1 MB.");
  const publishRkey = input.recordKey;
  if (!publishRkey || !/^[234567abcdefghij][234567abcdefghijklmnopqrstuvwxyz]{12}$/.test(publishRkey)) throw new Error("A Scheduled Article Needs a Stable Document Key.");
  if (!/^at:\/\/did:[^/]+\/site\.standard\.publication\/[a-zA-Z0-9._~:-]+$/.test(input.publication.uri)) throw new Error("Choose a Valid Standard.site Publication.");
  const timestamp = new Date(scheduledAt);
  if (!Number.isFinite(timestamp.getTime()) || timestamp.getTime() <= Date.now()) throw new Error("Choose a Future Publication Time.");
  const base = new URL(input.publication.url);
  if (base.protocol !== "https:" || base.username || base.password || base.search || base.hash) throw new Error("The Publication Must Have a Valid HTTPS URL.");
  const rawPath = input.path.trim() || input.title.normalize("NFKD").replace(/[\u0300-\u036f]/g, "").toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "") || "untitled-article";
  if (/[?#\\\u0000-\u0020]/.test(rawPath) || rawPath.split("/").some(part => part === "." || part === "..")) throw new Error("Choose a Relative Article Path Without Query Parameters or Traversal.");
  const path = `/${rawPath.replace(/^\/+/, "")}`;
  const native = await buildArticleNativeContent({
    host: input.publication.host, markdown: input.markdown, assets: [], description: input.description,
    blocks: blocks.map(block => ({ ...block, source: block.kind === "heading" ? markdownHeadingText(block.source) : block.kind === "code" ? markdownCodeText(block.source) : block.source })),
  }, { signal });
  const prepared = await prepareContentOffload(input.publication.host, native.content, { signal });
  if (prepared.offload) throw new Error("This Article Is Too Large to Schedule Without Deferred Asset Uploads.");
  const record = await buildDocumentRecord({
    site: input.publication.uri, title: input.title.trim(), publishedAt: timestamp.toISOString(), updatedAt: timestamp.toISOString(),
    path, content: prepared.content, textContent: native.textContent,
    description: input.description?.trim() || undefined,
    tags: input.tags.length ? [...new Set(input.tags.map(tag => tag.trim()).filter(Boolean))] : undefined,
  }, undefined, { signal });
  if (record.$type !== "site.standard.document" || record.title !== input.title.trim() || record.site !== input.publication.uri || record.publishedAt !== timestamp.toISOString() || record.path !== path) throw new Error("The Publishing Service Returned an Unexpected Article.");
  // Fail closed if a service response unexpectedly introduces retained asset dependencies.
  const serialized = JSON.stringify(record);
  if (/"\$type"\s*:\s*"blob"|article-asset:|"(?:blob|blobPages|textBlob)"\s*:/i.test(serialized)) throw new Error("Scheduled Articles Cannot Include Uploaded Assets Yet.");
  signal?.throwIfAborted();
  return { record: record as ScheduledArticleDocument, publishRkey, title: input.title.trim(), url: `${base.href.replace(/\/$/, "")}${path}` };
}
