import { describe, expect, it } from "bun:test";
import { GET } from "@/app/api/oauth/web-client-metadata/route";

describe("GET /api/oauth/web-client-metadata", () => {
  it("returns OAuth client metadata JSON", async () => {
    const request = new Request("https://thesocialwire.app/api/oauth/web-client-metadata");
    const response = await GET(request);
    expect(response.status).toBe(200);
    const body = (await response.json()) as { client_id: string; scope: string };
    expect(body.client_id).toContain("client-metadata");
    expect(body.scope).toContain("atproto");
    expect(response.headers.get("Access-Control-Allow-Origin")).toBe("*");
  });

  it("honors x-forwarded-host for client_id origin", async () => {
    const request = new Request(
      "https://internal/api/oauth/web-client-metadata",
      {
        headers: {
          "x-forwarded-host": "preview.example",
          "x-forwarded-proto": "https",
        },
      }
    );
    const response = await GET(request);
    const body = (await response.json()) as { client_id: string };
    expect(body.client_id).toBe("https://preview.example/client-metadata.json");
  });
});
