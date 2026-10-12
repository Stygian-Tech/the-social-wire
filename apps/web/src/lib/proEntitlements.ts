import type { OAuthSession } from "@atproto/oauth-client-browser";
import { gatewayFetch } from "@/lib/socialWireGatewayClient";

export type ProEntitlements = { viewerDid: string; plan: "free" | "pro" };
export const PRO_REQUIRED_MESSAGE = "This Feature Requires Social Wire Pro.";

export function isProGatingEnabled(): boolean {
  return process.env.NEXT_PUBLIC_PRO_GATING_ENABLED === "true";
}

/** Entitlements come only from the authenticated server, never browser storage. */
export async function getProEntitlements(session: OAuthSession, signal?: AbortSignal): Promise<ProEntitlements> {
  const response = await gatewayFetch(session, "/v1/subscription/entitlements", { signal, cache: "no-store" });
  if (!response.ok) throw new Error("Pro Access Could Not Be Verified.");
  const value = await response.json();
  if (value?.viewerDid !== session.did || !["free", "pro"].includes(value?.plan)) throw new Error("Pro Access Could Not Be Verified.");
  return { viewerDid: value.viewerDid, plan: value.plan };
}

export async function requirePro(session: OAuthSession): Promise<void> {
  if (!isProGatingEnabled()) return;
  if ((await getProEntitlements(session)).plan !== "pro") throw new Error(PRO_REQUIRED_MESSAGE);
}
