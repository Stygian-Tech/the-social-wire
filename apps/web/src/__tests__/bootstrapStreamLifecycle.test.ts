import { afterEach, expect, it, spyOn } from "bun:test";
import type { OAuthSession } from "@atproto/oauth-client-browser";
import * as Gateway from "@/lib/socialWireGatewayClient";
import { consumeBootstrapStream } from "@/lib/bootstrapStreamClient";

const restores: (() => void)[] = [];
afterEach(() => restores.splice(0).forEach(restore => restore()));
const oauthSession = { did: "did:plc:stream-lifecycle" } as unknown as OAuthSession;

it("finishes on protocol done even when the HTTP body stays open", async () => {
  let cancelled = false;
  const body = new ReadableStream<Uint8Array>({
    start(controller) { controller.enqueue(new TextEncoder().encode('{"kind":"done","done":{"refreshedAt":"2026-10-16T00:00:00Z"}}\n')); },
    cancel() { cancelled = true; },
  });
  const gateway = spyOn(Gateway, "gatewayFetch").mockResolvedValue(new Response(body));
  restores.push(() => gateway.mockRestore());
  const events: string[] = [];
  const result = consumeBootstrapStream({ oauthSession, handlers: { onEvent: event => events.push(event.kind) } });
  const outcome = await Promise.race([result.then(() => "done"), new Promise(resolve => setTimeout(() => resolve("stalled"), 50))]);
  expect(outcome).toBe("done");
  expect(events).toEqual(["done"]);
  expect(cancelled).toBe(true);
  expect(body.locked).toBe(false);
});

it("cancels a stalled reader on abort and propagates the timeout reason", async () => {
  let cancelled = false;
  const body = new ReadableStream<Uint8Array>({ cancel() { cancelled = true; } });
  const gateway = spyOn(Gateway, "gatewayFetch").mockResolvedValue(new Response(body));
  restores.push(() => gateway.mockRestore());
  const controller = new AbortController();
  const result = consumeBootstrapStream({ oauthSession, signal: controller.signal, handlers: { onEvent() {} } }).catch(error => error);
  await Promise.resolve();
  const reason = new DOMException("Refresh timed out", "TimeoutError");
  controller.abort(reason);
  const outcome = await Promise.race([result, new Promise(resolve => setTimeout(() => resolve("stalled"), 50))]);
  expect(outcome).toBe(reason);
  expect(cancelled).toBe(true);
  expect(body.locked).toBe(false);
});
