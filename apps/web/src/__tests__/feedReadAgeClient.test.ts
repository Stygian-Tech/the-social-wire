import { afterEach, describe, expect, it, spyOn } from "bun:test";
import type { OAuthSession } from "@atproto/oauth-client-browser";

import { fetchReadAgeOptions, markReadBefore } from "@/lib/feedReadAgeClient";
import type { GatewayMarkAllReadScope } from "@/lib/publicationProjectionClient";
import * as GatewayClient from "@/lib/socialWireGatewayClient";
import { socialWireXrpc } from "@/lib/socialWireXrpc";

const oauth = { did: "did:plc:viewer" } as unknown as OAuthSession;
const before = "2026-09-02T05:00:00Z";
let restoreGateway: (() => void) | undefined;

afterEach(() => restoreGateway?.());

describe("feedReadAgeClient", () => {
  const scopes: GatewayMarkAllReadScope[] = [
    { kind: "publication", publicationId: "at://did:plc:author/site.standard.publication/a" },
    { kind: "folder", folderRkey: "folder one" },
    { kind: "subscribed" },
    { kind: "following" },
  ];

  for (const scope of scopes) {
    it(`requests full ${scope.kind} history using the local calendar time zone`, async () => {
      const response = { referenceDay: before, options: [{ days: 1, before, count: 12 }] };
      const gateway = spyOn(GatewayClient, "gatewayFetch")
        .mockResolvedValue(Response.json(response));
      restoreGateway = () => gateway.mockRestore();

      expect(await fetchReadAgeOptions(oauth, scope, "America/Chicago")).toEqual(response);
      const [session, path, init] = gateway.mock.calls[0]!;
      expect(session).toBe(oauth);
      const url = new URL(path, "https://api.example.com");
      expect(url.pathname).toBe(socialWireXrpc.getReadAgeOptions);
      expect(Object.fromEntries(url.searchParams)).toEqual({ ...scope, timeZone: "America/Chicago" });
      expect(init?.method).toBe("GET");
    });
  }

  it("sends the exact server cutoff to the dedicated mutation endpoint", async () => {
    const scope = { kind: "subscribed" } as const;
    const response = { marked: 1, entryIds: ["old"], readAt: before, unreadCounts: {} };
    const gateway = spyOn(GatewayClient, "gatewayFetch")
      .mockResolvedValue(Response.json(response));
    restoreGateway = () => gateway.mockRestore();

    expect(await markReadBefore(oauth, scope, before)).toEqual(response);
    expect(gateway).toHaveBeenCalledWith(oauth, socialWireXrpc.markReadBefore, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ scope, before }),
    });
  });

  it("reports unsupported or failed requests without falling back to mark-all", async () => {
    const gateway = spyOn(GatewayClient, "gatewayFetch")
      .mockResolvedValue(new Response(null, { status: 404 }));
    restoreGateway = () => gateway.mockRestore();

    await expect(fetchReadAgeOptions(oauth, { kind: "following" }, "UTC"))
      .rejects.toThrow("Read age options failed (404)");
    await expect(markReadBefore(oauth, { kind: "following" }, before))
      .rejects.toThrow("Mark older stories read failed (404)");
    expect(gateway).toHaveBeenCalledTimes(2);
    expect(gateway.mock.calls.some(([, path]) => path === socialWireXrpc.markAllRead)).toBe(false);
  });
});
