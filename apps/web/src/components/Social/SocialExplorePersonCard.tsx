"use client";

import Link from "next/link";
import { moderateProfile, type AppBskyActorDefs, type ModerationOpts } from "@atproto/api";
import { Avatar } from "@/components/shared/Avatar";
import { socialProfilePageHref } from "@/lib/socialProfileNavigation";
import { socialHttpsUrl } from "./socialUrls";
import { SocialProfileLink } from "./SocialProfileLink";
import { SocialFollowButton } from "./SocialFollowButton";

export function SocialExplorePersonCard({ actor, moderation, returnTo, descriptionBelow = false }: { actor: AppBskyActorDefs.ProfileView; moderation: ModerationOpts; returnTo: string; descriptionBelow?: boolean }) {
  const avatarHidden = moderateProfile(actor, moderation).ui("avatar").blur;
  const identity = <><Avatar src={avatarHidden ? undefined : socialHttpsUrl(actor.avatar)} alt="" size={40} /><div className="min-w-0 flex-1"><p className="break-words font-semibold">{actor.displayName || actor.handle}</p><p className="break-all text-sm text-muted-foreground">@{actor.handle}</p>{actor.description && !descriptionBelow ? <p className="mt-2 whitespace-pre-wrap break-words text-sm">{actor.description}</p> : null}</div></>;
  return <article className="rounded-2xl border bg-card p-4">
    <div className="flex flex-wrap items-start gap-3">
      {descriptionBelow ? <Link href={socialProfilePageHref(actor.did, returnTo)} className="flex min-w-0 flex-1 items-start gap-3">{identity}</Link> : <SocialProfileLink actor={actor.did} returnTo={returnTo} className="flex min-w-0 flex-1 items-start gap-3">{identity}</SocialProfileLink>}
      <SocialFollowButton actor={actor} moderation={moderation} />
    </div>
    {descriptionBelow && actor.description ? <p className="mt-3 whitespace-pre-wrap break-words text-sm [overflow-wrap:anywhere]">{actor.description}</p> : null}
  </article>;
}
