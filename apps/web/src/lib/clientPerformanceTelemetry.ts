import type { OAuthSession } from "@atproto/oauth-client-browser";

import { getAppEnv } from "@/lib/appEnv";
import { gatewayFetch } from "@/lib/socialWireGatewayClient";

export type ClientPerformanceEvent =
  | "cached_feed_paint"
  | "uncached_feed_paint"
  | "feed_switch"
  | "fresh_merge"
  | "feed_error";

export function recordClientPerformance(
  oauthSession: OAuthSession,
  sample: {
    event: ClientPerformanceEvent;
    durationMs: number;
    feedType: "aggregate" | "publication";
    cacheState: "hit" | "miss";
    outcome: "success" | "error";
  }
): Promise<Response> {
  const rawEnvironment = getAppEnv();
  const environment = rawEnvironment === "prod" ? "production" : rawEnvironment;
  return gatewayFetch(oauthSession, "/v1/telemetry/client-performance", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      ...sample,
      durationMs: Math.max(0, Math.min(60_000, sample.durationMs)),
      environment: ["local", "dev", "test", "production"].includes(environment)
        ? environment
        : "dev",
    }),
    keepalive: true,
  });
}
