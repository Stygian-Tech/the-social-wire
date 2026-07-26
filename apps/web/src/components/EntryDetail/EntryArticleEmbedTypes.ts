import type { ReactNode } from "react";

export interface EntryArticleEmbedProps {
  url: string;
  title: string;
  className?: string;
  fallbackContent?: ReactNode;
  expectedAtUri?: string;
}
