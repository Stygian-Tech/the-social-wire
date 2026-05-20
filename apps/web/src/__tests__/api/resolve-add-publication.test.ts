import { describe, expect, it, mock } from "bun:test";
import { POST } from "@/app/api/resolve-add-publication/route";

mock.module("@/lib/addPublicationResolveServer", () => ({
  resolveAddPublicationInput: async (input: string) => {
    if (input === "bad") return { error: "not found" };
    return { kind: "rss", feedUrl: "https://example.com/feed.xml" };
  },
}));

describe("POST /api/resolve-add-publication", () => {
  it("returns 400 for invalid JSON", async () => {
    const req = new Request("http://localhost/api/resolve-add-publication", {
      method: "POST",
      body: "not-json",
    });
    const res = await POST(req as never);
    expect(res.status).toBe(400);
  });

  it("returns 400 when input field missing", async () => {
    const req = new Request("http://localhost/api/resolve-add-publication", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({}),
    });
    const res = await POST(req as never);
    expect(res.status).toBe(400);
  });

  it("returns 422 for resolution errors", async () => {
    const req = new Request("http://localhost/api/resolve-add-publication", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ input: "bad" }),
    });
    const res = await POST(req as never);
    expect(res.status).toBe(422);
  });

  it("returns resolution payload on success", async () => {
    const req = new Request("http://localhost/api/resolve-add-publication", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ input: "https://example.com" }),
    });
    const res = await POST(req as never);
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body.kind).toBe("rss");
  });
});
