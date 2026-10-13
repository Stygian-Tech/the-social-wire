"use client";

import type { ComposeLinkPreview } from "@/lib/blueskyExternalEmbed";
import { useRef, useState } from "react";
import { useInfiniteQuery, useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import type { AppBskyFeedDefs } from "@atproto/api";
import { useBrandAccountSession } from "@/hooks/useBrandAccounts";
import { createAuthenticatedAppViewAgent, getBlueskySocialCatalog } from "@/lib/blueskySocialClient";
import { getBlueskyProfilePage } from "@/lib/blueskyProfileClient";
import { getSocialNotificationUnread, getSocialNotificationsPage, markSocialNotificationsSeen, nextDiscoveryCursor } from "@/lib/blueskySocialDiscoveryClient";
import { getBlueskyPostThread, setBlueskyPostEngagement, type SocialEngagementKind } from "@/lib/blueskyPostClient";
import { publishBrandPost } from "@/lib/brandAccounts/brandAccountSocialClient";

export function useBrandAccountSocial(ownerDid: string, brandDid: string, threadUri?: string, options: { includePosts?: boolean } = {}) {
  const connection = useBrandAccountSession(ownerDid, brandDid);
  const cache = useQueryClient();
  const [interactions, setInteractions] = useState<Record<string, { like?: string; repost?: string }>>({});
  const locked = useRef(false);
  const key = ["brandAccounts", ownerDid, brandDid, connection.generation] as const;
  async function read<T>(work: (session: NonNullable<typeof connection.session>) => Promise<T>): Promise<T> { connection.assertCurrentActor(); const result = await work(connection.session!); connection.assertCurrentActor(); return result; }
  const catalog = useQuery({ queryKey: [...key, "catalog"], enabled: !!connection.session, queryFn: ({ signal }) => read(session => getBlueskySocialCatalog(session, signal, { includeFeeds: false })), retry: false });
  const moderation = !!connection.session && !catalog.isError && catalog.data?.moderation.userDid === brandDid ? catalog.data.moderation : undefined;
  const profile = useQuery({ queryKey: [...key, "profile"], enabled: !!connection.session && !!moderation, queryFn: ({ signal }) => read(async session => { const data = (await createAuthenticatedAppViewAgent(session).app.bsky.actor.getProfile({ actor: brandDid }, { signal })).data; if (data.did !== brandDid) throw new Error("The Brand Profile Identity Does Not Match."); return data; }), retry: false });
  const posts = useInfiniteQuery({ queryKey: [...key, "posts"], enabled: options.includePosts !== false && !!moderation && !!connection.session, initialPageParam: undefined as string | undefined, queryFn: ({ pageParam, signal }) => read(session => getBlueskyProfilePage({ session, tab: "posts", moderation: moderation!, cursor: pageParam, signal })), getNextPageParam: (page, _pages, _last, params) => page.cursor && !params.includes(page.cursor) ? page.cursor : undefined, retry: false });
  const notifications = useInfiniteQuery({ queryKey: [...key, "notifications"], enabled: !!moderation && !!connection.session, initialPageParam: undefined as string | undefined, queryFn: ({ pageParam, signal }) => read(session => getSocialNotificationsPage({ session, moderation: moderation!, cursor: pageParam, signal })), getNextPageParam: (page, _pages, _last, params) => nextDiscoveryCursor(page, params), retry: false });
  const unread = useQuery({ queryKey: [...key, "unread"], enabled: !!moderation && !!connection.session, queryFn: ({ signal }) => read(session => getSocialNotificationUnread(session, signal)), retry: false });
  const thread = useQuery({ queryKey: [...key, "thread", threadUri], enabled: !!threadUri && !!moderation && !!connection.session, queryFn: ({ signal }) => read(session => getBlueskyPostThread({ session, uri: threadUri!, moderation: moderation!, signal })), retry: false });
  const mutation = useMutation({ mutationFn: async (action: { kind: "post"; text: string; linkPreview?: ComposeLinkPreview; parent?: AppBskyFeedDefs.PostView } | { kind: "seen"; seenAt?: string } | { kind: SocialEngagementKind; post: AppBskyFeedDefs.PostView }) => {
    if (locked.current) throw new Error("Wait For the Current Brand Action.");
    connection.assertCurrentActor();
    if (!moderation) throw new Error("Brand Account Moderation Is Unavailable.");
    locked.current = true;
    try {
    const session = connection.session!;
    if (action.kind === "post") await publishBrandPost({ session, text: action.text, linkPreview: action.linkPreview, parent: action.parent, assertCurrentActor: connection.assertCurrentActor });
    else if (action.kind === "seen") await markSocialNotificationsSeen(session, action.seenAt ?? new Date().toISOString());
    else {
      const current = interactions[action.post.uri] ?? action.post.viewer;
      const uri = await setBlueskyPostEngagement({ session, moderation: moderation!, kind: action.kind, uri: action.post.uri, cid: action.post.cid, existingUri: current?.[action.kind] });
      connection.assertCurrentActor();
      setInteractions(previous => ({ ...previous, [action.post.uri]: { ...(previous[action.post.uri] ?? action.post.viewer), [action.kind]: uri } }));
    }
    connection.assertCurrentActor();
    await cache.invalidateQueries({ queryKey: key });
    } finally { locked.current = false; }
  }, retry: false });
  return { connection, profile, moderation, catalog, posts, notifications, unread, thread, mutation, interactions, refresh: () => cache.invalidateQueries({ queryKey: key }), key };
}
