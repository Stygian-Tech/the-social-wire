import { describe, expect, it } from "bun:test";
import { NextRequest } from "next/server";
import { GET } from "@/app/api/rss-feed/route";

describe("GET /api/rss-feed", () => {
  it("returns 400 when url is missing", async () => {
    const req = new NextRequest("http://localhost/api/rss-feed");
    const res = await GET(req);
    expect(res.status).toBe(400);
    const body = await res.json();
    expect(body.error).toBe("missing url");
  });

  it("returns 400 for invalid feed URL", async () => {
    const req = new NextRequest(
      "http://localhost/api/rss-feed?url=not-a-valid-url"
    );
    const res = await GET(req);
    expect(res.status).toBe(400);
  });
});
