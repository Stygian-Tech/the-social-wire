import { buildDeveloperGatewayHeaders, LATR_API_KEY_HEADER, LATR_CLIENT_ID_HEADER } from "latr-packages/gateway-client";

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
    "Set LATR_GATEWAY_CLIENT_CREDENTIAL to the `the-social-wire-web=…` entry from " +
    "api.testing.latr.link Fly secrets (official credential), or LATR_GATEWAY_CLIENT_ID + " +
    "LATR_GATEWAY_API_KEY issued for that same gateway host. Configure on Vercel for " +
    "Preview and Production. If both official and split env vars exist, official wins."
  );
}

export type LatrGatewayServerAuthMode = "official-client" | "split-developer" | "none";

export function resolveLatrGatewayServerAuthMode(): LatrGatewayServerAuthMode {
  const headers = buildLatrGatewayServerAuthHeaders();
  if (headers[LATR_OFFICIAL_CLIENT_HEADER]) return "official-client";
  if (headers[LATR_CLIENT_ID_HEADER] && headers[LATR_API_KEY_HEADER]) {
    return "split-developer";
  }
  return "none";
}

/** Server-injected L@tr gateway client auth headers (never sent from the browser). */
export function buildLatrGatewayServerAuthHeaders(): Record<string, string> {
  const clientCredential = readServerOfficialCredential();
  if (clientCredential) {
    return { [LATR_OFFICIAL_CLIENT_HEADER]: clientCredential };
  }

  const clientId = readServerClientId();
  const apiKey = readServerApiKey();
  if (clientId && apiKey) {
    return buildDeveloperGatewayHeaders({ clientId, apiKey });
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
