import type { OAuthSession } from "@atproto/oauth-client-browser";

import { gatewayFetch } from "@/lib/socialWireGatewayClient";

export async function isUpstreamProofRequired(response: Response): Promise<boolean> {
  if (response.status !== 428) return false;
  try {
    const body = await response.clone().json();
    return body?.error === "UpstreamProofRequired";
  } catch {
    return false;
  }
}

/** Only a cold viewer cache needs a PDS proof pool. Never retry other failures. */
export async function gatewayFetchWithProofChallenge(
  session: OAuthSession,
  path: string,
  init: RequestInit,
  header: string,
  prepare: () => Promise<string>,
): Promise<Response> {
  const response = await gatewayFetch(session, path, init);
  if (!(await isUpstreamProofRequired(response))) return response;
  init.signal?.throwIfAborted();
  // gatewayFetch obtains the bound receipt before preparing proofs and renews
  // the whole ceremony at most once if that receipt expires during preparation.
  return gatewayFetch(session, path, init, async () => ({ [header]: await prepare() }));
}
