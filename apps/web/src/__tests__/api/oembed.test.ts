import { describe, expect, it } from "bun:test";
import { NextRequest } from "next/server";

import { GET } from "@/app/api/oembed/route";

describe("GET /api/oembed", () => {
  it("returns 400 when url param missing", async () => {
    const req = new NextRequest("http://localhost/api/oembed");
    const res = await GET(req);
    expect(res.status).toBe(400);
    const body = await res.json();
    expect(body.error).toBe("missing url");
  });

  it("returns 400 for non-https target", async () => {
    const req = new NextRequest(
      "http://localhost/api/oembed?url=" +
        encodeURIComponent("http://insecure.example/article")
    );
    const res = await GET(req);
    expect(res.status).toBe(400);
  });
});
