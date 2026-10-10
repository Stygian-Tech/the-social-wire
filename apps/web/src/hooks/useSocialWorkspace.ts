"use client";
import { useAuth } from "@/hooks/useAuth";
import { SCOPE_RECOVERY_MESSAGE } from "@/lib/oauthScopeRecovery";
export function useSocialWorkspaceSession() {
  const { session, getOAuthSession, oauthSessionReloadSeq } = useAuth();
  return { did: session?.did ?? "", sequence: oauthSessionReloadSeq, requireSession: () => {
    const oauth = getOAuthSession();
    if (!oauth) throw new Error(SCOPE_RECOVERY_MESSAGE);
    if (oauth.did !== session?.did) throw new Error("Your account changed. Please reload this page.");
    return oauth;
  } };
}
