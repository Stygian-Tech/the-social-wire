import type { ArticleHost, ArticleRecord, ArticleImageAsset } from "@stygian/anypub-kit/types";
export type { ArticleHost, ArticleRecord, ArticleBlob, ArticleImageAsset } from "@stygian/anypub-kit/types";
export type ArticlePublication = { uri: string; cid: string; name: string; url: string; host: ArticleHost; record: ArticleRecord };
export type PublishedArticle = { uri: string; cid: string; record: ArticleRecord; wrapperUri?: string; wrapperCid?: string };
export type ArticlePublishInput = {
  publication: ArticlePublication;
  title: string;
  description?: string;
  path: string;
  tags: string[];
  markdown: string;
  bodyAssets?: ArticleImageAsset[];
  cover?: ArticleImageAsset;
  existing?: PublishedArticle;
  /** Stable TID from articleDraftRecordKey: retries address the same PDS record. */
  recordKey?: string;
};
export type ArticlePublishResult = { uri: string; cid: string; wrapperUri?: string; wrapperCid?: string; url: string };
