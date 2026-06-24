import { AT_PROTO_OAUTH_SCOPES } from "@/lib/atprotoOAuthScopes";

/** Public gateway URL for hosted dev OAuth when the web SPA is deployment-protected. */
export function inferGatewayApiBase(origin?: string): string | null {
  if (origin) {
    try {
      const { hostname } = new URL(origin);
      if (hostname === "testing.thesocialwire.app") {
        return "https://api.testing.thesocialwire.app";
      }
    } catch {
      //
    }
  }
  return null;
}

export function gatewayWebOAuthClientMetadataUrl(apiBase: string): string {
  return `${apiBase.replace(/\/$/, "")}/oauth-client-metadata.json`;
}

/**
 * Hosted OAuth `client_id` for a web origin.
 * Uses the public API gateway when the SPA host is deployment-protected (e.g. testing.thesocialwire.app).
 */
export function hostedOAuthClientIdForOrigin(origin: string): string {
  const gateway = inferGatewayApiBase(origin);
  if (gateway) {
    return gatewayWebOAuthClientMetadataUrl(gateway);
  }
  return `${origin.replace(/\/$/, "")}/oauth-client-metadata.json`;
}

/** True when the origin must use public gateway metadata (not same-origin SPA JSON). */
export function originUsesGatewayOAuthClientMetadata(origin: string): boolean {
  const base = origin.replace(/\/$/, "");
  return hostedOAuthClientIdForOrigin(origin) !== `${base}/oauth-client-metadata.json`;
}

/**
 * Resolve hosted OAuth client_id in the browser.
 * Gateway client_id wins over `NEXT_PUBLIC_ATPROTO_CLIENT_ID` when the SPA host is
 * deployment-protected (e.g. testing.thesocialwire.app behind Vercel auth).
 */
export function resolveHostedOAuthClientId(origin: string): string {
  const fromOrigin = hostedOAuthClientIdForOrigin(origin);
  if (originUsesGatewayOAuthClientMetadata(origin)) {
    return fromOrigin;
  }
  const explicit = process.env.NEXT_PUBLIC_ATPROTO_CLIENT_ID?.trim();
  if (explicit) return explicit;
  return fromOrigin;
}

/** Discoverable ATProto OAuth client metadata for the web SPA at a given origin. */
export function buildWebOAuthClientMetadata(origin: string) {
  const base = origin.replace(/\/$/, "");
  return {
    client_id: `${base}/oauth-client-metadata.json`,
    application_type: "web",
    grant_types: ["authorization_code", "refresh_token"],
    response_types: ["code"],
    redirect_uris: [`${base}/callback`],
    scope: AT_PROTO_OAUTH_SCOPES,
    token_endpoint_auth_method: "none",
    dpop_bound_access_tokens: true,
    client_name: "The Social Wire",
    client_uri: base,
  } as const;
}
