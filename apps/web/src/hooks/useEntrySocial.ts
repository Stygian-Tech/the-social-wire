"use client";

import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import type { OAuthSession } from "@atproto/oauth-client-browser";
import { useAuth } from "@/hooks/useAuth";
import {
  createOAuthAgent,
  createPublicAppViewAgent,
  type EntryDetail,
} from "@/lib/atprotoClient";
import { canonicalArticleHttpsUrl } from "@/lib/articleCanonicalUrl";
import { decodeHtmlEntities } from "@/lib/decodeHtmlEntities";
import { isOriginalEntryContentUri } from "@/lib/savedLinkSocialTarget";

export const bskyPostViewerKey = (uri: string | undefined) =>
  ["bsky-post-viewer", uri ?? ""] as const;

type BskyRepoCollection =
  | "app.bsky.feed.post"
  | "app.bsky.feed.like"
  | "app.bsky.feed.repost";

const REAUTH_FOR_BSKY_WRITE_MESSAGE =
  "Your Bluesky posting permission needs to be refreshed. Sign out and sign back in, then try again.";
const MAX_EXTERNAL_THUMB_BYTES = 1_000_000;

function truncateExternalText(text: string, maxLength: number): string {
  const normalized = decodeHtmlEntities(text).replace(/\s+/g, " ").trim();
  if (normalized.length <= maxLength) return normalized;
  return `${normalized.slice(0, Math.max(0, maxLength - 1)).trimEnd()}…`;
}

function externalCardTitle(entry: EntryDetail | null): string {
  return truncateExternalText(entry?.title?.trim() || "Article", 300);
}

function externalCardDescription(entry: EntryDetail | null): string {
  return truncateExternalText(
    entry?.summary?.trim() || entry?.contentHtml?.trim() || "",
    1_000
  );
}

function externalCardThumbnailCandidates(entry: EntryDetail | null): string[] {
  return [
    entry?.thumbnailUrl?.trim(),
    entry?.thumbnailFallbackUrl?.trim(),
  ].filter((url): url is string => !!url && /^https:\/\//i.test(url));
}

async function uploadExternalCardThumb(
  agent: ReturnType<typeof createOAuthAgent>,
  entry: EntryDetail | null
) {
  for (const url of externalCardThumbnailCandidates(entry)) {
    try {
      const params = new URLSearchParams({ url });
      const res = await fetch(`/api/bluesky-card-thumb?${params.toString()}`);
      if (!res.ok) continue;
      const blob = await res.blob();
      if (!blob.type.startsWith("image/")) continue;
      if (blob.size === 0 || blob.size > MAX_EXTERNAL_THUMB_BYTES) continue;
      const uploaded = await agent.uploadBlob(blob);
      return uploaded.data.blob;
    } catch {
      /* Thumbnail upload is best-effort; post the card without an image. */
    }
  }
  return undefined;
}

function scopeAllowsRepoAction(
  scopeToken: string,
  collection: BskyRepoCollection,
  action: "create" | "delete"
): boolean {
  if (scopeToken === `repo:${collection}` || scopeToken === "repo:*") {
    return true;
  }

  const [repoScope, query = ""] = scopeToken.split("?");
  if (repoScope !== `repo:${collection}`) return false;
  if (!query) return true;

  const params = new URLSearchParams(query);
  const actions = params.getAll("action");
  return actions.length === 0 || actions.includes(action);
}

async function requireBskyRepoScope(
  session: OAuthSession,
  collection: BskyRepoCollection,
  action: "create" | "delete"
): Promise<void> {
  const info = await session.getTokenInfo("auto");
  const scopes = String(info.scope ?? "").split(/\s+/).filter(Boolean);
  if (!scopes.some((scope) => scopeAllowsRepoAction(scope, collection, action))) {
    throw new Error(REAUTH_FOR_BSKY_WRITE_MESSAGE);
  }
}

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
      await requireBskyRepoScope(
        oauth,
        "app.bsky.feed.like",
        likeUri ? "delete" : "create"
      );
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
      await requireBskyRepoScope(
        oauth,
        "app.bsky.feed.repost",
        repostUri ? "delete" : "create"
      );
      const agent = createOAuthAgent(oauth);
      if (repostUri) await agent.deleteRepost(repostUri);
      else await agent.repost(uri, cid);
    },
    onSuccess: invalidateViewer,
  });

  const postMutation = useMutation({
    mutationFn: async (text: string) => {
      const oauth = getOAuthSession();
      if (!oauth) throw new Error("Not signed in");
      await requireBskyRepoScope(oauth, "app.bsky.feed.post", "create");
      const shouldLikeLinkedPost = !!(uri && cid && !viewerQuery.data?.likeUri);
      if (shouldLikeLinkedPost) {
        await requireBskyRepoScope(oauth, "app.bsky.feed.like", "create");
      }
      const agent = createOAuthAgent(oauth);
      const shareUrl = entry ? canonicalArticleHttpsUrl(entry) : null;
      if (!shareUrl) throw new Error("No canonical article URL for this entry");
      const title = externalCardTitle(entry);
      const description = externalCardDescription(entry);
      const thumb = await uploadExternalCardThumb(agent, entry);
      const postPromise = agent.post({
        text,
        embed: {
          $type: "app.bsky.embed.external",
          external: {
            uri: shareUrl,
            title,
            description,
            ...(thumb ? { thumb } : {}),
            ...(entry?.entryId && isOriginalEntryContentUri(entry.entryId)
              ? { associatedRecord: entry.entryId }
              : {}),
          },
        },
      });
      const likePromise = shouldLikeLinkedPost
        ? agent.like(uri, cid)
        : Promise.resolve();
      await Promise.all([postPromise, likePromise]);
    },
    onSettled: invalidateViewer,
  });

  const replyMutation = useMutation({
    mutationFn: async (text: string) => {
      const oauth = getOAuthSession();
      if (!oauth || !uri || !cid) throw new Error("Missing post or session");
      await requireBskyRepoScope(oauth, "app.bsky.feed.post", "create");
      const agent = createOAuthAgent(oauth);
      await agent.post({
        text,
        reply: {
          root: { uri, cid },
          parent: { uri, cid },
        },
      });
    },
    onSuccess: invalidateViewer,
  });

  return {
    viewerQuery,
    toggleLikeMutation,
    toggleRepostMutation,
    postMutation,
    replyMutation,
    hasLinkedPost: !!(uri && cid),
  };
}
