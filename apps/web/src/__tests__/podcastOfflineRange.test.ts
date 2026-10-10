import { describe, expect, it } from "bun:test";
import { readFileSync } from "node:fs";
import { runInNewContext } from "node:vm";
function mediaHandler() {
  const events: Record<
    string,
    (event: {
      request: Request;
      respondWith: (response: Promise<Response>) => void;
    }) => void
  > = {};
  const blob = new Blob([new Uint8Array([0, 1, 2, 3, 4, 5])], {
    type: "audio/mpeg",
  });
  const indexedDB = {
    open: () => {
      const request: Record<string, unknown> = {};
      const db = {
        close: () => {},
        transaction: () => ({
          objectStore: () => ({
            get: (key: string) => {
              const read: Record<string, unknown> = {
                result:
                  key === "did:plc:listener\nepisode"
                    ? { media: blob }
                    : undefined,
              };
              queueMicrotask(() => (read.onsuccess as () => void)());
              return read;
            },
          }),
        }),
      };
      request.result = db;
      queueMicrotask(() => (request.onsuccess as () => void)());
      return request;
    },
  };
  const self = {
    location: { origin: "https://wire.test" },
    addEventListener: (name: string, handler: (typeof events)[string]) => {
      events[name] = handler;
    },
  };
  runInNewContext(
    readFileSync(`${import.meta.dir}/../../public/podcast-sw.js`, "utf8"),
    { self, indexedDB, Blob, Response, URL, Promise, Number, queueMicrotask },
  );
  return async (range?: string, viewer = "did:plc:listener") => {
    let response: Promise<Response> | undefined;
    events.fetch({
      request: new Request(
        `https://wire.test/podcasts/offline-media?viewer=${encodeURIComponent(viewer)}&episodeId=episode`,
        { headers: range ? { Range: range } : {} },
      ),
      respondWith: (value) => {
        response = value;
      },
    });
    return response!;
  };
}
describe("Viewer-scoped podcast offline Range playback", () => {
  it("returns exact partial bytes and suffix ranges for audio seeking", async () => {
    const handler = mediaHandler();
    const response = await handler("bytes=2-4");
    expect(response.status).toBe(206);
    expect(response.headers.get("content-range")).toBe("bytes 2-4/6");
    expect([...new Uint8Array(await response.arrayBuffer())]).toEqual([
      2, 3, 4,
    ]);
    expect([
      ...new Uint8Array(await (await handler("bytes=-2")).arrayBuffer()),
    ]).toEqual([4, 5]);
  });
  it("rejects malformed/out-of-bounds ranges and another viewer's download", async () => {
    const handler = mediaHandler();
    expect((await handler("bytes=8-10")).status).toBe(416);
    expect((await handler("bytes=0-2,4-5")).status).toBe(416);
    expect((await handler(undefined, "did:plc:other")).status).toBe(404);
  });
});
