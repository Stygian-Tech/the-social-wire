"use client";

import { useState } from "react";
import { moderateProfile } from "@atproto/api";
import { useQueryClient } from "@tanstack/react-query";
import { FeedHeader } from "@/components/FeedHeader/FeedHeader";
import { floatingGlassClasses } from "@/components/shared/floatingChromeStyles";
import { Avatar } from "@/components/shared/Avatar";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { useAuth } from "@/hooks/useAuth";
import { useBlueskySocialCatalog } from "@/hooks/useBlueskySocialCatalog";
import { useSocialExplore } from "@/hooks/useSocialDiscovery";
import { socialDiscoveryErrorMessage, type SocialExploreKind } from "@/lib/blueskySocialDiscoveryClient";
import { SCOPE_RECOVERY_MESSAGE } from "@/lib/oauthScopeRecovery";
import { InteractiveSocialPost } from "./InteractiveSocialPost";
import { SocialPermissionRecovery } from "./SocialPermissionRecovery";
import { SocialTimelineSkeleton } from "./SocialTimelineSkeleton";
import { moderateSocialPost } from "./socialModeration";
import { socialHttpsUrl, socialProfileUrl } from "./socialUrls";

export function SocialExplore() {
  const { session } = useAuth();
  return <SocialExploreViewer key={session?.did ?? "signed-out"} />;
}

function SocialExploreViewer() {
  const { session } = useAuth();
  const [draft, setDraft] = useState("");
  const [query, setQuery] = useState("");
  const [kind, setKind] = useState<SocialExploreKind>("posts");
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
      <div className={`${floatingGlassClasses} mx-auto my-2 flex w-[calc(100%-1rem)] max-w-2xl flex-col gap-4 p-3 sm:p-4`}>
        <form className="flex gap-2" onSubmit={event => { event.preventDefault(); setQuery(draft.trim()); }}>
          <Input aria-label="Search Bluesky" placeholder="Search Posts and People" value={draft} maxLength={500} onChange={event => setDraft(event.target.value)} />
          <Button type="submit">Search</Button>
        </form>
        <div role="group" aria-label="Search Type" className="flex gap-2">
          <Button variant={kind === "posts" ? "default" : "outline"} aria-pressed={kind === "posts"} onClick={() => setKind("posts")}>Posts</Button>
          <Button variant={kind === "people" ? "default" : "outline"} aria-pressed={kind === "people"} onClick={() => setKind("people")}>People</Button>
        </div>
        {error ? <section role="alert" className="flex flex-col items-start gap-3 py-4">
          <h2 className="text-lg font-semibold">Explore Unavailable</h2><p className="text-sm text-muted-foreground">{error}</p>
          {error === SCOPE_RECOVERY_MESSAGE ? <SocialPermissionRecovery /> : <Button variant="outline" onClick={() => { void refresh(); }}>Retry</Button>}
        </section> : !moderation || results.isPending ? <SocialTimelineSkeleton /> : <>
          {!query ? <h2 className="text-lg font-semibold">Suggested People</h2> : null}
          {posts.map(post => <InteractiveSocialPost key={post.uri} item={{ post }} moderation={moderation} />)}
          {actors.map(actor => {
            const avatarHidden = moderateProfile(actor, moderation).ui("avatar").blur;
            return <a key={actor.did} href={socialProfileUrl(actor.did)} target="_blank" rel="noopener noreferrer" className="flex items-start gap-3 rounded-2xl border bg-card p-4">
              <Avatar src={avatarHidden ? undefined : socialHttpsUrl(actor.avatar)} alt="" size={40} />
              <div className="min-w-0 flex-1"><p className="break-words font-semibold">{actor.displayName || actor.handle}</p><p className="break-all text-sm text-muted-foreground">@{actor.handle}</p>{actor.description ? <p className="mt-2 whitespace-pre-wrap break-words text-sm">{actor.description}</p> : null}</div>
            </a>;
          })}
          {!posts.length && !actors.length ? <p className="py-8 text-center text-sm text-muted-foreground">{query ? "No matching results to show." : "No suggestions to show right now."}</p> : null}
          {results.hasNextPage ? <Button variant="outline" disabled={results.isFetchingNextPage} onClick={() => { void results.fetchNextPage(); }}>{results.isFetchingNextPage ? "Loading…" : "Load More"}</Button> : null}
        </>}
      </div>
    </div>
  </div>;
}
