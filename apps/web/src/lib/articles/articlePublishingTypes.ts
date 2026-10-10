export type ArticleHost = "leaflet" | "markpub" | "offprint" | "pckt" | "unknown";
export type ArticleRecord = Record<string, unknown>;
export type ArticleBlob = { $type: "blob"; ref: { $link: string }; mimeType: string; size: number };
export type ArticlePublication = { uri: string; cid: string; name: string; url: string; host: ArticleHost; record: ArticleRecord };
export type PublishedArticle = { uri: string; cid: string; record: ArticleRecord; wrapperUri?: string; wrapperCid?: string };
export type ArticleImageAsset = { id: string; blob: ArticleBlob; alt: string; width: number; height: number; url: string };
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
