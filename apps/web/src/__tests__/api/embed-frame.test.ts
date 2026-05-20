import { describe, expect, it } from "bun:test";
import { NextRequest } from "next/server";
import { GET } from "@/app/api/embed-frame/route";

describe("GET /api/embed-frame", () => {
  it("returns 400 when url param missing", async () => {
    const req = new NextRequest("http://localhost/api/embed-frame");
    const res = await GET(req);
    expect(res.status).toBe(400);
    const body = await res.json();
    expect(body.error).toBe("missing url");
  });

  it("returns 400 for non-https embed target", async () => {
    const req = new NextRequest(
      "http://localhost/api/embed-frame?url=" +
        encodeURIComponent("ftp://example.com/page")
    );
    const res = await GET(req);
    expect(res.status).toBe(400);
  });
});
