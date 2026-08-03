import { AT_PROTO_OAUTH_SCOPES } from "@/lib/atprotoOAuthScopes";

/**
 * Hosted OAuth `client_id` for a web origin. Railway serves the dynamic metadata
 * route from the web service itself, so discovery stays same-origin.
 */
export function hostedOAuthClientIdForOrigin(origin: string): string {
  return `${origin.replace(/\/$/, "")}/oauth-client-metadata.json`;
}

/**
 * Resolve hosted OAuth client_id in the browser.
 * An explicit client ID remains available for intentional nonstandard deployments.
 */
export function resolveHostedOAuthClientId(origin: string): string {
  const explicit = process.env.NEXT_PUBLIC_ATPROTO_CLIENT_ID?.trim();
  if (explicit) return explicit;
  return hostedOAuthClientIdForOrigin(origin);
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
