/**
 * ATProto OAuth client setup and session management.
 *
 * Uses @atproto/oauth-client-browser for PKCE + DPoP token flow.
 * - Access token: managed in memory by the OAuthSession
 * - Refresh token: managed by the oauth-client-browser library (IndexedDB)
 * - DPoP signing: handled automatically by OAuthSession.fetchHandler
 */

import { BrowserOAuthClient, OAuthSession } from "@atproto/oauth-client-browser";
import { buildAtprotoLoopbackClientId } from "@atproto/oauth-types";
import { BSKY_APPVIEW_PUBLIC } from "@/lib/atprotoClient";

/**
 * Space-separated ATProto OAuth scopes. Must stay in sync with
 * `public/client-metadata.json` (`scope`): authorization servers reject
 * undeclared scopes.
 *
 * `atproto` is required by the ATProto OAuth profile. Repository writes for
 * Social Wire lexicons need explicit `repo:` permissions; use one scope per
 * collection with combined `action=` params (permission string syntax).
 *
 * **Re-login required after deploy:** widening scopes does not upgrade existing
 * access tokens; users must sign out and sign in again.
 */
export const AT_PROTO_OAUTH_SCOPES = [
  "atproto",
  "repo:com.thesocialwire.folder?action=create&action=update&action=delete",
  "repo:com.thesocialwire.publicationPrefs?action=create&action=update&action=delete",
  "repo:com.thesocialwire.preferences?action=create&action=update&action=delete",
  "repo:com.thesocialwire.entryReadState?action=create&action=update&action=delete",
  "repo:com.latr.saved.external?action=create&action=update&action=delete",
  "repo:com.latr.saved.item?action=create&action=update&action=delete",
  "repo:site.standard.graph.subscription?action=create&action=update&action=delete",
  "repo:app.skyreader.feed.subscription?action=create&action=update&action=delete",
].join(" ");

/**
 * Prefer IP loopback redirects (RFC 8252); `oauth-client-browser` may redirect the
 * page from hostname `localhost` to `127.0.0.1` after load so IndexedDB aligns.
 */
export const ATPROTO_LOOPBACK_CALLBACK_PATH =
  process.env.NEXT_PUBLIC_ATPROTO_LOOPBACK_CALLBACK_PATH ?? "/callback";

function normalizeLoopbackPath(pathSpec: string): string {
  if (!pathSpec.startsWith("/")) {
    return `/${pathSpec}`;
  }
  return pathSpec;
}

/** True when restoring OAuth via `pathname` — never call `oauthClient.init()` here (avoid racing `/callback`). */
export function pathnameIsOAuthCallbackRoute(pathname: string): boolean {
  return (
    normalizeLoopbackPath(pathname) === normalizeLoopbackPath(ATPROTO_LOOPBACK_CALLBACK_PATH)
  );
}

function isLoopbackHostname(hostname: string): boolean {
  return (
    hostname === "localhost" ||
    hostname === "127.0.0.1" ||
    hostname === "::1" ||
    hostname === "[::1]"
  );
}

function isLoopbackIpHostname(hostname: string): boolean {
  return hostname === "127.0.0.1" || hostname === "[::1]";
}

/**
 * Local loopback OAuth redirects must land on an IP host, and browser storage is
 * origin-scoped. If sign-in starts from `localhost`, the callback on `127.0.0.1`
 * cannot read the stored OAuth state, so move the app before creating state.
 */
export function localOAuthCanonicalHref(
  currentHref: string,
  clientId: string,
  redirectUris: readonly string[]
): string | null {
  if (!clientId.startsWith("http://localhost")) return null;

  const current = new URL(currentHref);
  if (current.hostname !== "localhost") return null;

  for (const redirectUri of redirectUris) {
    const redirect = new URL(redirectUri);
    if (!isLoopbackIpHostname(redirect.hostname)) continue;
    if (redirect.protocol !== current.protocol) continue;
    if (redirect.port && redirect.port !== current.port) continue;

    current.hostname = redirect.hostname;
    if (redirect.port) current.port = redirect.port;
    return current.href;
  }

  return null;
}

/** Enable parameterized OAuth loopback (`http://localhost?redirect_uri=…`) for Next dev machines. */
function shouldUseParameterizedLoopbackClientId(): boolean {
  const explicit = process.env.NEXT_PUBLIC_ATPROTO_LOOPBACK_FORCE;
  if (explicit === "0" || explicit === "false") return false;

  const appEnv = process.env.NEXT_PUBLIC_APP_ENV;
  if (appEnv === "local") return true;
  if (!appEnv && process.env.NODE_ENV === "development") return true;

  const force = explicit === "1" || explicit === "true";
  return force && appEnv !== "prod" && appEnv !== "production";
}

function isLocalOAuthMode(): boolean {
  if (shouldUseParameterizedLoopbackClientId()) return true;
  return (
    typeof window !== "undefined" &&
    isLoopbackHostname(window.location.hostname)
  );
}

function buildDefaultLocalCallbackUrl(): string {
  const url = new URL(window.location.href);
  if (url.hostname === "localhost") {
    url.hostname = "127.0.0.1";
  }
  url.pathname = normalizeLoopbackPath(ATPROTO_LOOPBACK_CALLBACK_PATH);
  url.search = "";
  url.hash = "";
  return url.toString();
}

function resolveOAuthResponseMode(): "fragment" | "query" {
  const explicit = process.env.NEXT_PUBLIC_OAUTH_RESPONSE_MODE;
  if (explicit === "fragment" || explicit === "query") return explicit;
  return isLocalOAuthMode() ? "query" : "fragment";
}

export function readOAuthCallbackParamsFromWindow(): URLSearchParams | null {
  if (typeof window === "undefined") return null;

  const fromHash = new URLSearchParams(window.location.hash.slice(1));
  if (
    fromHash.has("state") &&
    (fromHash.has("code") || fromHash.has("error"))
  ) {
    return fromHash;
  }

  const fromSearch = new URLSearchParams(window.location.search);
  if (
    fromSearch.has("state") &&
    (fromSearch.has("code") || fromSearch.has("error"))
  ) {
    return fromSearch;
  }

  return null;
}

export function hasPendingOAuthBrowserCallback(): boolean {
  return readOAuthCallbackParamsFromWindow() != null;
}

export function localLoopbackCanonicalHref(currentHref: string): string | null {
  const current = new URL(currentHref);
  if (current.hostname !== "localhost") return null;

  current.hostname = "127.0.0.1";
  return current.href;
}

/**
 * Resolve the ATProto OAuth client ID.
 *
 * **Loopback (local OAuth to your real PDS):** when `NEXT_PUBLIC_APP_ENV === "local"`,
 * or when APP_ENV is **unset during `next dev`**, builds a parameterized `http://localhost?…`
 * client ID embedding `redirect_uri=http://127.0.0.1:<port>/callback` (+ IPv6 twin) so the
 * port and path match the dev server (`@atproto/oauth-client-browser` rejects bare ports
 * for the default `"http://localhost"` ID alone).
 *
 * **Hosted OAuth:** otherwise use `NEXT_PUBLIC_ATPROTO_CLIENT_ID` or Social Wire prod metadata URL.
 *
 * **Disabling loopback overrides:** `NEXT_PUBLIC_ATPROTO_LOOPBACK_FORCE=false` skips the parameterized client.
 */
function resolveClientId(): string {
  if (isLocalOAuthMode()) {
    if (typeof window === "undefined") {
      throw new Error("Local OAuth client ID resolution is browser-only.");
    }

    const explicitRedirect = process.env.NEXT_PUBLIC_LOCAL_REDIRECT_URI?.trim();
    return buildAtprotoLoopbackClientId({
      redirect_uris: explicitRedirect
        ? [explicitRedirect]
        : [buildDefaultLocalCallbackUrl()],
      scope: AT_PROTO_OAUTH_SCOPES,
    });
  }
  return (
    process.env.NEXT_PUBLIC_ATPROTO_CLIENT_ID ??
    "https://thesocialwire.app/client-metadata.json"
  );
}

let _clientPromise: Promise<BrowserOAuthClient> | null = null;

const ATPRO_BROWSER_OAUTH_SUB_STORAGE_KEY = "@@atproto/oauth-client-browser(sub)";
const OAUTH_CLIENT_LOAD_TIMEOUT_MS = 10_000;
export const OAUTH_CALLBACK_TIMEOUT_MS = 20_000;
const SESSION_RESTORE_TIMEOUT_MS = 8_000;
const OAUTH_FETCH_DEADLINE_MS = 90_000;

async function raceWithTimeout<T>(
  promise: Promise<T>,
  ms: number,
  label: string
): Promise<T> {
  let timeoutId: ReturnType<typeof setTimeout>;
  const timeoutPromise = new Promise<never>((_, reject) => {
    timeoutId = setTimeout(() => {
      reject(new Error(`${label} timed out after ${ms}ms`));
    }, ms);
  });

  try {
    return await Promise.race([promise, timeoutPromise]);
  } finally {
    clearTimeout(timeoutId!);
  }
}

function createFetchWithDeadline(
  timeoutMs: number,
  base: typeof fetch = fetch
): typeof fetch {
  const wrapped = (input: RequestInfo | URL, init?: RequestInit) => {
    const controller = new AbortController();
    const timer = globalThis.setTimeout(() => controller.abort(), timeoutMs);
    const incoming = init?.signal;
    if (incoming) {
      if (incoming.aborted) {
        globalThis.clearTimeout(timer);
        return Promise.reject(incoming.reason);
      }
      incoming.addEventListener(
        "abort",
        () => {
          globalThis.clearTimeout(timer);
          controller.abort(incoming.reason);
        },
        { once: true }
      );
    }
    const signal =
      typeof AbortSignal !== "undefined" && "any" in AbortSignal
        ? AbortSignal.any(incoming ? [controller.signal, incoming] : [controller.signal])
        : controller.signal;
    return base(input, { ...init, signal }).finally(() => {
      globalThis.clearTimeout(timer);
    });
  };

  return Object.assign(wrapped, { preconnect: base.preconnect }) as typeof fetch;
}

function maybeClearStaleOAuthRoutingHint(err: unknown): void {
  if (!(err instanceof Error)) return;
  if (!err.message.includes("timed out")) return;
  /** `oauth-client-browser` persists `sub` so `restore()` retries; timeouts often mean wedge on refresh. */
  try {
    localStorage.removeItem(ATPRO_BROWSER_OAUTH_SUB_STORAGE_KEY);
  } catch {
    //
  }
}

export function getStoredOAuthDid(): string | null {
  try {
    return localStorage.getItem(ATPRO_BROWSER_OAUTH_SUB_STORAGE_KEY);
  } catch {
    return null;
  }
}

// Promise-based singleton. BrowserOAuthClient.load() is the correct API —
// the constructor only accepts `clientMetadata`, not `clientId`. Passing
// `clientId` to the constructor is silently ignored and the client falls back
// to building a loopback metadata from window.location, which breaks on any
// non-root path. load() handles both loopback (http:) and discoverable
// (https:) client IDs correctly.

/**
 * Returns the singleton ATProto OAuth client.
 * Safe to call concurrently — the load promise is shared across all callers.
 */
export async function getOAuthClient(): Promise<BrowserOAuthClient> {
  if (typeof window === "undefined") {
    throw new Error("getOAuthClient is browser-only");
  }
  if (!_clientPromise) {
    const load = BrowserOAuthClient.load({
      clientId: resolveClientId(),
      handleResolver: BSKY_APPVIEW_PUBLIC,
      fetch: createFetchWithDeadline(OAUTH_FETCH_DEADLINE_MS),
      responseMode: resolveOAuthResponseMode(),
    });
    _clientPromise = raceWithTimeout(
      load,
      OAUTH_CLIENT_LOAD_TIMEOUT_MS,
      "OAuth client load"
    ).catch((err) => {
      _clientPromise = null;
      throw err;
    });
  }
  return _clientPromise;
}

export async function redirectToCanonicalLocalOAuthOrigin(): Promise<boolean> {
  if (typeof window === "undefined") return false;

  const client = await getOAuthClient();
  const canonicalHref = localOAuthCanonicalHref(
    window.location.href,
    client.clientMetadata.client_id,
    client.clientMetadata.redirect_uris
  );

  if (!canonicalHref) return false;

  window.location.replace(canonicalHref);
  return true;
}

/**
 * Initiates the ATProto OAuth PKCE flow for the given handle.
 * Redirects the browser to the user's PDS authorization endpoint.
 */
export async function signIn(handle: string): Promise<void> {
  if (typeof window !== "undefined") {
    const canonicalHref = localLoopbackCanonicalHref(window.location.href);
    if (canonicalHref) {
      window.location.replace(canonicalHref);
      return new Promise(() => {
        // The browser is navigating to the canonical loopback origin.
      });
    }
  }

  const client = await getOAuthClient();
  await client.signInRedirect(handle, {
    scope: AT_PROTO_OAUTH_SCOPES,
  });
  // Browser is redirected — execution stops here.
}

/**
 * Exchanges the OAuth callback parameters (from the current URL) for tokens.
 * Should be called from the `/callback` route (`src/app/(auth)/callback/page.tsx`).
 * Returns the resolved OAuthSession on success.
 */
let handleCallbackInflight: Promise<OAuthSession> | null = null;

export async function handleCallback(): Promise<OAuthSession> {
  if (handleCallbackInflight) return handleCallbackInflight;

  handleCallbackInflight = (async () => {
    const params = readOAuthCallbackParamsFromWindow();
    if (!params) {
      throw new TypeError(
        "No OAuth authorization response in URL (missing state/code in query or fragment)."
      );
    }

    const work = (async () => {
      _clientPromise = null;
      const client = await getOAuthClient();
      const redirectUri =
        client.findRedirectUrl() ??
        process.env.NEXT_PUBLIC_LOCAL_REDIRECT_URI?.trim() ??
        buildDefaultLocalCallbackUrl();
      const { session } = await client.initCallback(
        params,
        redirectUri as Parameters<BrowserOAuthClient["initCallback"]>[1]
      );
      return session;
    })();

    return await raceWithTimeout(
      work,
      OAUTH_CALLBACK_TIMEOUT_MS,
      "OAuth callback"
    );
  })();

  try {
    return await handleCallbackInflight;
  } finally {
    handleCallbackInflight = null;
  }
}

/**
 * Restores an existing session from storage, or returns null.
 */
export async function getSession(): Promise<OAuthSession | null> {
  const restore = (async () => {
    try {
      if (hasPendingOAuthBrowserCallback()) return null;

      const client = await getOAuthClient();
      const result = await client.initRestore();
      if (!result) return null;
      return result.session ?? null;
    } catch (err) {
      maybeClearStaleOAuthRoutingHint(err);
      return null;
    }
  })();

  return Promise.race([
    restore,
    new Promise<null>((resolve) =>
      setTimeout(() => resolve(null), SESSION_RESTORE_TIMEOUT_MS)
    ),
  ]);
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
