import { isMissingOAuthScope, SCOPE_RECOVERY_MESSAGE } from "@/lib/oauthScopeRecovery";

export function livePostErrorMessage(error: unknown): string {
  if (isMissingOAuthScope(error) || error instanceof Error && error.message === SCOPE_RECOVERY_MESSAGE) return SCOPE_RECOVERY_MESSAGE;
  return error instanceof Error && error.message ? error.message : "The Live Post Could Not Be Saved. Please Retry.";
}
