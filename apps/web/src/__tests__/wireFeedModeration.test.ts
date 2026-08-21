import { describe, expect, it } from "bun:test";

import {
  hasWireModerationScopes,
} from "@/hooks/useWireFeed";
import { WIRE_MODERATION_RPC_SCOPES } from "@/lib/atprotoOAuthScopes";
import {
  WIRE_MODERATION_DPOP_HEADER,
  WIRE_MODERATION_PROOF_SPECS,
} from "@/lib/wireFeedClient";

describe("The Wire viewer moderation", () => {
  it("requires every declared viewer moderation scope", () => {
    const complete = ["atproto", ...WIRE_MODERATION_RPC_SCOPES].join(" ");
    expect(hasWireModerationScopes(complete)).toBe(true);

    for (const missing of WIRE_MODERATION_RPC_SCOPES) {
      const incomplete = WIRE_MODERATION_RPC_SCOPES.filter(
        (scope) => scope !== missing,
      ).join(" ");
      expect(hasWireModerationScopes(incomplete)).toBe(false);
    }
  });

  it("mints the exact ordered PDS proof pool expected by Gateway", () => {
    expect(WIRE_MODERATION_DPOP_HEADER).toBe("X-Wire-Moderation-DPoP");
    expect(WIRE_MODERATION_PROOF_SPECS).toEqual([
      { xrpcMethod: "app.bsky.actor.getPreferences", httpMethod: "GET" },
      { xrpcMethod: "app.bsky.graph.getBlocks", httpMethod: "GET" },
      { xrpcMethod: "app.bsky.graph.getMutes", httpMethod: "GET" },
      { xrpcMethod: "app.bsky.graph.getListMutes", httpMethod: "GET" },
      { xrpcMethod: "app.bsky.graph.getListBlocks", httpMethod: "GET" },
    ]);
  });
});
