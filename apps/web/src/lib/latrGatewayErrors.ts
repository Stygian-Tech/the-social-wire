import { isLatrGatewayInvalidClientCredentialResponse } from "@/lib/latrGatewayCredentials";

export const SOCIALWIRE_TESTING_OAUTH_CLIENT_ID =
  "https://api.testing.thesocialwire.app/oauth/client-metadata.json";

export const SOCIALWIRE_PROD_OAUTH_CLIENT_ID =
  "https://api.thesocialwire.app/oauth/client-metadata.json";

export function latrGatewayErrorMessage(
  status: number,
  body: { error?: string; message?: string }
): string {
  const code = body.error?.trim();
  const message = body.message?.trim();

  if (isLatrGatewayInvalidClientCredentialResponse(status, body)) {
    return (
      "L@tr gateway rejected the server app credential. On Vercel set " +
      "LATR_GATEWAY_CLIENT_CREDENTIAL to the `the-social-wire-web=…` value from " +
      "api.testing.latr.link Fly secrets (or a matching LATR_GATEWAY_CLIENT_ID + " +
      "LATR_GATEWAY_API_KEY pair issued for that gateway). Remove stale/wrong keys."
    );
  }

  if (status === 403 && code === "client_forbidden") {
    return (
      "Your Social Wire sign-in is not allowlisted on the L@tr gateway. The operator must add " +
      `${SOCIALWIRE_TESTING_OAUTH_CLIENT_ID} (testing) or ${SOCIALWIRE_PROD_OAUTH_CLIENT_ID} (prod) ` +
      "to OAUTH_GATEWAY_ALLOWED_CLIENT_IDS on the matching api.*.latr.link Fly app."
    );
  }

  if (status === 403 && code === "pds_forbidden") {
    return (
      message ??
      "PDS rejected the L@tr write. Confirm OAuth scopes include com.latr.saved.* and sign out/in after scope changes."
    );
  }

  if (status === 401 && code === "pds_unauthorized") {
    return (
      message ??
      "PDS write authorization failed. Retry the action; if it persists, sign out and back in."
    );
  }

  if (status === 401 && code === "missing_auth") {
    return message ?? "Missing Authorization header for the L@tr gateway.";
  }

  return message ?? code ?? `Gateway error (${status})`;
}
