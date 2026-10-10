/** Private browser draft; publishing is a separate, explicit operation. */
export type ArticleDraft = {
  id: string;
  title: string;
  markdown: string;
  excerpt: string;
  path: string;
  tags: string[];
  publicationUri: string;
  coverAssetId?: string;
  publishedUri?: string;
  assets?: { id: string; alt: string; width: number; height: number; mimeType: string; name: string }[];
  createdAt: string;
  updatedAt: string;
  /** Supply the last saved revision to prevent overwriting edits from another tab. */
  revision?: number;
};
