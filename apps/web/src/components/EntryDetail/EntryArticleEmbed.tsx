"use client";

import { useMemo } from "react";
import { EntryArticleEmbedInner } from "@/components/EntryDetail/EntryArticleEmbedInner";
import type { EntryArticleEmbedProps } from "@/components/EntryDetail/EntryArticleEmbedTypes";
import { sanitizeEmbedUrlForIframe } from "@/lib/publicResourceUrl";

export function EntryArticleEmbed(props: EntryArticleEmbedProps) {
  const pageUrl = useMemo(
    () => sanitizeEmbedUrlForIframe(props.url),
    [props.url],
  );
  return <EntryArticleEmbedInner key={pageUrl} {...props} pageUrl={pageUrl} />;
}
