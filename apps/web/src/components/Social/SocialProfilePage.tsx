"use client";

import { useRouter, useSearchParams } from "next/navigation";
import { moderateProfile } from "@atproto/api";
import { ArrowLeft } from "lucide-react";
import { FeedHeader } from "@/components/FeedHeader/FeedHeader";
import { ProfileHeader } from "@/components/Account/ProfileHeader";
import { ProfileContent } from "@/components/Account/ProfileContent";
import { Button } from "@/components/ui/button";
import { useAuth } from "@/hooks/useAuth";
import { useBlueskySocialCatalog } from "@/hooks/useBlueskySocialCatalog";
import { useBlueskyProfile } from "@/hooks/useBlueskyProfile";
import { isSocialProfileActor } from "@/lib/socialProfileNavigation";
import { safeSocialPostReturnPath } from "@/lib/socialPostNavigation";
import { socialErrorMessage } from "@/lib/blueskySocialClient";
import { SCOPE_RECOVERY_MESSAGE } from "@/lib/oauthScopeRecovery";
import { SocialPermissionRecovery } from "./SocialPermissionRecovery";

export function SocialProfilePage() {
  const { session } = useAuth();
  const params = useSearchParams();
  return <ProfileViewer key={`${session?.did}:${params?.get("actor")}`} actor={params?.get("actor")} returnTo={params?.get("returnTo")} />;
}

function ProfileViewer({ actor, returnTo }: { actor?: string | null; returnTo?: string | null }) {
  const router = useRouter();
  const { session } = useAuth();
  const catalog = useBlueskySocialCatalog();
  const moderation = !catalog.isError && catalog.data?.moderation.userDid === session?.did ? catalog.data?.moderation : undefined;
  const profile = useBlueskyProfile(actor, moderation);
  const value = !profile.isError && moderation ? profile.data : undefined;
  const decision = value && moderation ? moderateProfile(value, moderation) : undefined;
  const list = decision?.ui("profileList");
  const content = decision?.ui("contentView");
  const withheld = [list, content].some(ui => ui?.filter || ui?.blur || ui?.noOverride);
  const identity = decision?.ui("displayName");
  const avatar = decision?.ui("avatar");
  const media = decision?.ui("contentMedia");
  const blocked = (ui: typeof avatar) => !!ui && (ui.filter || ui.blur || ui.noOverride);
  const error = catalog.isError ? socialErrorMessage(catalog.error) : profile.isError ? socialErrorMessage(profile.error) : undefined;
  const retry = () => { if (catalog.isError) void catalog.refetch(); else void profile.refetch(); };
  const origin = safeSocialPostReturnPath(returnTo);
  return <div className="flex min-h-0 min-w-0 flex-1 flex-col">
    <FeedHeader title="Profile" leading={<Button variant="ghost" size="icon" aria-label="Back" title="Back" onClick={() => router.replace(origin.startsWith("/social/profile") ? "/social" : origin)}><ArrowLeft aria-hidden="true" /></Button>} />
    <div className="min-h-0 flex-1 overflow-y-auto overscroll-y-contain">
      {!isSocialProfileActor(actor) ? <p role="alert" className="p-6">This profile link is invalid.</p> : error ? <div role="alert" className="flex flex-col items-start gap-3 p-6"><p>{error}</p>{error === SCOPE_RECOVERY_MESSAGE ? <SocialPermissionRecovery /> : <Button variant="outline" onClick={retry}>Retry</Button>}</div> : !moderation || profile.isPending ? <p role="status" className="p-6">Loading profile…</p> : withheld ? <p className="p-6">Profile withheld by your moderation settings.</p> : value ? <>
        <ProfileHeader viewer={{ ...value, displayName: blocked(identity) ? "Account" : value.displayName, handle: blocked(identity) ? undefined : value.handle, description: blocked(identity) ? undefined : value.description, avatar: blocked(avatar) ? undefined : value.avatar, banner: blocked(media) ? undefined : value.banner }} onRetry={retry} />
        <ProfileContent actor={value.did} own={value.did === session?.did} />
      </> : <p className="p-6">This profile is unavailable.</p>}
    </div>
  </div>;
}
