import { getAppEnv, isNonProd } from "@/lib/appEnv";
import type { LatrGatewayCredentialDiagnostics } from "@/lib/latrGatewayCredentialDiagnostics";

const DEBUG_CREDENTIALS_PATH = "/api/latr-gateway/debug/credentials";

/**
 * Fetch server-side L@tr gateway credential diagnostics (non-prod only).
 * Safe to call from the browser — secrets are never returned.
 */
export async function fetchLatrGatewayCredentialDiagnostics(): Promise<LatrGatewayCredentialDiagnostics | null> {
  if (!isNonProd(getAppEnv())) return null;

  const res = await fetch(DEBUG_CREDENTIALS_PATH, {
    method: "GET",
    headers: { Accept: "application/json" },
    cache: "no-store",
  });

  if (res.status === 404) return null;

  const json = (await res.json()) as LatrGatewayCredentialDiagnostics;
  return json;
}

/** Logs credential diagnostics to the console when APP_ENV is dev/test/local. */
export async function logLatrGatewayCredentialDiagnostics(): Promise<void> {
  const diagnostics = await fetchLatrGatewayCredentialDiagnostics();
  if (!diagnostics) {
    console.info("[latr-gateway] credential diagnostics unavailable in production.");
    return;
  }

  const label = diagnostics.probe.ok ? "OK" : "FAILED";
  console.group(`[latr-gateway] credential diagnostics (${label})`);
  console.info("appEnv:", diagnostics.appEnv);
  console.info("upstream:", diagnostics.upstreamBaseUrl);
  console.info("authMode:", diagnostics.authMode);
  console.info("clientId:", diagnostics.clientId);
  console.info("apiKey:", diagnostics.apiKeyHint ?? "(not configured)");
  console.info(
    "officialCredential:",
    diagnostics.officialCredentialPresent
      ? `present (${diagnostics.officialCredentialLength} chars)`
      : "(not configured)"
  );
  if (diagnostics.warnings.length > 0) {
    console.warn("warnings:", diagnostics.warnings);
  }
  console.info("probe:", diagnostics.probe);
  console.groupEnd();
}
