export function buildOperationsOAuthClientMetadata(origin: string) {
  const normalizedOrigin = new URL(origin).origin
  const clientId = `${normalizedOrigin}/operations-client-metadata.json`

  return {
    client_id: clientId,
    application_type: "web",
    grant_types: ["authorization_code", "refresh_token"],
    response_types: ["code"],
    redirect_uris: [`${normalizedOrigin}/callback`],
    scope: "atproto",
    token_endpoint_auth_method: "none",
    dpop_bound_access_tokens: true,
    client_name: "The Social Wire Operations",
    client_uri: normalizedOrigin,
  }
}

export function operationsOAuthClientMetadataUrl(gatewayOrigin: string) {
  return `${new URL(gatewayOrigin).origin}/operations-oauth-client-metadata.json`
}
