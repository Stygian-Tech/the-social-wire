/**
 * ATProto OAuth client setup and session management.
 *
 * Uses @atproto/oauth-client-browser for PKCE + DPoP token flow.
 * - Access token: managed in memory by the OAuthSession
 * - Refresh token: managed by the oauth-client-browser library (IndexedDB)
 * - DPoP signing: handled automatically by OAuthSession.fetchHandler
 */

import { BrowserOAuthClient, OAuthSession } from "@atproto/oauth-client-browser";

/**
 * Resolve the ATProto OAuth client ID.
 *
 * ATProto OAuth loopback clients MUST use exactly `http://localhost` as the
 * client ID — no path, no port number.  Any other localhost URL (e.g.
 * `http://localhost:3000/client-metadata.json`) is rejected with
 * "Invalid loopback client ID: Value must not contain a path component".
 *
 * Priority:
 *  1. Local dev  (APP_ENV=local)  → always `http://localhost`
 *  2. Explicit env var             → use as-is (dev/prod hosted metadata)
 *  3. Default fallback             → production metadata URL
 */
function resolveClientId(): string {
  if (process.env.NEXT_PUBLIC_APP_ENV === "local") {
    return "http://localhost";
  }
  return (
    process.env.NEXT_PUBLIC_ATPROTO_CLIENT_ID ??
    "https://thesocialwire.app/client-metadata.json"
  );
}

// Promise-based singleton. BrowserOAuthClient.load() is the correct API —
// the constructor only accepts `clientMetadata`, not `clientId`. Passing
// `clientId` to the constructor is silently ignored and the client falls back
// to building a loopback metadata from window.location, which breaks on any
// non-root path. load() handles both loopback (http:) and discoverable
// (https:) client IDs correctly.
let _clientPromise: Promise<BrowserOAuthClient> | null = null;

/**
 * Returns the singleton ATProto OAuth client.
 * Safe to call concurrently — the load promise is shared across all callers.
 */
export async function getOAuthClient(): Promise<BrowserOAuthClient> {
  if (!_clientPromise) {
    _clientPromise = BrowserOAuthClient.load({
      clientId: resolveClientId(),
      handleResolver: "https://bsky.social",
    });
  }
  return _clientPromise;
}

/**
 * Initiates the ATProto OAuth PKCE flow for the given handle.
 * Redirects the browser to the user's PDS authorization endpoint.
 */
export async function signIn(handle: string): Promise<void> {
  const client = await getOAuthClient();
  await client.signInRedirect(handle, {
    scope: "atproto",
  });
  // Browser is redirected — execution stops here.
}

/**
 * Exchanges the OAuth callback parameters (from the current URL) for tokens.
 * Should be called from the /oauth/callback route.
 * Returns the resolved OAuthSession on success.
 */
export async function handleCallback(): Promise<OAuthSession> {
  const client = await getOAuthClient();
  const { session } = await client.initCallback(client.readCallbackParams());
  return session;
}

/**
 * Restores an existing session from storage, or returns null.
 */
export async function getSession(): Promise<OAuthSession | null> {
  const client = await getOAuthClient();
  try {
    const result = await client.init();
    if (!result) return null;
    // init() returns { session } when a session is available
    return result.session ?? null;
  } catch {
    return null;
  }
}

/**
 * Signs the user out and clears stored session data.
 */
export async function signOut(did: string): Promise<void> {
  const client = await getOAuthClient();
  await client.revoke(did);
}

/**
 * Creates a fetch function that wraps OAuthSession.fetchHandler so that
 * absolute URLs (e.g. Social Wire service calls) are signed with the
 * session's DPoP-bound access token.
 *
 * OAuthSession.fetchHandler uses `new URL(pathname, tokenSet.aud)` — when
 * `pathname` is already an absolute URL, the base is ignored, so this works
 * correctly for any service that accepts DPoP/Bearer tokens.
 */
export function createAuthFetch(
  session: OAuthSession
): (url: string, init?: RequestInit) => Promise<Response> {
  return (url, init) => session.fetchHandler(url, init);
}
