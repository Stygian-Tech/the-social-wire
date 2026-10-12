"use client";

/* eslint-disable @next/next/no-img-element -- OG images retain the source publisher format. */

import { useState } from "react";
import { AppBskyRichtextFacet, RichText, type ChatBskyConvoDefs } from "@atproto/api";
import { useQuery } from "@tanstack/react-query";
import { useAuth } from "@/hooks/useAuth";
import { useCachedImageUrl } from "@/hooks/useCachedImageUrl";
import { fetchLatrOgPreview } from "@/lib/latrSaveMetadataBackfill";
import { chatPostReference } from "./SocialChatPostPreview";
import { socialHttpsUrl } from "./socialUrls";

type LinkMessage = Pick<ChatBskyConvoDefs.MessageView, "text" | "facets">;

/** One bounded preview, with facet destinations taking precedence over visible text. */
export function chatLinkPreviewUrl(message: LinkMessage): string | undefined {
  const candidates: string[] = [];
  for (const segment of new RichText(message).segments()) {
    const link = segment.facet?.features.find(AppBskyRichtextFacet.isLink);
    if (AppBskyRichtextFacet.isLink(link)) candidates.push(link.uri);
    else for (const match of segment.text.matchAll(/https:\/\/[^\s<>"']+/g)) candidates.push(match[0].replace(/[.,!?;:]+$/, ""));
  }
  for (const candidate of candidates) {
    const url = socialHttpsUrl(candidate);
    if (url && !chatPostReference(url)) return url;
  }
}

export function SocialChatLinkPreview({ message }: { message: LinkMessage }) {
  const url = chatLinkPreviewUrl(message);
  return url ? <ResolvedLinkPreview key={url} url={url} /> : null;
}

function ResolvedLinkPreview({ url }: { url: string }) {
  const { session, getOAuthSession, oauthSessionReloadSeq } = useAuth();
  const preview = useQuery({
    queryKey: ["blueskySocial", session?.did ?? "", "chatLinkPreview", oauthSessionReloadSeq, url],
    enabled: !!session,
    queryFn: async () => {
      const oauth = getOAuthSession();
      if (!oauth || oauth.did !== session?.did) return null;
      return fetchLatrOgPreview(oauth, url);
    },
    staleTime: 10 * 60_000,
    gcTime: 30 * 60_000,
    retry: false,
  });
  const image = socialHttpsUrl(preview.data?.image);
  const cached = useCachedImageUrl(image);
  const [failedImage, setFailedImage] = useState<string>();
  if (!session || preview.isError || !preview.data) return null;
  const host = new URL(url).hostname;
  return <a href={url} target="_blank" rel="noopener noreferrer" className="mt-2 block w-full min-w-0 max-w-[400px] overflow-hidden rounded-xl border bg-background/40 transition-colors hover:bg-background/60" aria-label={`Open ${preview.data.title || host}`}>
    {cached.objectUrl && !cached.failed && failedImage !== image ? <img
      src={cached.objectUrl}
      alt=""
      loading="lazy"
      referrerPolicy="no-referrer"
      className="mx-auto block h-auto max-h-60 w-auto max-w-full"
      onError={() => setFailedImage(image)}
    /> : null}
    <div className="flex min-w-0 flex-col gap-1 p-2.5 [overflow-wrap:anywhere]">
      <span className="line-clamp-2 text-sm font-medium">{preview.data.title || host}</span>
      {preview.data.excerpt ? <span className="line-clamp-2 text-xs text-muted-foreground">{preview.data.excerpt}</span> : null}
      <span className="truncate text-[10px] text-muted-foreground">{preview.data.site ? `${preview.data.site} · ` : ""}{host}</span>
    </div>
  </a>;
}
