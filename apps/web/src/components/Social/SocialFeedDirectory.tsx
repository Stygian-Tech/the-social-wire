"use client";
import { FeedHeader } from "@/components/FeedHeader/FeedHeader";
import { useAuth } from "@/hooks/useAuth";
import { SCOPE_RECOVERY_MESSAGE } from "@/lib/oauthScopeRecovery";
import { SocialPermissionRecovery } from "./SocialPermissionRecovery";
import { useState } from "react";
import Link from "next/link";
import { moderateFeedGenerator, type AppBskyFeedDefs } from "@atproto/api";
import { useBlueskySocialCatalog } from "@/hooks/useBlueskySocialCatalog";
import { useSocialFeedDirectory } from "@/hooks/useSocialFeedDirectory";
import { socialErrorMessage, socialFeedHref } from "@/lib/blueskySocialClient";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";

export function SocialFeedDirectory() {
  const { session } = useAuth();
  return <SocialFeedDirectoryViewer key={session?.did ?? "signed-out"} />;
}

function SocialFeedDirectoryViewer() {
  const [search, setSearch] = useState("");
  const [query, setQuery] = useState("");
  const catalog = useBlueskySocialCatalog();
  const { directory, saved: savedGenerators, mutation } = useSocialFeedDirectory(query);
  const feeds = Array.from(new Map(directory.data?.pages.flatMap(page => page.feeds).map(feed => [feed.uri, feed]) ?? []).values());
  function renderFeed(feed: AppBskyFeedDefs.GeneratorView) {
    if (!catalog.data || catalog.isError) return null;
    const decision = moderateFeedGenerator(feed, catalog.data.moderation);
    if (["contentList", "contentView", "profileList"].some(context => { const ui = decision.ui(context as "contentList"); return ui.filter || ui.blur || ui.noOverride; })) return null;
    const saved = catalog.data.feeds.find(item => item.uri === feed.uri);
    return <article key={feed.uri} className="flex flex-col gap-3 rounded-xl border bg-card p-4">
      <div><h2 className="font-semibold">{feed.displayName}</h2><p className="text-sm text-muted-foreground">By @{(decision.ui("displayName").blur || decision.ui("displayName").noOverride) ? "hidden" : feed.creator.handle}</p></div>
      {feed.description ? <p className="whitespace-pre-wrap break-words text-sm">{feed.description}</p> : null}
      <div className="flex flex-wrap gap-2">
        <Link className="rounded-md border px-3 py-2 text-sm hover:bg-muted" href={socialFeedHref({ kind: "feed", uri: feed.uri, name: feed.displayName, pinned: saved?.pinned ?? false })}>Open Feed</Link>
        {!saved ? <Button variant="outline" disabled={mutation.isPending} onClick={() => mutation.mutate({ uri: feed.uri, action: "save" })}>Save Feed</Button> : <Button variant="outline" disabled={mutation.isPending} onClick={() => mutation.mutate({ uri: feed.uri, action: "remove" })}>Remove Feed</Button>}
        <Button variant="outline" disabled={mutation.isPending} onClick={() => mutation.mutate({ uri: feed.uri, action: saved?.pinned ? "unpin" : "pin" })}>{saved?.pinned ? "Unpin Feed" : "Pin Feed"}</Button>
      </div>
    </article>;
  }
  return <div className="flex min-h-0 w-full flex-1 flex-col"><FeedHeader title="Feeds" subtitle="Social" /><div className="min-h-0 flex-1 overflow-y-auto overscroll-contain"><section className="mx-auto flex w-full max-w-3xl flex-col gap-4 p-4">
    <p className="text-sm text-muted-foreground">Discover custom feeds. Saved feeds appear in your Social feed navigation.</p>
    <form className="flex gap-2" onSubmit={event => { event.preventDefault(); setQuery(search.trim()); }}><Input aria-label="Search Feeds" value={search} onChange={event => setSearch(event.target.value)} placeholder="Search feeds" /><Button type="submit">Search</Button></form>
    {catalog.isPending || directory.isPending ? <p role="status">Loading feeds…</p> : null}
    {catalog.error || directory.error || mutation.error ? <div role="alert" className="flex flex-col gap-2"><p>{socialErrorMessage(catalog.error ?? directory.error ?? mutation.error)}</p>{socialErrorMessage(catalog.error ?? directory.error ?? mutation.error) === SCOPE_RECOVERY_MESSAGE ? <SocialPermissionRecovery /> : <Button variant="outline" onClick={() => { void catalog.refetch(); void directory.refetch(); mutation.reset(); }}>Retry</Button>}</div> : null}
    {savedGenerators.error ? <div role="alert"><p>{socialErrorMessage(savedGenerators.error)}</p>{socialErrorMessage(savedGenerators.error) === SCOPE_RECOVERY_MESSAGE ? <SocialPermissionRecovery /> : <Button variant="outline" onClick={() => { void savedGenerators.refetch(); }}>Retry</Button>}</div> : null}
    {catalog.data && savedGenerators.data?.length ? <div className="flex flex-col gap-3"><h2 className="font-semibold">Saved Feeds</h2>{savedGenerators.data.map(renderFeed)}</div> : null}
    <h2 className="font-semibold">{query ? "Search Results" : "Discover Feeds"}</h2>
    {catalog.data ? feeds.map(renderFeed) : null}
    {!directory.isPending && !directory.error && !feeds.length ? <p>No feeds found.</p> : null}
    {directory.hasNextPage ? <Button variant="outline" disabled={directory.isFetchingNextPage} onClick={() => { void directory.fetchNextPage(); }}>Load More</Button> : null}
  </section></div></div>;
}
