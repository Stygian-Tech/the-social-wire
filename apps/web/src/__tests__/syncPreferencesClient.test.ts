import { describe, expect, it } from "bun:test";

import {
  decodeSyncPreferencesResponse,
  syncPreferencesPath,
} from "@/lib/syncPreferencesClient";

describe("syncPreferencesClient", () => {
  it("uses the authoritative refresh route after a direct PDS write", () => {
    expect(syncPreferencesPath(true)).toBe(
      "/xrpc/app.thesocialwire.sync.getPreferences?fresh=true",
    );
  });

  it("does not turn an upstream failure into default L@tr preferences", async () => {
    await expect(
      decodeSyncPreferencesResponse(new Response(null, { status: 502 }), "did:plc:viewer"),
    ).rejects.toThrow("Preference sync failed (502).");
  });

  it("returns the committed Semble preference record and revision", async () => {
    const response = new Response(
      JSON.stringify({
        cid: "bafy-semble",
        record: {
          $type: "app.thesocialwire.preferences",
          readLaterService: "semble",
          readLaterConnections: {
            semble: {
              collectionUri:
                "at://did:plc:viewer/network.cosmik.collection/read-later",
              collectionName: "Read Later",
              connectedAt: "2026-09-01T12:00:00Z",
            },
          },
          createdAt: "2026-09-01T12:00:00Z",
          updatedAt: "2026-09-01T12:01:00Z",
        },
      }),
      { status: 200, headers: { "Content-Type": "application/json" } },
    );

    const result = await decodeSyncPreferencesResponse(response, "did:plc:viewer");

    expect(result?.cid).toBe("bafy-semble");
    expect(result?.value.readLaterService).toBe("semble");
    expect(result?.value.readLaterConnections?.semble?.collectionName).toBe(
      "Read Later",
    );
  });
});
