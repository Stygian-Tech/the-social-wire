"use client";

import { useState } from "react";
import { useRouter, useSearchParams } from "next/navigation";
import { moderateProfile } from "@atproto/api";
import { useQueryClient } from "@tanstack/react-query";
import { FeedHeader } from "@/components/FeedHeader/FeedHeader";
import { floatingGlassClasses } from "@/components/shared/floatingChromeStyles";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { useAuth } from "@/hooks/useAuth";
import { useBlueskySocialCatalog } from "@/hooks/useBlueskySocialCatalog";
import { useSocialExplore } from "@/hooks/useSocialDiscovery";
import { socialDiscoveryErrorMessage, type SocialExploreKind } from "@/lib/blueskySocialDiscoveryClient";
import { SCOPE_RECOVERY_MESSAGE } from "@/lib/oauthScopeRecovery";
import { InteractiveSocialPost } from "./InteractiveSocialPost";
import { SocialExploreDiscovery } from "./SocialExploreDiscovery";
import { SocialPermissionRecovery } from "./SocialPermissionRecovery";
import { SocialTimelineSkeleton } from "./SocialTimelineSkeleton";
import { moderateSocialPost } from "./socialModeration";
import { SocialExplorePersonCard } from "./SocialExplorePersonCard";

export function SocialExplore() {
  const { session } = useAuth();
  const params = useSearchParams();
  return <SocialExploreViewer key={`${session?.did ?? "signed-out"}:${params?.get("q") ?? ""}:${params?.get("type") ?? "posts"}`} />;
}

function SocialExploreViewer() {
  const { session } = useAuth();
  const params = useSearchParams();
  const router = useRouter();
  const urlQuery = (params?.get("q") ?? "").slice(0, 500);
  const urlKind = params?.get("type") === "people" ? "people" : "posts";
  const [draft, setDraft] = useState(urlQuery);
  const [query, setQuery] = useState(urlQuery);
  const [kind, setKind] = useState<SocialExploreKind>(urlKind);
  function search(value: string, type: SocialExploreKind) {
    setQuery(value); setKind(type);
    const next = new URLSearchParams(params?.toString());
    if (value) next.set("q", value); else next.delete("q");
    next.set("type", type);
    router.replace(`/social/explore?${next}`, { scroll: false });
  }
  const catalog = useBlueskySocialCatalog();
  const availableModeration = catalog.data?.moderation;
  const moderation = !catalog.isError && availableModeration?.userDid === session?.did ? availableModeration : undefined;
  const results = useSocialExplore(query, kind, moderation);
  const queryClient = useQueryClient();
  const error = catalog.isError ? socialDiscoveryErrorMessage(catalog.error, "Explore") : results.isError ? socialDiscoveryErrorMessage(results.error, "Explore") : undefined;
  const seen = new Set<string>();
  const posts = moderation ? (results.data?.pages.flatMap(page => page.posts) ?? []).filter(post => {
    if (seen.has(post.uri) || moderateSocialPost(post, moderation).ui("contentList").filter) return false;
    seen.add(post.uri); return true;
  }) : [];
  const actors = moderation ? (results.data?.pages.flatMap(page => page.actors) ?? []).filter(actor => {
    const decision = moderateProfile(actor, moderation).ui("profileList");
    if (seen.has(actor.did) || decision.filter || decision.blur) return false;
    seen.add(actor.did); return true;
  }) : [];
  async function refresh() {
    const settings = await catalog.refetch();
    if (!settings.isError && session) await queryClient.invalidateQueries({ queryKey: ["blueskySocial", session.did, "explore"] });
  }

  return <div className="flex min-h-0 w-full flex-1 flex-col">
    <FeedHeader title="Explore" subtitle="Social" />
    <div className="min-h-0 flex-1 overflow-y-auto overscroll-contain" key={session?.did}>
      <div className="mx-auto my-2 flex w-[calc(100%-1rem)] max-w-2xl flex-col gap-4">
        <section aria-label="Search" className={`${floatingGlassClasses} flex flex-col gap-4 p-3 sm:p-4`}>
          <h2 className="text-lg font-semibold">Search</h2>
          <form className="flex gap-2" onSubmit={event => { event.preventDefault(); search(draft.trim(), kind); }}>
            <Input aria-label="Search Bluesky" placeholder="Search Posts and People" value={draft} maxLength={500} onChange={event => setDraft(event.target.value)} />
            <Button type="submit">Search</Button>
          </form>
          <div role="group" aria-label="Search Type" className="flex gap-2">
            <Button variant={kind === "posts" ? "default" : "outline"} aria-pressed={kind === "posts"} onClick={() => search(query, "posts")}>Posts</Button>
            <Button variant={kind === "people" ? "default" : "outline"} aria-pressed={kind === "people"} onClick={() => search(query, "people")}>People</Button>
          </div>
        </section>
        <SocialExploreDiscovery moderation={moderation} savedFeeds={catalog.data?.feeds ?? []} enabled={!query} search={value => { setDraft(value); search(value, "posts"); }} />
        <section aria-label={query ? "Search Results" : "Suggested People"} className={`${floatingGlassClasses} flex flex-col gap-4 p-3 sm:p-4`}>
          <h2 className="text-lg font-semibold">{query ? "Search Results" : "Suggested People"}</h2>
          {error ? <div role="alert" className="flex flex-col items-start gap-3 py-4">
            <h2 className="text-lg font-semibold">Explore Unavailable</h2><p className="text-sm text-muted-foreground">{error}</p>
            {error === SCOPE_RECOVERY_MESSAGE ? <SocialPermissionRecovery /> : <Button variant="outline" onClick={() => { void refresh(); }}>Retry</Button>}
          </div> : !moderation || results.isPending ? <SocialTimelineSkeleton /> : <>
            {posts.map(post => <InteractiveSocialPost key={post.uri} item={{ post }} moderation={moderation} />)}
            {actors.map(actor => <SocialExplorePersonCard key={actor.did} actor={actor} moderation={moderation} returnTo={`/social/explore${params?.toString() ? `?${params.toString()}` : ""}`} />)}
            {!posts.length && !actors.length ? <p className="py-8 text-center text-sm text-muted-foreground">{query ? "No matching results to show." : "No suggestions to show right now."}</p> : null}
            {results.hasNextPage ? <Button variant="outline" disabled={results.isFetchingNextPage} onClick={() => { void results.fetchNextPage(); }}>{results.isFetchingNextPage ? "Loading…" : "Load More"}</Button> : null}
          </>}
        </section>
      </div>
    </div>
  </div>;
}
