"use client";

import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { useAuth } from "@/hooks/useAuth";
import {
  createOAuthAgent,
  createPublicAppViewAgent,
  type EntryDetail,
} from "@/lib/atprotoClient";
import { normalizeHttpUrlToHttps } from "@/lib/publicResourceUrl";

export const bskyPostViewerKey = (uri: string | undefined) =>
  ["bsky-post-viewer", uri ?? ""] as const;

export function useEntrySocial(entry: EntryDetail | null) {
  const { getOAuthSession } = useAuth();
  const queryClient = useQueryClient();
  const uri = entry?.bskyPostUri;
  const cid = entry?.bskyPostCid;

  const viewerQuery = useQuery({
    queryKey: bskyPostViewerKey(uri),
    queryFn: async () => {
      if (!uri) return null;
      // App View read — must not use PDS-audience OAuth fetch (see AGENTS.md).
      const agent = createPublicAppViewAgent();
      const res = await agent.api.app.bsky.feed.getPosts({ uris: [uri] });
      const post = res.data.posts[0];
      if (!post) return null;
      return {
        likeUri: post.viewer?.like,
        repostUri: post.viewer?.repost,
      };
    },
    enabled: !!uri && !!cid,
    staleTime: 30_000,
  });

  const invalidateViewer = () => {
    if (uri) {
      void queryClient.invalidateQueries({ queryKey: bskyPostViewerKey(uri) });
    }
  };

  const toggleLikeMutation = useMutation({
    mutationFn: async ({ likeUri }: { likeUri?: string }) => {
      const oauth = getOAuthSession();
      if (!oauth || !uri || !cid) throw new Error("Missing post or session");
      const agent = createOAuthAgent(oauth);
      if (likeUri) await agent.deleteLike(likeUri);
      else await agent.like(uri, cid);
    },
    onSuccess: invalidateViewer,
  });

  const toggleRepostMutation = useMutation({
    mutationFn: async ({ repostUri }: { repostUri?: string }) => {
      const oauth = getOAuthSession();
      if (!oauth || !uri || !cid) throw new Error("Missing post or session");
      const agent = createOAuthAgent(oauth);
      if (repostUri) await agent.deleteRepost(repostUri);
      else await agent.repost(uri, cid);
    },
    onSuccess: invalidateViewer,
  });

  const quoteMutation = useMutation({
    mutationFn: async (text: string) => {
      const oauth = getOAuthSession();
      if (!oauth) throw new Error("Not signed in");
      const agent = createOAuthAgent(oauth);
      const rawShare =
        entry?.embedUrl ??
        entry?.originalUrl ??
        (typeof window !== "undefined" ? window.location.href : "");
      const shareUrl =
        rawShare.startsWith("http://") || rawShare.startsWith("https://")
          ? normalizeHttpUrlToHttps(rawShare)
          : rawShare;
      const title = entry?.title ?? "Article";

      if (uri && cid) {
        await agent.post({
          text,
          embed: {
            $type: "app.bsky.embed.record",
            record: { uri, cid },
          },
        });
        return;
      }

      await agent.post({
        text,
        embed: {
          $type: "app.bsky.embed.external",
          external: {
            uri: shareUrl,
            title: title.slice(0, 300),
            description: "",
            ...(entry?.entryId ? { associatedRecord: entry.entryId } : {}),
          },
        },
      });
    },
    onSuccess: invalidateViewer,
  });

  return {
    viewerQuery,
    toggleLikeMutation,
    toggleRepostMutation,
    quoteMutation,
    hasLinkedPost: !!(uri && cid),
  };
}
