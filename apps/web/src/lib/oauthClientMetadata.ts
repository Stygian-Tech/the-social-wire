import { AT_PROTO_OAUTH_SCOPES } from "@/lib/atprotoOAuthScopes";

/** Discoverable ATProto OAuth client metadata for the web SPA at a given origin. */
export function buildWebOAuthClientMetadata(origin: string) {
  const base = origin.replace(/\/$/, "");
  return {
    client_id: `${base}/client-metadata.json`,
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
