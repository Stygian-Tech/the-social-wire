import type { OAuthSession } from "@atproto/oauth-client-browser";
import {
  LATR_GATEWAY_SAVES_PATH,
  type LatrGatewaySavedItemsResponse,
} from "latr-packages/gateway-client";

import { latrGatewayJson } from "@/lib/latrGatewayClient";
import type { LatrSavedItemRecord, RepoRecord } from "@/lib/pdsClient";

/** List `com.latr.saved.item` rows via `GET /v1/latr/saves` (same path as L@tr.link gateway docs). */
export async function listLatrSavedItemsViaGateway(
  oauthSession: OAuthSession,
  options: { signal?: AbortSignal } = {}
): Promise<RepoRecord<LatrSavedItemRecord>[]> {
  const response = await latrGatewayJson<
    LatrGatewaySavedItemsResponse<LatrSavedItemRecord>
  >(oauthSession, LATR_GATEWAY_SAVES_PATH, {
    method: "GET",
    signal: options.signal,
  });
  return response.records ?? [];
}
