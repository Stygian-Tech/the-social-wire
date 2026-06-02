import type { OAuthSession } from "@atproto/oauth-client-browser";
import {
  LATR_GATEWAY_MIGRATE_LEXICONS_PATH,
  type LatrGatewayLexiconMigrationResponse,
} from "latr-packages/gateway-client";

import { latrGatewayJson } from "@/lib/latrGatewayClient";

/** One-time PDS copy from legacy `com.latr.*` to canonical `link.latr.*`. */
export async function migrateLatrLexiconsViaGateway(
  oauthSession: OAuthSession
): Promise<LatrGatewayLexiconMigrationResponse | null> {
  try {
    return await latrGatewayJson<LatrGatewayLexiconMigrationResponse>(
      oauthSession,
      LATR_GATEWAY_MIGRATE_LEXICONS_PATH,
      { method: "POST" }
    );
  } catch {
    return null;
  }
}

export function latrLexiconMigrationChanged(
  response: LatrGatewayLexiconMigrationResponse | null
): boolean {
  if (!response) return false;
  return (
    response.externalCopied > 0 ||
    response.itemsCopied > 0 ||
    response.externalDeleted > 0 ||
    response.itemsDeleted > 0
  );
}
