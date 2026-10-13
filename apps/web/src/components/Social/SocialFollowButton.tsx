"use client";

import { useEffect, useRef, type ComponentProps } from "react";
import type { AppBskyActorDefs, ModerationOpts } from "@atproto/api";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { Button } from "@/components/ui/button";
import { useSocialWorkspaceSession } from "@/hooks/useSocialWorkspace";
import { createOAuthAgent } from "@/lib/atprotoClient";
import { socialErrorMessage } from "@/lib/blueskySocialClient";
import { SCOPE_RECOVERY_MESSAGE } from "@/lib/oauthScopeRecovery";
import { SocialPermissionRecovery } from "./SocialPermissionRecovery";

export function SocialFollowButton({ actor, moderation, variant = "outline" }: { actor: Pick<AppBskyActorDefs.ProfileView, "did" | "handle" | "viewer">; moderation: ModerationOpts; variant?: ComponentProps<typeof Button>["variant"] }) {
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
  return <>
    {allowed ? <Button variant={following.data ? "outline" : variant} className="shrink-0" aria-label={`${following.data ? "Following" : "Follow"} ${actor.handle ? `@${actor.handle}` : "Account"}`} disabled={!!following.data || follow.isPending} onClick={() => {
      if (busy.current || following.data) return;
      busy.current = true;
      follow.mutate(did);
    }}>{follow.isPending ? "Following…" : following.data ? "Following" : "Follow"}</Button> : null}
    {error ? <p role="alert" className="w-full text-sm text-destructive">{error}</p> : null}
    {error === SCOPE_RECOVERY_MESSAGE ? <SocialPermissionRecovery /> : null}
  </>;
}
