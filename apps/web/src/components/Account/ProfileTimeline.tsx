"use client";

import { useState } from "react";
import { Button } from "@/components/ui/button";
import { InteractiveSocialPost } from "@/components/Social/InteractiveSocialPost";
import { SocialTimelineSkeleton } from "@/components/Social/SocialTimelineSkeleton";
import { moderateSocialPost } from "@/components/Social/socialModeration";
import { useAuth } from "@/hooks/useAuth";
import { useBlueskySocialCatalog } from "@/hooks/useBlueskySocialCatalog";
import { useBlueskyProfileTimeline } from "@/hooks/useBlueskyProfileTimeline";
import type { ProfileSection } from "@/lib/blueskyProfileClient";
import { flattenSocialPages, socialErrorMessage, socialPostIdentity } from "@/lib/blueskySocialClient";
import { rememberOAuthReturnPath, SCOPE_RECOVERY_MESSAGE } from "@/lib/oauthScopeRecovery";

export function ProfileTimeline({ section }: { section: ProfileSection }) {
  const { session, signIn } = useAuth();
  const catalog = useBlueskySocialCatalog();
  const moderation = catalog.isError ? undefined : catalog.data?.moderation;
  const timeline = useBlueskyProfileTimeline(section, moderation);
  const [openingLogin, setOpeningLogin] = useState(false);
  const [loginError, setLoginError] = useState(false);
  const error = catalog.isError ? socialErrorMessage(catalog.error) : timeline.isError ? socialErrorMessage(timeline.error) : undefined;
  const posts = moderation ? flattenSocialPages(timeline.data?.pages ?? []).filter(item => !moderateSocialPost(item.post, moderation).ui("contentList").filter) : [];
  async function retry() {
    const result = await catalog.refetch();
    if (!result.isError) await timeline.refetch();
  }
  async function login() {
    if (!session) return;
    setOpeningLogin(true); setLoginError(false); rememberOAuthReturnPath();
    try { await signIn(session.did); } catch { setOpeningLogin(false); setLoginError(true); }
  }
  if (error) return <div role="alert" className="mx-auto flex max-w-2xl flex-col items-start gap-3 p-6">
    <h2 className="text-lg font-semibold">Profile Content Unavailable</h2><p className="text-sm text-muted-foreground">{error}</p>
    {error === SCOPE_RECOVERY_MESSAGE ? <Button disabled={openingLogin} onClick={() => { void login(); }}>{openingLogin ? "Opening Login…" : "Log In Again"}</Button> : <Button variant="outline" onClick={() => { void retry(); }}>Retry</Button>}
    {loginError ? <p>Login could not be opened. Please try again.</p> : null}
  </div>;
  if (catalog.isPending || timeline.isPending) return <SocialTimelineSkeleton />;
  return <div className="mx-auto flex max-w-2xl flex-col gap-4 p-3 sm:p-4">
    {moderation ? posts.map(item => <InteractiveSocialPost key={socialPostIdentity(item)} item={item} moderation={moderation} />) : null}
    {!posts.length ? <p className="py-10 text-center text-sm text-muted-foreground">No {section.charAt(0).toUpperCase() + section.slice(1)} to Show</p> : null}
    {timeline.hasNextPage ? <Button variant="outline" disabled={timeline.isFetchingNextPage} onClick={() => { void timeline.fetchNextPage(); }}>{timeline.isFetchingNextPage ? "Loading…" : "Load More"}</Button> : null}
  </div>;
}
