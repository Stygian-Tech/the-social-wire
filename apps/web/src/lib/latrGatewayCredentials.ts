/** After a 403/503 from the L@tr gateway proxy, skip enrichment calls this session. */
let authRejected = false;

export function isLatrGatewayAuthRejected(): boolean {
  return authRejected;
}

export function markLatrGatewayAuthRejected(): void {
  authRejected = true;
}

export function resetLatrGatewayAuthRejectedForTests(): void {
  authRejected = false;
}

export function isLatrGatewayInvalidClientCredentialResponse(
  status: number,
  body: { error?: string; message?: string }
): boolean {
  if (status !== 403 && status !== 503) return false;
  const code = body.error?.trim().toLowerCase();
  const message = body.message?.trim().toLowerCase() ?? "";
  return (
    code === "invalid_client_credential" ||
    code === "missing_client_credential" ||
    message.includes("invalid gateway client credentials") ||
    message.includes("latr_gateway_client_id")
  );
}

export function latrGatewayCredentialsHelpText(): string {
  return (
    "L@tr gateway credentials must be configured on the web server " +
    "(LATR_GATEWAY_CLIENT_ID + LATR_GATEWAY_API_KEY, or LATR_GATEWAY_CLIENT_CREDENTIAL). " +
    "Contact the site operator if save/archive actions fail."
  );
}
