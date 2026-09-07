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

describe("progressive read age stream", () => {
  function streamResponse() {
    let controller!: ReadableStreamDefaultController<Uint8Array>;
    const body = new ReadableStream<Uint8Array>({ start(value) { controller = value; } });
    const gateway = spyOn(GatewayClient, "gatewayFetch").mockResolvedValue(
      new Response(body, { headers: { "Content-Type": "application/x-ndjson" } })
    );
    restoreGateway = () => gateway.mockRestore();
    return { controller, send: (text: string) => controller.enqueue(new TextEncoder().encode(text)) };
  }
  const first = { referenceDay: before, options: [{ days: 7, before, count: 3 }] };
  const final = { ...first, options: [{ days: 7, before, count: 12 }] };

  it("delivers split chunks progressively and finishes only on done", async () => {
    const { send } = streamResponse();
    const snapshots: unknown[] = [];
    let firstArrived!: () => void;
    const arrived = new Promise<void>((resolve) => { firstArrived = resolve; });
    let complete = false;
    const operation = fetchReadAgeOptions(oauth, { kind: "subscribed" }, "UTC", {
      onOptions: (options) => { snapshots.push(options); firstArrived(); },
    }).then((result) => { complete = true; return result; });
    const event = JSON.stringify({ type: "options", ...first });
    send(event.slice(0, 18));
    send(event.slice(18) + "\n");
    await arrived;
    expect(snapshots).toEqual([first.options]);
    expect(complete).toBe(false);
    send(JSON.stringify({ type: "options", ...final }) + '\n{"type":"done"}\n');
    expect(await operation).toEqual(final);
    expect(snapshots).toEqual([first.options, final.options]);
  });

  for (const ending of ["truncated", "error", "malformed", "out-of-range", "no-options"] as const) {
    it(`rejects ${ending} streams`, async () => {
      const { send, controller } = streamResponse();
      const operation = fetchReadAgeOptions(oauth, { kind: "subscribed" }, "UTC");
      if (ending !== "no-options") send(JSON.stringify({ type: "options", ...first }) + "\n");
      if (ending === "error") send('{"type":"error","message":"private upstream detail"}\n');
      if (ending === "malformed") send('{bad json}\n');
      if (ending === "out-of-range") send(JSON.stringify({ type: "options", ...first, options: [{ days: 8, before, count: 1 }] }) + "\n");
      if (ending === "no-options") send('{"type":"done"}\n');
      controller.close();
      await expect(operation).rejects.toThrow();
    });
  }

  it("keeps JSON rollout fallback capped at a week", async () => {
    const gateway = spyOn(GatewayClient, "gatewayFetch").mockResolvedValue(Response.json({
      ...first, options: [...first.options, { days: 30, before, count: 2 }],
    }));
    restoreGateway = () => gateway.mockRestore();
    expect(await fetchReadAgeOptions(oauth, { kind: "subscribed" }, "UTC")).toEqual(first);
  });
});
