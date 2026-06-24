import { isLatrGatewayInvalidClientCredentialResponse } from "@/lib/latrGatewayCredentials";

export const SOCIALWIRE_TESTING_OAUTH_CLIENT_ID =
  "https://api.testing.thesocialwire.app/oauth-client-metadata.json";

export const SOCIALWIRE_PROD_OAUTH_CLIENT_ID =
  "https://api.thesocialwire.app/oauth-client-metadata.json";

export function latrGatewayErrorMessage(
  status: number,
  body: { error?: string; message?: string }
): string {
  const presentation = latrGatewayErrorPresentation(status, body);
  if (presentation.detail) {
    return `${presentation.headline} ${presentation.detail}`;
  }
  return presentation.headline;
}

export type LatrGatewayErrorPresentation = {
  headline: string;
  detail?: string;
};

export function latrGatewayErrorPresentation(
  status: number,
  body: { error?: string; message?: string }
): LatrGatewayErrorPresentation {
  const code = body.error?.trim();
  const message = body.message?.trim();

  if (isLatrGatewayInvalidClientCredentialResponse(status, body)) {
    return {
      headline: "L@tr gateway rejected the server app credential.",
      detail:
        "On Vercel, set LATR_GATEWAY_CLIENT_CREDENTIAL (or matching LATR_GATEWAY_CLIENT_ID + LATR_GATEWAY_API_KEY) for api.testing.latr.link.",
    };
  }

  if (status === 403 && code === "client_forbidden") {
    return {
      headline: "L@tr gateway blocked this sign-in.",
      detail:
        "Allowlist Social Wire's OAuth client on the matching api.*.latr.link gateway (OAUTH_GATEWAY_ALLOWED_CLIENT_IDS).",
    };
  }

  if (status === 403 && code === "pds_forbidden") {
    if (message) {
      return { headline: message };
    }
    return {
      headline: "PDS rejected the L@tr write.",
      detail:
        "Confirm OAuth scopes include link.latr.saved.* (and legacy com.latr.saved.* during migration), then sign out and back in.",
    };
  }

  if (status === 401 && code === "pds_unauthorized") {
    return {
      headline: message ?? "PDS write authorization failed.",
      detail: "Retry the action; if it persists, sign out and back in.",
    };
  }

  if (status === 401 && code === "missing_auth") {
    return {
      headline: message ?? "Missing Authorization header for the L@tr gateway.",
    };
  }

  const fallback = message ?? code ?? `Gateway error (${status})`;
  return { headline: fallback };
}

/** Split a thrown gateway error into a short headline and optional detail for narrow columns. */
export function latrGatewayErrorForDisplay(
  error: unknown,
  fallbackTitle = "Something went wrong"
): LatrGatewayErrorPresentation {
  if (!(error instanceof Error)) {
    return { headline: fallbackTitle };
  }

  const text = error.message.trim();
  if (!text) return { headline: fallbackTitle };

  if (text.startsWith("L@tr gateway blocked this sign-in.")) {
    return latrGatewayErrorPresentation(403, { error: "client_forbidden" });
  }
  if (text.startsWith("L@tr gateway rejected the server app credential.")) {
    return latrGatewayErrorPresentation(403, {
      error: "invalid_client_credential",
      message: "Invalid gateway client credentials",
    });
  }

  const sentenceBreak = text.search(/(?<=[.!?])\s+/);
  if (sentenceBreak > 0 && sentenceBreak < 120) {
    return {
      headline: text.slice(0, sentenceBreak).trim(),
      detail: text.slice(sentenceBreak).trim(),
    };
  }

  if (text.length > 140) {
    return {
      headline: `${text.slice(0, 137).trim()}…`,
      detail: text,
    };
  }

  return { headline: text };
}
