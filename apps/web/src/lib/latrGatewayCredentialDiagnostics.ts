import {
  LATR_API_KEY_HEADER,
  LATR_CLIENT_ID_HEADER,
} from "latr-packages/gateway-client";

import { getAppEnv } from "@/lib/appEnv";
import { THE_SOCIAL_WIRE_WEB_CLIENT_ID } from "@/lib/latrGatewayOfficialCredential";
import {
  buildLatrGatewayServerAuthHeaders,
  hasLatrGatewayServerCredentials,
  latrGatewayServerCredentialsHelpText,
  latrGatewayUpstreamBaseUrl,
  resolveLatrGatewayServerAuthMode,
} from "@/lib/latrGatewayProxyServer";

const LATR_OFFICIAL_CLIENT_HEADER = "X-Latr-Official-Client";

export type LatrGatewayCredentialAuthMode =
  | "split-developer"
  | "official-client"
  | "none";

export type LatrGatewayCredentialProbe = {
  ok: boolean;
  status: number;
  code?: string;
  message?: string;
  interpretation: string;
};

export type LatrGatewayCredentialDiagnostics = {
  appEnv: string;
  upstreamBaseUrl: string;
  authMode: LatrGatewayCredentialAuthMode;
  /** Configured client id (not secret). */
  clientId: string | null;
  apiKeyPresent: boolean;
  /** Redacted fingerprint, e.g. `lk_abcd…wxyz`. */
  apiKeyHint: string | null;
  officialCredentialPresent: boolean;
  officialCredentialLength: number | null;
  envPresent: {
    LATR_GATEWAY_CLIENT_ID: boolean;
    LATR_GATEWAY_API_KEY: boolean;
    LATR_GATEWAY_CLIENT_CREDENTIAL: boolean;
    LATR_GATEWAY_OFFICIAL_CLIENT_CREDENTIALS: boolean;
    LATR_GATEWAY_URL: boolean;
    NEXT_PUBLIC_LATR_GATEWAY_URL: boolean;
  };
  warnings: string[];
  probe: LatrGatewayCredentialProbe;
  helpText: string;
};

function redactApiKeyHint(apiKey: string | undefined): string | null {
  const trimmed = apiKey?.trim();
  if (!trimmed) return null;
  if (trimmed.length <= 10) return `${trimmed.slice(0, 3)}…`;
  return `${trimmed.slice(0, 7)}…${trimmed.slice(-4)}`;
}

function resolveAuthMode(): LatrGatewayCredentialAuthMode {
  return resolveLatrGatewayServerAuthMode();
}

function collectWarnings(args: {
  clientId: string | undefined;
  apiKey: string | undefined;
  rawOfficial: string | undefined;
  authMode: LatrGatewayCredentialAuthMode;
}): string[] {
  const warnings: string[] = [];
  const { clientId, apiKey, rawOfficial, authMode } = args;

  if (clientId && !apiKey) {
    warnings.push("LATR_GATEWAY_CLIENT_ID is set but LATR_GATEWAY_API_KEY is missing.");
  }
  if (apiKey && !clientId) {
    warnings.push("LATR_GATEWAY_API_KEY is set but LATR_GATEWAY_CLIENT_ID is missing.");
  }
  if (
    clientId &&
    clientId !== THE_SOCIAL_WIRE_WEB_CLIENT_ID &&
    authMode === "split-developer"
  ) {
    warnings.push(
      `LATR_GATEWAY_CLIENT_ID is "${clientId}"; expected "${THE_SOCIAL_WIRE_WEB_CLIENT_ID}" for this app on hosted gateways.`
    );
  }
  if (clientId && apiKey && rawOfficial) {
    warnings.push(
      "Both split developer headers and official credential env vars are set; official credential takes precedence."
    );
  }
  if (
    rawOfficial &&
    (rawOfficial.includes(",") || rawOfficial.includes(";")) &&
    !rawOfficial.includes(THE_SOCIAL_WIRE_WEB_CLIENT_ID)
  ) {
    warnings.push(
      "LATR_GATEWAY_OFFICIAL_CLIENT_CREDENTIALS map does not include the-social-wire-web."
    );
  }
  if (
    rawOfficial?.includes("=") &&
    authMode === "none" &&
    !process.env.LATR_GATEWAY_CLIENT_ID?.trim()
  ) {
    warnings.push(
      "Official credential env looks like client-id=… but could not be parsed; use bare base64 or the-social-wire-web=…"
    );
  }

  return warnings;
}

export function interpretProbeResponse(
  status: number,
  body: { error?: string; message?: string }
): LatrGatewayCredentialProbe {
  const code = body.error?.trim();
  const message = body.message?.trim();

  if (status === 401 && code === "missing_auth") {
    return {
      ok: true,
      status,
      code,
      message,
      interpretation:
        "Gateway accepted app credentials; route still requires signed-in user OAuth (expected).",
    };
  }

  if (status === 403 && code === "invalid_client_credential") {
    return {
      ok: false,
      status,
      code,
      message,
      interpretation:
        "Gateway rejected app credentials — verify client id / API key match api.testing.latr.link (or your LATR_GATEWAY_URL host).",
    };
  }

  if (status === 403 && code === "client_forbidden") {
    return {
      ok: false,
      status,
      code,
      message,
      interpretation:
        "App credentials were accepted but OAuth client policy blocked the probe (unexpected without user token).",
    };
  }

  if (status === 503 || code === "missing_client_credential") {
    return {
      ok: false,
      status,
      code,
      message,
      interpretation: "Proxy or gateway thinks app credentials are missing.",
    };
  }

  if (status >= 200 && status < 300) {
    return {
      ok: true,
      status,
      code,
      message,
      interpretation: "Gateway accepted app credentials for the probe route.",
    };
  }

  return {
    ok: false,
    status,
    code,
    message,
    interpretation:
      message ??
      `Unexpected gateway response (${status}); check upstream URL and Fly secrets.`,
  };
}

/** Server-side probe: inject app auth only (no user OAuth) against og-preview. */
export async function probeLatrGatewayServerCredentials(): Promise<LatrGatewayCredentialProbe> {
  if (!hasLatrGatewayServerCredentials()) {
    return {
      ok: false,
      status: 0,
      code: "missing_env",
      interpretation: latrGatewayServerCredentialsHelpText(),
    };
  }

  const upstreamBaseUrl = latrGatewayUpstreamBaseUrl();
  const probeUrl = `${upstreamBaseUrl}/v1/latr/og-preview?${new URLSearchParams({
    url: "https://example.com",
  }).toString()}`;

  let response: Response;
  try {
    response = await fetch(probeUrl, {
      method: "GET",
      headers: {
        Accept: "application/json",
        ...buildLatrGatewayServerAuthHeaders(),
      },
    });
  } catch {
    return {
      ok: false,
      status: 0,
      code: "gateway_unreachable",
      interpretation: `Could not reach ${upstreamBaseUrl}.`,
    };
  }

  let body: { error?: string; message?: string } = {};
  try {
    body = (await response.json()) as { error?: string; message?: string };
  } catch {
    /* ignore */
  }

  return interpretProbeResponse(response.status, body);
}

export async function buildLatrGatewayCredentialDiagnostics(): Promise<LatrGatewayCredentialDiagnostics> {
  const clientId = process.env.LATR_GATEWAY_CLIENT_ID?.trim();
  const apiKey = process.env.LATR_GATEWAY_API_KEY?.trim();
  const rawOfficial =
    process.env.LATR_GATEWAY_CLIENT_CREDENTIAL?.trim() ??
    process.env.LATR_GATEWAY_OFFICIAL_CLIENT_CREDENTIALS?.trim();
  const authMode = resolveAuthMode();
  const serverHeaders = buildLatrGatewayServerAuthHeaders();

  const officialCredentialPresent = Boolean(
    serverHeaders[LATR_OFFICIAL_CLIENT_HEADER]
  );
  const officialCredentialLength = serverHeaders[LATR_OFFICIAL_CLIENT_HEADER]
    ?.length ?? null;

  return {
    appEnv: getAppEnv(),
    upstreamBaseUrl: latrGatewayUpstreamBaseUrl(),
    authMode,
    clientId:
      authMode === "split-developer"
        ? (serverHeaders[LATR_CLIENT_ID_HEADER] ?? clientId ?? null)
        : clientId ?? null,
    apiKeyPresent: authMode === "split-developer" && Boolean(apiKey),
    apiKeyHint:
      authMode === "split-developer" ? redactApiKeyHint(apiKey) : null,
    officialCredentialPresent,
    officialCredentialLength,
    envPresent: {
      LATR_GATEWAY_CLIENT_ID: Boolean(process.env.LATR_GATEWAY_CLIENT_ID?.trim()),
      LATR_GATEWAY_API_KEY: Boolean(process.env.LATR_GATEWAY_API_KEY?.trim()),
      LATR_GATEWAY_CLIENT_CREDENTIAL: Boolean(
        process.env.LATR_GATEWAY_CLIENT_CREDENTIAL?.trim()
      ),
      LATR_GATEWAY_OFFICIAL_CLIENT_CREDENTIALS: Boolean(
        process.env.LATR_GATEWAY_OFFICIAL_CLIENT_CREDENTIALS?.trim()
      ),
      LATR_GATEWAY_URL: Boolean(process.env.LATR_GATEWAY_URL?.trim()),
      NEXT_PUBLIC_LATR_GATEWAY_URL: Boolean(
        process.env.NEXT_PUBLIC_LATR_GATEWAY_URL?.trim()
      ),
    },
    warnings: collectWarnings({ clientId, apiKey, rawOfficial, authMode }),
    probe: await probeLatrGatewayServerCredentials(),
    helpText: latrGatewayServerCredentialsHelpText(),
  };
}
