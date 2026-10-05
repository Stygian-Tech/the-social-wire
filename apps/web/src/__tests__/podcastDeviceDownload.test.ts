import { afterEach, describe, expect, it, mock } from "bun:test";
import { podcastAudioFilename, savePodcastAudioResponseToDevice, savePodcastAudioToDevice } from "@/lib/podcasts/deviceDownload";
import type { PodcastEpisode } from "@/lib/podcasts/client";
const episode: PodcastEpisode = { id: "episode", showId: "show", title: "A / Podcast: Episode", publishedAt: "2026-10-05", audioUrl: "https://publisher.test/audio?token=secret", audioMimeType: "audio/mpeg", transcripts: [] };
const oldWindow = Object.getOwnPropertyDescriptor(globalThis, "window");
const oldIndexedDB = Object.getOwnPropertyDescriptor(globalThis, "indexedDB");
const oldDocument = Object.getOwnPropertyDescriptor(globalThis, "document");
afterEach(() => {
  if (oldIndexedDB) Object.defineProperty(globalThis, "indexedDB", oldIndexedDB); else Reflect.deleteProperty(globalThis, "indexedDB");
  if (oldWindow) Object.defineProperty(globalThis, "window", oldWindow); else Reflect.deleteProperty(globalThis, "window");
  if (oldDocument) Object.defineProperty(globalThis, "document", oldDocument); else Reflect.deleteProperty(globalThis, "document");
});
function pickerEnvironment(write = mock(async (data: Uint8Array) => { void data; })) {
  const close = mock(async () => {});
  const abort = mock(async () => {});
  const picker = mock(async () => ({ createWritable: async () => ({ write, close, abort }) }));
  Object.defineProperty(globalThis, "window", { configurable: true, value: { showSaveFilePicker: picker } });
  return { write, close, abort, picker };
}
describe("Save podcast audio to a device", () => {
  it("opens the picker before loading protected media and streams bytes with progress", async () => {
    const env = pickerEnvironment();
    const progress = mock((received: number, total?: number) => { void received; void total; });
    const load = mock(async () => {
      expect(env.picker).toHaveBeenCalledTimes(1);
      return new Response(new ReadableStream({ start(controller) { controller.enqueue(new Uint8Array([1, 2])); controller.enqueue(new Uint8Array([3])); controller.close(); } }), { headers: { "Content-Type": "audio/mpeg", "Content-Length": "3" } });
    });
    expect(await savePodcastAudioResponseToDevice(episode, load, { onProgress: progress })).toBe("saved");
    expect(env.write.mock.calls.map(([bytes]) => [...bytes])).toEqual([[1, 2], [3]]);
    expect(progress.mock.calls).toEqual([[2, 3], [3, 3]]);
    expect(env.close).toHaveBeenCalledTimes(1);
    expect(env.abort).not.toHaveBeenCalled();
  });
  it("does not fetch or fall back when the user dismisses the picker", async () => {
    Object.defineProperty(globalThis, "window", { configurable: true, value: { showSaveFilePicker: async () => { throw new DOMException("Dismissed", "AbortError"); } } });
    const load = mock(async () => new Response("audio"));
    expect(await savePodcastAudioResponseToDevice(episode, load)).toBe("cancelled");
    expect(load).not.toHaveBeenCalled();
  });
  it("aborts the destination when streaming fails instead of leaving a partial file", async () => {
    const env = pickerEnvironment(mock(async () => { throw new Error("Disk full"); }));
    await expect(savePodcastAudioResponseToDevice(episode, async () => new Response(new Uint8Array([1])))).rejects.toThrow("Disk full");
    expect(env.abort).toHaveBeenCalledTimes(1);
    expect(env.close).not.toHaveBeenCalled();
  });
  it("cancels an active transfer and never closes an incomplete audio file", async () => {
    const controller = new AbortController();
    const env = pickerEnvironment(mock(async () => { controller.abort(); }));
    expect(await savePodcastAudioResponseToDevice(episode, async () => new Response(new Uint8Array([1])), { signal: controller.signal })).toBe("cancelled");
    expect(env.abort).toHaveBeenCalled();
    expect(env.close).not.toHaveBeenCalled();
  });
  it("rejects protected-route errors, partial responses and non-audio payloads", async () => {
    pickerEnvironment();
    for (const response of [new Response("Unauthorized", { status: 401 }), new Response("partial", { status: 206 }), new Response("<html>login</html>", { headers: { "Content-Type": "text/html" } })]) {
      await expect(savePodcastAudioResponseToDevice(episode, async () => response)).rejects.toThrow();
    }
  });
  it("uses a local blob download in browsers without a save picker, never a tokenized media URL", async () => {
    Object.defineProperty(globalThis, "window", { configurable: true, value: {} });
    const click = mock(() => {});
    const anchor = { href: "", download: "", click, remove: mock(() => {}) };
    Object.defineProperty(globalThis, "document", { configurable: true, value: {
      createElement: () => anchor, body: { append: mock(() => {}) },
    } });
    const originalTimer = globalThis.setTimeout;
    let cleanup: (() => void) | undefined;
    globalThis.setTimeout = ((callback: () => void) => { cleanup = callback; return 1; }) as unknown as typeof setTimeout;
    try {
      expect(await savePodcastAudioResponseToDevice(episode, async () => new Response(new Uint8Array([1]), { headers: { "Content-Type": "audio/mpeg" } }))).toBe("saved");
      expect(anchor.href.startsWith("blob:")).toBe(true);
      expect(anchor.href.includes("secret")).toBe(false);
      expect(anchor.download).toBe("A  Podcast Episode.mp3");
      expect(click).toHaveBeenCalledTimes(1);
      expect(anchor.remove).toHaveBeenCalledTimes(1);
      cleanup?.();
    } finally { globalThis.setTimeout = originalTimer; }
  });
  it("exports only the current viewer's cached audio and fetches when that file is missing", async () => {
    let lookupKey = "";
    const local = new Blob([new Uint8Array([9, 8])], { type: "audio/mpeg" });
    Object.defineProperty(globalThis, "indexedDB", { configurable: true, value: { open() {
      const request: { result?: unknown; onsuccess?: () => void } = {};
      request.result = { close() {}, transaction() {
        const transaction: { oncomplete?: () => void; objectStore?: () => unknown } = {};
        transaction.objectStore = () => ({ get(key: string) {
          lookupKey = key;
          const read: { result?: unknown; onsuccess?: () => void } = { result: key === "did:plc:owner\nepisode" ? { media: local } : undefined };
          queueMicrotask(() => { read.onsuccess?.(); transaction.oncomplete?.(); });
          return read;
        } });
        return transaction;
      } };
      queueMicrotask(() => request.onsuccess?.());
      return request;
    } } });
    const cached = pickerEnvironment();
    const load = mock(async () => new Response(new Uint8Array([1])));
    expect(await savePodcastAudioToDevice("did:plc:owner", episode, load)).toBe("saved");
    expect(lookupKey).toBe("did:plc:owner\nepisode");
    expect(cached.write.mock.calls.map(([bytes]) => [...bytes])).toEqual([[9, 8]]);
    expect(load).not.toHaveBeenCalled();
    const other = pickerEnvironment();
    expect(await savePodcastAudioToDevice("did:plc:other", episode, load)).toBe("saved");
    expect(lookupKey).toBe("did:plc:other\nepisode");
    expect(other.write.mock.calls.map(([bytes]) => [...bytes])).toEqual([[1]]);
    expect(load).toHaveBeenCalledTimes(1);
  });
  it("sanitizes filenames and retains the supported source audio format", () => {
    expect(podcastAudioFilename(episode)).toBe("A  Podcast Episode.mp3");
    expect(podcastAudioFilename({ ...episode, title: "../", audioMimeType: "audio/mp4" })).toBe("Podcast Episode.m4a");
  });
});
