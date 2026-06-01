/** Official gateway client id registered on latr-gateway Fly secrets. */
export const THE_SOCIAL_WIRE_WEB_CLIENT_ID = "the-social-wire-web";

const CLIENT_ID_PATTERN = /^[a-z0-9][a-z0-9.-]*$/i;

/** Parse `client-id=base64` map entries from latr-gateway env strings. */
export function parseOfficialClientCredentialsMap(
  value: string
): Record<string, string> {
  const credentials: Record<string, string> = {};
  for (const token of value.split(/[,;]/)) {
    const trimmed = token.trim();
    if (!trimmed) continue;
    const separator = trimmed.search(/[=:]/);
    if (separator < 0) continue;
    const clientId = trimmed.slice(0, separator).trim();
    const credential = trimmed.slice(separator + 1).trim();
    if (!clientId || !credential) continue;
    credentials[clientId] = credential;
  }
  return credentials;
}

/**
 * Normalize server env to the raw base64 credential sent as `X-Latr-Official-Client`.
 * Accepts bare base64 or `the-social-wire-web=…` / full comma-separated maps copied
 * from `LATR_GATEWAY_OFFICIAL_CLIENT_CREDENTIALS`.
 */
export function normalizeLatrGatewayOfficialCredential(
  raw: string | undefined
): string | undefined {
  const trimmed = raw?.trim();
  if (!trimmed) return undefined;

  if (trimmed.includes(",") || trimmed.includes(";")) {
    const map = parseOfficialClientCredentialsMap(trimmed);
    if (map[THE_SOCIAL_WIRE_WEB_CLIENT_ID]) {
      return map[THE_SOCIAL_WIRE_WEB_CLIENT_ID];
    }
    const entries = Object.entries(map);
    return entries.length === 1 ? entries[0][1] : undefined;
  }

  const separator = trimmed.search(/[=:]/);
  if (separator > 0) {
    const clientId = trimmed.slice(0, separator).trim();
    const credential = trimmed.slice(separator + 1).trim();
    if (
      credential &&
      CLIENT_ID_PATTERN.test(clientId) &&
      clientId.includes("-")
    ) {
      return credential;
    }
  }

  return trimmed;
}
