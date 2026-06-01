import { buildDeveloperGatewayHeaders } from "latr-packages/gateway-client";

import { getAppEnv } from "@/lib/appEnv";
import { normalizeLatrGatewayOfficialCredential } from "@/lib/latrGatewayOfficialCredential";
import {
  DEFAULT_DEV_LATR_GATEWAY_URL,
  DEFAULT_PROD_LATR_GATEWAY_URL,
  DEFAULT_TEST_LATR_GATEWAY_URL,
  latrGatewayBaseUrlForHostname,
  LOCAL_LATR_GATEWAY_URL,
} from "@/lib/latrGatewayUrl";

const LATR_OFFICIAL_CLIENT_HEADER = "X-Latr-Official-Client";

function readServerHostname(): string | undefined {
  return (
    process.env.VERCEL_URL?.trim().toLowerCase() ??
    process.env.NEXT_PUBLIC_SITE_URL?.trim().toLowerCase()
  );
}

/** Upstream L@tr gateway base URL (server-side; credentials stay off the client). */
export function latrGatewayUpstreamBaseUrl(): string {
  const configured =
    process.env.LATR_GATEWAY_URL?.trim() ??
    process.env.NEXT_PUBLIC_LATR_GATEWAY_URL?.trim();
  if (configured) return configured.replace(/\/$/, "");

  const vercelHost = readServerHostname();
  if (vercelHost) {
    try {
      const hostname = new URL(
        vercelHost.includes("://") ? vercelHost : `https://${vercelHost}`
      ).hostname;
      const hosted = latrGatewayBaseUrlForHostname(hostname);
      if (hosted) return hosted;
    } catch {
      /* fall through */
    }
  }

  switch (getAppEnv()) {
    case "prod":
      return DEFAULT_PROD_LATR_GATEWAY_URL;
    case "test":
    case "dev":
      return DEFAULT_DEV_LATR_GATEWAY_URL;
    default:
      return LOCAL_LATR_GATEWAY_URL;
  }
}

function readServerClientId(): string | undefined {
  return process.env.LATR_GATEWAY_CLIENT_ID?.trim();
}

function readServerApiKey(): string | undefined {
  return process.env.LATR_GATEWAY_API_KEY?.trim();
}

function readServerOfficialCredential(): string | undefined {
  const raw =
    process.env.LATR_GATEWAY_CLIENT_CREDENTIAL?.trim() ??
    process.env.LATR_GATEWAY_OFFICIAL_CLIENT_CREDENTIALS?.trim();
  return normalizeLatrGatewayOfficialCredential(raw);
}

export function hasLatrGatewayServerCredentials(): boolean {
  const clientId = readServerClientId();
  const apiKey = readServerApiKey();
  if (clientId && apiKey) return true;
  return Boolean(readServerOfficialCredential());
}

export function latrGatewayServerCredentialsHelpText(): string {
  return (
    "Configure LATR_GATEWAY_CLIENT_ID and LATR_GATEWAY_API_KEY (preferred) or " +
    "LATR_GATEWAY_CLIENT_CREDENTIAL (bare base64 or the-social-wire-web=… from Fly secrets) " +
    "on the web server for Preview and Production. Testing uses " +
    "https://api.testing.latr.link — credentials must match that gateway host."
  );
}

/** Server-injected L@tr gateway client auth headers (never sent from the browser). */
export function buildLatrGatewayServerAuthHeaders(): Record<string, string> {
  const clientId = readServerClientId();
  const apiKey = readServerApiKey();
  if (clientId && apiKey) {
    return buildDeveloperGatewayHeaders({ clientId, apiKey });
  }

  const clientCredential = readServerOfficialCredential();
  if (clientCredential) {
    return { [LATR_OFFICIAL_CLIENT_HEADER]: clientCredential };
  }

  return {};
}

/** Headers forwarded from the signed-in browser session to the upstream gateway. */
export const LATR_GATEWAY_PROXY_FORWARDED_REQUEST_HEADERS = [
  "authorization",
  "dpop",
  "x-atproto-upstream-dpop",
  "content-type",
  "accept",
] as const;

export const LATR_GATEWAY_PROXY_FORWARDED_RESPONSE_HEADERS = [
  "content-type",
  "dpop-nonce",
] as const;
