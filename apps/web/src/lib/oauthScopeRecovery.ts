import type { OAuthSession } from "@atproto/oauth-client-browser";
import { getAppEnv, isNonProd } from "@/lib/appEnv";

export const SCOPE_RECOVERY_MESSAGE = "Please log in again to update your account permissions, then retry this action.";
const listeners = new Set<(did: string) => void>();
const wrappedSessions = new WeakSet<OAuthSession>();
const RETURN_PATH_KEY = "the-social-wire.oauth-return-path.v1";

export function isMissingOAuthScope(error: unknown): boolean {
  if (typeof error === "string") return /missing required scope|insufficient_scope|invalid_scope/i.test(error);
  if (!error || typeof error !== "object") return false;
  const value = error as { message?: unknown; error?: unknown; code?: unknown };
  return [value.message, value.error, value.code].some(value => typeof value === "string" && isMissingOAuthScope(value));
}

export function onOAuthScopeRecovery(listener: (did: string) => void): () => void {
  listeners.add(listener);
  return () => { listeners.delete(listener); };
}

/** Observe every consumer of this session, including direct Agent/PDS writes. Never retry a mutation. */
export function observeOAuthScopeErrors(session: OAuthSession): OAuthSession {
  if (wrappedSessions.has(session)) return session;
  wrappedSessions.add(session);
  const fetchHandler = session.fetchHandler.bind(session);
  session.fetchHandler = async (url, init) => {
    try {
      const response = await fetchHandler(url, init);
      if (response.status >= 400 && response.status < 500) {
        const challenge = response.headers.get("WWW-Authenticate");
        const text = await response.clone().text().catch(() => "");
        let failure: unknown = text;
        try { failure = JSON.parse(text); } catch { /* Some PDS responses are plain text. */ }
        if (isMissingOAuthScope(challenge) || isMissingOAuthScope(failure)) {
          if (!isNonProd(getAppEnv())) {
            listeners.forEach(listener => listener(session.did));
            throw new Error(SCOPE_RECOVERY_MESSAGE);
          }
        }
      }
      return response;
    } catch (error) {
      if (!isNonProd(getAppEnv()) && isMissingOAuthScope(error)) {
        listeners.forEach(listener => listener(session.did));
        throw new Error(SCOPE_RECOVERY_MESSAGE);
      }
      throw error;
    }
  };
  return session;
}

export function rememberOAuthReturnPath(): void {
  try { window.sessionStorage.setItem(RETURN_PATH_KEY, window.location.pathname + window.location.search + window.location.hash); } catch { /* Storage may be unavailable. */ }
}

export function consumeOAuthReturnPath(): string {
  try {
    const path = window.sessionStorage.getItem(RETURN_PATH_KEY);
    window.sessionStorage.removeItem(RETURN_PATH_KEY);
    if (path?.startsWith("/") && !path.startsWith("//") && !path.includes("\\") && !/^\/(login|callback)(?:[/?#]|$)/.test(path)) return path;
  } catch { /* Use the default reader destination. */ }
  return "/read";
}
