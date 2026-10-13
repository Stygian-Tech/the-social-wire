"use client";

import { moderateProfile } from "@atproto/api";
import { useSocialWorkspaceSession } from "@/hooks/useSocialWorkspace";
import { useBlueskyProfile } from "@/hooks/useBlueskyProfile";
import { useBlueskySocialCatalog } from "@/hooks/useBlueskySocialCatalog";
import { socialErrorMessage } from "@/lib/blueskySocialClient";
import { SCOPE_RECOVERY_MESSAGE } from "@/lib/oauthScopeRecovery";
import { Button } from "@/components/ui/button";
import { SocialExplorePersonCard } from "./SocialExplorePersonCard";
import { SocialPermissionRecovery } from "./SocialPermissionRecovery";

export function SocialMentionProfileCard({ actor }: { actor: string }) {
  const { did } = useSocialWorkspaceSession();
  const catalog = useBlueskySocialCatalog();
  const moderation = !catalog.isError && catalog.data?.moderation.userDid === did ? catalog.data.moderation : undefined;
  const profile = useBlueskyProfile(actor, moderation);
  const error = catalog.isError ? socialErrorMessage(catalog.error) : profile.isError ? socialErrorMessage(profile.error) : undefined;
  if (!did) return <p className="p-4 text-sm">Sign In To Preview Profiles.</p>;
  if (error) return <div className="flex flex-col items-start gap-3 p-4"><p role="alert" className="text-sm">{error}</p>{error === SCOPE_RECOVERY_MESSAGE ? <SocialPermissionRecovery /> : <Button variant="outline" size="sm" onClick={() => { if (catalog.isError) void catalog.refetch(); else void profile.refetch(); }}>Retry</Button>}</div>;
  if (!moderation || profile.isPending) return <p role="status" className="p-4 text-sm text-muted-foreground">Loading profile…</p>;
  if (!profile.data) return <p className="p-4 text-sm">This profile is unavailable.</p>;
  const decision = moderateProfile(profile.data, moderation);
  const withheld = [decision.ui("profileList"), decision.ui("contentView")].some(ui => ui.filter || ui.blur || ui.noOverride);
  if (withheld) return <p className="p-4 text-sm">Profile withheld by your moderation settings.</p>;
  const identity = decision.ui("displayName");
  const hideIdentity = identity.filter || identity.blur || identity.noOverride;
  const avatar = decision.ui("avatar");
  return <SocialExplorePersonCard actor={{ ...profile.data, $type: "app.bsky.actor.defs#profileView", ...(hideIdentity ? { displayName: "Account", handle: "", description: undefined } : {}), ...(avatar.filter || avatar.blur || avatar.noOverride ? { avatar: undefined } : {}) }} moderation={moderation} returnTo="/social" />;
}
