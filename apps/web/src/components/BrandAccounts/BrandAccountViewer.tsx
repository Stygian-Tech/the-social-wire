"use client";

import { useEffect, useState } from "react";
import { AppBskyFeedDefs, moderateNotification, moderateProfile, type AppBskyFeedDefs as FeedTypes } from "@atproto/api";
import { Heart, MessageCircle, Repeat2 } from "lucide-react";
import { notificationFeedItem, notificationIdentity, notificationPostUri } from "@/lib/blueskySocialDiscoveryClient";
import { linkBrandAccount } from "@/lib/brandAccounts/brandAccountSessions";
import { Avatar } from "@/components/shared/Avatar";
import { Button } from "@/components/ui/button";
import { SocialPostCard } from "@/components/Social/SocialPostCard";
import { SocialReplyContext } from "@/components/Social/SocialReplyContext";
import { moderateSocialPost } from "@/components/Social/socialModeration";
import { socialHttpsUrl } from "@/components/Social/socialUrls";
import { BrandPostComposer } from "./BrandPostComposer";
import { useBrandAccountSocial } from "./useBrandAccountSocial";

export function BrandAccountViewer({ ownerDid, brandDid, notificationsOnly = false, onUnread }: { ownerDid: string; brandDid: string; notificationsOnly?: boolean; onUnread?: (did: string, count: number | undefined) => void }) {
  const [tab, setTab] = useState<"posts" | "notifications">("notifications");
  const [threadUri, setThreadUri] = useState<string>();
  const [compose, setCompose] = useState<{ parent?: FeedTypes.PostView }>();
  const [reauthorizing, setReauthorizing] = useState(false);
  const [authorizationError, setAuthorizationError] = useState<string>();
  const brand = useBrandAccountSocial(ownerDid, brandDid, threadUri, { includePosts: !notificationsOnly });
  const unreadCount = brand.connection.session && brand.moderation && !brand.unread.isError ? brand.unread.data : undefined;
  useEffect(() => { onUnread?.(brandDid, unreadCount); return () => onUnread?.(brandDid, undefined); }, [brandDid, unreadCount, onUnread]);
  const { moderation, connection, mutation } = brand;
  const error = authorizationError ?? connection.error ?? brand.catalog.error?.message ?? brand.profile.error?.message ?? brand.unread.error?.message ?? (tab === "posts" ? brand.posts.error?.message : brand.notifications.error?.message) ?? mutation.error?.message;
  const profile = brand.profile.data;
  const showAvatar = profile && moderation && !["filter", "blur", "noOverride"].some(flag => moderateProfile(profile, moderation).ui("avatar")[flag as "filter" | "blur" | "noOverride"]);
  const safeName = profile && moderation && !["filter", "blur", "noOverride"].some(flag => moderateProfile(profile, moderation).ui("displayName")[flag as "filter" | "blur" | "noOverride"]) ? profile.displayName : undefined;
  function actions(post: FeedTypes.PostView) {
    const interaction = brand.interactions[post.uri] ?? post.viewer;
    return <div className="flex gap-5 text-sm text-muted-foreground" aria-label="Brand Post Actions"><button disabled={mutation.isPending} className="flex items-center gap-2 rounded-lg p-1 hover:bg-accent" onClick={() => setCompose({ parent: post })} aria-label="Reply as Brand Account"><MessageCircle className="size-4" />{post.replyCount ?? 0}</button><button disabled={mutation.isPending} aria-pressed={!!interaction?.repost} className="flex items-center gap-2 rounded-lg p-1 hover:bg-accent" aria-label="Repost as Brand Account" onClick={() => { void mutation.mutateAsync({ kind: "repost", post }).catch(() => {}); }}><Repeat2 className="size-4" />{post.repostCount ?? 0}</button><button disabled={mutation.isPending} aria-pressed={!!interaction?.like} className="flex items-center gap-2 rounded-lg p-1 hover:bg-accent" aria-label="Like as Brand Account" onClick={() => { void mutation.mutateAsync({ kind: "like", post }).catch(() => {}); }}><Heart className={`size-4 ${interaction?.like ? "fill-current text-rose-500" : ""}`} />{post.likeCount ?? 0}</button></div>;
  }
  function card(item: FeedTypes.FeedViewPost) {
    if (!moderation) return null;
    const decision = moderateSocialPost(item.post, moderation).ui("contentList");
    if (decision.filter) return null;
    const grouped = !!item.reply && !decision.blur && !decision.noOverride;
    return <div key={item.post.uri} className={`space-y-2 ${grouped ? "rounded-2xl border bg-card p-4" : ""}`}>{grouped && item.reply ? <SocialReplyContext reply={item.reply} postUri={item.post.uri} moderation={moderation} onOpenPost={post => setThreadUri(post.uri)} /> : null}<SocialPostCard embedded={grouped} item={item} moderation={moderation} onOpen={() => setThreadUri(item.post.uri)} onOpenPost={post => setThreadUri(post.uri)} actions={actions(item.post)} /></div>;
  }
  const pages = brand.notifications.data?.pages ?? [];
  const posts = new Map(pages.flatMap(page => page.posts).map(post => [post.uri, post]));
  const notificationIds = new Set<string>();
  const notifications = moderation ? pages.flatMap(page => page.notifications).filter(item => { const id = notificationIdentity(item); const decision = moderateNotification(item, moderation).ui("contentList"); if (notificationIds.has(id) || decision.filter || decision.blur || decision.noOverride) return false; notificationIds.add(id); return true; }) : [];
  const ownPosts = new Map(brand.posts.data?.pages.flatMap(page => page.feed).map(item => [item.post.uri, item]) ?? []);
  const thread = AppBskyFeedDefs.isThreadViewPost(brand.thread.data?.thread) ? brand.thread.data.thread as FeedTypes.ThreadViewPost : undefined;
  return <div className="mx-auto max-w-2xl space-y-4 pb-4">
    <header className="space-y-3 rounded-2xl border bg-card p-4"><div className="flex items-center gap-3"><Avatar src={showAvatar ? socialHttpsUrl(profile?.avatar) : undefined} alt="" size={44} /><div className="min-w-0"><h2 className="truncate font-semibold">{safeName || profile?.handle || "Linked Brand Account"}</h2><p className="break-all text-xs text-muted-foreground">Acting as {profile?.handle ? `@${profile.handle} · ` : ""}{brandDid}</p></div></div><div className="flex flex-wrap gap-2">{!notificationsOnly ? <Button size="sm" disabled={!moderation || mutation.isPending} onClick={() => setCompose({})}>Compose Post</Button> : null}<Button size="sm" variant="outline" disabled={!moderation || mutation.isPending} onClick={() => { void brand.refresh(); }}>Refresh</Button><Button size="sm" variant="outline" disabled={!moderation || mutation.isPending} onClick={() => { void mutation.mutateAsync({ kind: "seen" }).catch(() => {}); }}>Mark Notifications Read</Button></div>{!notificationsOnly ? <div className="flex gap-2"><Button size="sm" variant={tab === "notifications" ? "default" : "outline"} onClick={() => setTab("notifications")}>Notifications{brand.unread.data != null ? ` · ${brand.unread.data}` : ""}</Button><Button size="sm" variant={tab === "posts" ? "default" : "outline"} onClick={() => setTab("posts")}>Posts</Button></div> : <p className="text-sm">{unreadCount === undefined ? "Brand Notifications" : `${unreadCount} Brand Unread`}</p>}</header>
    {error ? <div role="alert" className="space-y-2 rounded-xl border p-3"><p className="text-sm">{error}</p><Button size="sm" variant="outline" disabled={reauthorizing} onClick={() => { setReauthorizing(true); setAuthorizationError(undefined); void linkBrandAccount(ownerDid, brandDid).catch(failure => { setAuthorizationError(failure instanceof Error ? failure.message : "Authorization Could Not Be Opened."); setReauthorizing(false); }); }}>{reauthorizing ? "Authorizing…" : "Reauthorize Account"}</Button>{connection.error ? <Button size="sm" onClick={connection.retry}>Reconnect Account</Button> : <Button size="sm" variant="outline" onClick={() => { void brand.refresh(); }}>Retry</Button>}</div> : null}
    {!moderation ? !error ? <p role="status" className="p-8 text-center">Loading Brand Account…</p> : null : threadUri ? <section className="space-y-3"><Button variant="outline" size="sm" onClick={() => setThreadUri(undefined)}>Back</Button><h3 className="font-semibold">Post Conversation</h3>{brand.thread.isPending ? <p role="status">Loading Conversation…</p> : brand.thread.error ? <p role="alert">{brand.thread.error.message}</p> : thread ? <>{AppBskyFeedDefs.isThreadViewPost(thread.parent) ? card({ post: thread.parent.post }) : null}{card({ post: thread.post })}{thread.replies?.filter(AppBskyFeedDefs.isThreadViewPost).map(reply => card({ post: reply.post }))}</> : <p>This Conversation Is Unavailable.</p>}</section> : tab === "posts" ? <>{[...ownPosts.values()].map(card)}{brand.posts.isPending ? <p role="status">Loading Posts…</p> : !ownPosts.size ? <p>No Posts Yet</p> : null}{brand.posts.hasNextPage ? <Button variant="outline" disabled={brand.posts.isFetchingNextPage} onClick={() => { void brand.posts.fetchNextPage(); }}>Load More Posts</Button> : null}</> : <>{notifications.map(notification => { const item = notificationFeedItem(notification, posts); const uri = notificationPostUri(notification); return <section key={notificationIdentity(notification)} className="space-y-3 rounded-2xl border p-3"><p className="text-sm">@{notification.author.handle} · {notification.reason}</p>{item ? card(item) : uri ? <Button size="sm" variant="outline" onClick={() => setThreadUri(uri)}>View Post</Button> : null}</section>; })}{brand.notifications.isPending ? <p role="status">Loading Notifications…</p> : !notifications.length ? <p>No Notifications Yet</p> : null}{brand.notifications.hasNextPage ? <Button variant="outline" disabled={brand.notifications.isFetchingNextPage} onClick={() => { void brand.notifications.fetchNextPage(); }}>Load More Notifications</Button> : null}</>}
    {compose && moderation && connection.session ? <BrandPostComposer ownerDid={ownerDid} session={connection.session} moderation={moderation} profile={profile} parent={compose.parent} pending={mutation.isPending} assertCurrentActor={connection.assertCurrentActor} publish={text => mutation.mutateAsync({ kind: "post", text, parent: compose.parent })} close={() => setCompose(undefined)} /> : null}

  </div>;
}
