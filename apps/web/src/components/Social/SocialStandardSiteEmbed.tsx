"use client";
import type { ReactNode } from "react";
import { useQuery } from "@tanstack/react-query";
import type { AppBskyEmbedExternal } from "@atproto/api";
import { useAuth } from "@/hooks/useAuth";
import { fetchStandardSiteEmbed } from "@/lib/standardSiteEmbedClient";
import { StandardSiteArticleCard } from "./StandardSiteArticleCard";
import { StandardSiteArticleActions } from "./StandardSiteArticleActions";

export function SocialStandardSiteEmbed({ external, href, fallback }: {
  external: AppBskyEmbedExternal.ViewExternal; href: string; fallback: ReactNode;
}) {
  const { session, getOAuthSession, oauthSessionReloadSeq } = useAuth();
  const metadata = useQuery({
    queryKey: ["socialStandardSiteEmbed", session?.did, oauthSessionReloadSeq, href],
    queryFn: ({ signal }) => {
      const oauth = getOAuthSession();
      if (!oauth) throw new Error("Sign in to load article details.");
      return fetchStandardSiteEmbed(oauth, href, signal);
    },
    enabled: !!session,
    staleTime: 5 * 60_000,
    gcTime: 10 * 60_000,
    retry: 1,
    refetchOnWindowFocus: false,
  });
  if (!metadata.data) return fallback;
  return <StandardSiteArticleCard metadata={metadata.data} thumb={external.thumb}>
    <StandardSiteArticleActions key={`${session?.did}:${oauthSessionReloadSeq}:${metadata.data.documentUri}`} metadata={metadata.data} />
  </StandardSiteArticleCard>;
}
