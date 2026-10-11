"use client";

import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { useAuth } from "@/hooks/useAuth";
import { changeSocialLabeler, getSocialLabeler, getSocialModerationSettings, type SocialLabelerChange } from "@/lib/socialModerationClient";
import { SCOPE_RECOVERY_MESSAGE } from "@/lib/oauthScopeRecovery";

export function useSocialModerationSettings() {
  const auth = useAuth();
  const client = useQueryClient();
  const did = auth.session?.did;
  const session = () => {
    const value = auth.getOAuthSession();
    if (!value) throw new Error(SCOPE_RECOVERY_MESSAGE);
    if (value.did !== did) throw new Error("Your account changed. Reload Settings.");
    return value;
  };
  const settings = useQuery({
    queryKey: ["blueskySocial", did ?? "", "moderationSettings", auth.oauthSessionReloadSeq],
    enabled: !!did,
    queryFn: ({ signal }) => getSocialModerationSettings(session(), signal),
    retry: false,
  });
  const lookup = useMutation({ mutationFn: (actor: string) => getSocialLabeler(session(), actor) });
  const change = useMutation({
    mutationFn: (value: SocialLabelerChange) => changeSocialLabeler(session(), value),
    onSuccess: async () => {
      if (auth.getOAuthSession()?.did !== did) return;
      const queryKey = ["blueskySocial", did ?? ""];
      await client.cancelQueries({ queryKey });
      // Reset removes previous safety definitions before active queries reload.
      await client.resetQueries({ queryKey });
    },
  });
  return { settings, lookup, change };
}
