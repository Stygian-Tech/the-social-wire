import { afterEach, expect, it, spyOn } from "bun:test";
import type { OAuthSession } from "@atproto/oauth-client-browser";
import * as Gateway from "@/lib/socialWireGatewayClient";
import { getGifFile, getGifPoster } from "@/lib/klipyClient";
import type { GifRendition } from "@/lib/composerMedia";

const session = { did: "did:plc:gif-owner" } as unknown as OAuthSession;
const actor = { session, viewerDid: session.did };
const restores: (() => void)[] = [];
afterEach(() => restores.splice(0).reverse().forEach(restore => restore()));
function gateway(send: (path: string, init?: RequestInit) => Promise<Response>) {
  const mock = spyOn(Gateway, "gatewayFetch").mockImplementation(async (current, path, init) => { expect(current).toBe(session); return send(path, init); });
  restores.push(() => mock.mockRestore()); return mock;
}
it.each(["gif", "poster", "mp4", "webm"] as GifRendition[])("retrieves %s by catalog ID through the fixed authenticated endpoint", async rendition => {
  const type = rendition === "gif" ? "image/gif" : rendition === "poster" ? "image/png" : `video/${rendition}`;
  gateway(async (path, init) => {
    expect(path).toBe(`/xrpc/app.thesocialwire.socialDraft.getGifFile?id=catalog-ID&rendition=${rendition}`);
    expect(init?.cache).toBe("no-store"); expect(init?.redirect).toBe("error"); expect(init?.signal).toBeDefined();
    return new Response("private bytes", { headers: { "Content-Type": type } });
  });
  const blob = await getGifFile(actor, "catalog-ID", rendition);
  expect(await blob.text()).toBe("private bytes"); expect(blob.type).toBe(type);
});
it("refuses URI IDs and a different account without sending credentials", async () => {
  const mock = gateway(async () => { throw new Error("Must Not Fetch"); });
  await expect(getGifFile(actor, "https://static.klipy.com/ii/a.gif", "gif")).rejects.toThrow("Reselect");
  await expect(getGifFile({ ...actor, viewerDid: "did:plc:other" }, "id", "gif")).rejects.toThrow("Account Changed");
  expect(mock).not.toHaveBeenCalled();
});
it("validates MIME, poster size, and cancellation without a public URL fallback", async () => {
  const mock = gateway(async () => new Response("wrong", { headers: { "Content-Type": "text/html" } }));
  await expect(getGifFile(actor, "id", "gif")).rejects.toThrow("Invalid Private GIF");
  mock.mockImplementation(async () => new Response(new Blob([new Uint8Array(1_000_001)], { type: "image/jpeg" })));
  await expect(getGifPoster(session, "id")).rejects.toThrow("Invalid Private GIF");
  mock.mockImplementation(() => new Promise(() => {}));
  const controller = new AbortController(); const pending = getGifFile({ ...actor, signal: controller.signal }, "id", "gif");
  controller.abort(new Error("Closed")); await expect(pending).rejects.toThrow("Closed");
});
it("rejects a late actor result and preserves upstream errors", async () => {
  let current = true;
  const mock = gateway(async () => { current = false; return new Response(new Blob(["GIF"], { type: "image/gif" })); });
  await expect(getGifFile({ ...actor, assertCurrentActor: () => { if (!current) throw new Error("Account Changed"); } }, "id", "gif")).rejects.toThrow("Account Changed");
  mock.mockImplementation(async () => new Response(null, { status: 503 }));
  await expect(getGifFile(actor, "id", "gif")).rejects.toThrow("Retry Or Reselect");
});
