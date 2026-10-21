import { expect, spyOn, test } from "bun:test";
import { POST } from "@/app/xrpc/at.anypub.prepare/route";
import { createPreparationProxy } from "@/lib/anypub/preparationProxy";
function request(body = '{"operation":"document","input":{"title":"Private Draft"}}') {
  return new Request("https://thesocialwire.app/xrpc/at.anypub.prepare", { method: "POST", headers: { "Content-Type": "application/json", Authorization: "Bearer browser-token", DPoP: "browser-proof", Cookie: "session=private" }, body });
}
test("forwards only JSON preparation without browser credentials", async () => {
  let sent: RequestInit | undefined;
  let target = "";
  const fetcher = (async (url: string | URL | Request, init?: RequestInit) => { target = String(url); sent = init; return Response.json({ record: { $type: "site.standard.document" } }); }) as typeof fetch;
  const response = await createPreparationProxy({ upstream: "http://anypub.railway.internal:8080", fetcher })(request());
  expect(response.status).toBe(200);
  expect(target).toBe("http://anypub.railway.internal:8080/xrpc/at.anypub.prepare");
  expect(sent?.headers).toEqual({ "Content-Type": "application/json" });
  expect(sent?.credentials).toBe("omit");
  expect(sent?.redirect).toBe("error");
  expect(new TextDecoder().decode(sent?.body as Uint8Array)).toContain("Private Draft");
  expect(response.headers.get("Cache-Control")).toBe("no-store");
});
test("preserves validation failures and fails closed without service configuration", async () => {
  const fetcher = (async () => Response.json({ error: "InvalidRequest", message: "title: exceeds limit" }, { status: 400 })) as unknown as typeof fetch;
  const validation = await createPreparationProxy({ upstream: "https://anypub.example", fetcher })(request());
  expect(validation.status).toBe(400);
  expect(await validation.json()).toEqual({ error: "InvalidRequest", message: "title: exceeds limit" });
  expect((await createPreparationProxy({})(request())).status).toBe(503);
  expect((await createPreparationProxy({ upstream: "https://user:secret@anypub.example" })(request())).status).toBe(503);
});
test("rejects invalid media types, oversized input, and invalid upstream responses", async () => {
  const handler = createPreparationProxy({ upstream: "https://anypub.example", fetcher: (async () => new Response("private server details", { status: 500 })) as unknown as typeof fetch });
  expect((await handler(new Request("https://example.com", { method: "POST", body: "text" }))).status).toBe(415);
  expect((await handler(request('x'.repeat(8 * 1024 * 1024 + 1)))).status).toBe(413);
  const failure = await handler(request());
  expect(failure.status).toBe(502);
  expect(await failure.text()).not.toContain("private server details");
  const notJSON = createPreparationProxy({ upstream: "https://anypub.example", fetcher: (async () => new Response("html")) as unknown as typeof fetch });
  expect((await notJSON(request())).status).toBe(502);
});

test("the XRPC route reads only server configuration and reports a missing service", async () => {
  const previous = process.env.ANYPUB_API_URL;
  delete process.env.ANYPUB_API_URL;
  try { expect((await POST(request())).status).toBe(503); }
  finally { if (previous === undefined) delete process.env.ANYPUB_API_URL; else process.env.ANYPUB_API_URL = previous; }
});

test("the configured XRPC route forwards to the published at.anypub namespace", async () => {
  const previous = process.env.ANYPUB_API_URL;
  process.env.ANYPUB_API_URL = "https://anypub.example";
  const fetcher = spyOn(globalThis, "fetch").mockResolvedValue(Response.json({ record: { $type: "site.standard.document" } }));
  try {
    const response = await POST(request());
    expect(response.status).toBe(200);
    expect(fetcher).toHaveBeenCalledTimes(1);
    const [endpoint, init] = fetcher.mock.calls[0];
    expect(String(endpoint)).toBe("https://anypub.example/xrpc/at.anypub.prepare");
    expect(init?.headers).toEqual({ "Content-Type": "application/json" });
    expect(init?.credentials).toBe("omit");
    expect(await response.json()).toEqual({ record: { $type: "site.standard.document" } });
  } finally {
    fetcher.mockRestore();
    if (previous === undefined) delete process.env.ANYPUB_API_URL;
    else process.env.ANYPUB_API_URL = previous;
  }
});
