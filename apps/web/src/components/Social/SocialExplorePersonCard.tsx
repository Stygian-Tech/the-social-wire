"use client";

import { useEffect, useRef } from "react";
import Link from "next/link";
import { moderateProfile, type AppBskyActorDefs, type ModerationOpts } from "@atproto/api";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { Avatar } from "@/components/shared/Avatar";
import { Button } from "@/components/ui/button";
import { useSocialWorkspaceSession } from "@/hooks/useSocialWorkspace";
import { createOAuthAgent } from "@/lib/atprotoClient";
import { socialErrorMessage } from "@/lib/blueskySocialClient";
import { SCOPE_RECOVERY_MESSAGE } from "@/lib/oauthScopeRecovery";
import { socialProfilePageHref } from "@/lib/socialProfileNavigation";
import { SocialPermissionRecovery } from "./SocialPermissionRecovery";
import { socialHttpsUrl } from "./socialUrls";
import { SocialProfileLink } from "./SocialProfileLink";

export function SocialExplorePersonCard({ actor, moderation, returnTo, descriptionBelow = false }: { actor: AppBskyActorDefs.ProfileView; moderation: ModerationOpts; returnTo: string; descriptionBelow?: boolean }) {
  const { did, sequence, requireSession } = useSocialWorkspaceSession();
  const cache = useQueryClient();
  const currentDid = useRef(did);
  const busy = useRef(false);
  useEffect(() => { currentDid.current = did; }, [did]);
  const key = ["blueskySocial", did, "following", sequence, actor.did] as const;
  const following = useQuery({ queryKey: key, initialData: actor.viewer?.following ?? "", queryFn: () => actor.viewer?.following ?? "", enabled: false });
  const allowed = !!did && did !== actor.did && moderation.userDid === did && !actor.viewer?.blocking && !actor.viewer?.blockedBy;
  const follow = useMutation({
    mutationFn: async (viewerDid: string) => {
      const session = requireSession();
      if (session.did !== viewerDid || currentDid.current !== viewerDid || moderation.userDid !== viewerDid || !allowed) throw new Error("Your account changed. Please reload this page.");
      const result = await createOAuthAgent(session).follow(actor.did);
      if (!result.uri.startsWith(`at://${viewerDid}/app.bsky.graph.follow/`)) throw new Error("This follow returned an invalid record reference.");
      return result.uri;
    },
    onSuccess: (uri, viewerDid) => {
      if (currentDid.current !== viewerDid) return;
      let session;
      try { session = requireSession(); } catch { return; }
      if (session.did !== viewerDid) return;
      cache.setQueryData(key, uri);
      void cache.invalidateQueries({ predicate: query => query.queryKey[0] === "blueskySocial" && query.queryKey[1] === viewerDid && ["explore", "profile", "timeline", "catalog"].includes(String(query.queryKey[2])) });
    },
    onSettled: () => { busy.current = false; },
  });
  const error = follow.variables === did && follow.error ? socialErrorMessage(follow.error) : undefined;
  const avatarHidden = moderateProfile(actor, moderation).ui("avatar").blur;
  const identity = <><Avatar src={avatarHidden ? undefined : socialHttpsUrl(actor.avatar)} alt="" size={40} /><div className="min-w-0 flex-1"><p className="break-words font-semibold">{actor.displayName || actor.handle}</p><p className="break-all text-sm text-muted-foreground">@{actor.handle}</p>{actor.description && !descriptionBelow ? <p className="mt-2 whitespace-pre-wrap break-words text-sm">{actor.description}</p> : null}</div></>;
  return <article className="rounded-2xl border bg-card p-4">
    <div className="flex flex-wrap items-start gap-3">
      {descriptionBelow ? <Link href={socialProfilePageHref(actor.did, returnTo)} className="flex min-w-0 flex-1 items-start gap-3">{identity}</Link> : <SocialProfileLink actor={actor.did} returnTo={returnTo} className="flex min-w-0 flex-1 items-start gap-3">{identity}</SocialProfileLink>}
      {allowed ? <Button variant="outline" className="shrink-0" aria-label={`${following.data ? "Following" : "Follow"} @${actor.handle}`} disabled={!!following.data || follow.isPending} onClick={() => {
        if (busy.current || following.data) return;
        busy.current = true;
        follow.mutate(did);
      }}>{follow.isPending ? "Following…" : following.data ? "Following" : "Follow"}</Button> : null}
    </div>
    {descriptionBelow && actor.description ? <p className="mt-3 whitespace-pre-wrap break-words text-sm [overflow-wrap:anywhere]">{actor.description}</p> : null}
    {error ? <p role="alert" className="mt-2 text-sm text-destructive">{error}</p> : null}
    {error === SCOPE_RECOVERY_MESSAGE ? <SocialPermissionRecovery /> : null}
  </article>;
}
