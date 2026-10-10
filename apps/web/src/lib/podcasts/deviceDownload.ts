import type { PodcastEpisode } from "./client";
import { getPodcastDownload } from "./offline";

type AudioDestination = {
  write(data: Uint8Array): Promise<void>;
  close(): Promise<void>;
  abort(reason?: unknown): Promise<void>;
};
type SavePicker = (options: {
  suggestedName: string;
  types: { description: string; accept: Record<string, string[]> }[];
}) => Promise<{ createWritable(): Promise<AudioDestination> }>;
export type PodcastDeviceSaveOptions = {
  signal?: AbortSignal;
  onProgress?: (receivedBytes: number, totalBytes?: number) => void;
};

export function podcastAudioFilename(episode: PodcastEpisode): string {
  const mime = episode.audioMimeType?.split(";")[0].trim().toLowerCase();
  const extension = ({
    "audio/mp4": "m4a", "audio/x-m4a": "m4a", "audio/aac": "aac",
    "audio/ogg": "ogg", "audio/opus": "opus", "audio/wav": "wav",
    "audio/x-wav": "wav", "audio/flac": "flac", "audio/webm": "webm",
  } as Record<string, string>)[mime ?? ""] ?? "mp3";
  const title = episode.title.replace(/[<>:"/\\|?*\x00-\x1f]/g, "").replace(/\.+$/g, "").trim().slice(0, 160);
  return `${title || "Podcast Episode"}.${extension}`;
}

/** Call directly from a click: the picker must open before authentication or IndexedDB awaits. */
export async function savePodcastAudioResponseToDevice(
  episode: PodcastEpisode,
  loadMedia: () => Promise<Response>,
  options: PodcastDeviceSaveOptions = {},
): Promise<"saved" | "cancelled"> {
  const filename = podcastAudioFilename(episode);
  const picker = (window as Window & { showSaveFilePicker?: SavePicker }).showSaveFilePicker;
  let destination: AudioDestination | undefined;
  let reader: ReadableStreamDefaultReader<Uint8Array> | undefined;
  const abort = () => {
    void reader?.cancel(options.signal?.reason).catch(() => {});
    void destination?.abort(options.signal?.reason).catch(() => {});
  };
  try {
    options.signal?.throwIfAborted();
    // Do not retry a dismissed picker as a download: cancellation is intentional.
    const handle = picker ? await picker.call(window, {
      suggestedName: filename,
      types: [{ description: "Podcast Audio", accept: {
        [episode.audioMimeType?.split(";")[0] || "audio/mpeg"]: [`.${filename.split(".").pop()}`],
      } }],
    }) : undefined;
    options.signal?.throwIfAborted();
    const response = await loadMedia();
    if (response.status !== 200) throw new Error(`Audio download failed (${response.status})`);
    const mime = response.headers.get("Content-Type")?.split(";")[0].trim().toLowerCase();
    if (mime && !mime.startsWith("audio/") && mime !== "application/octet-stream")
      throw new Error("The download did not contain audio");
    const length = Number(response.headers.get("Content-Length"));
    const total = Number.isSafeInteger(length) && length > 0 ? length : undefined;
    options.signal?.throwIfAborted();
    if (handle) {
      destination = await handle.createWritable();
      options.signal?.throwIfAborted();
      if (!response.body) throw new Error("The audio file was empty");
      reader = response.body.getReader();
      options.signal?.addEventListener("abort", abort, { once: true });
      let received = 0;
      while (true) {
        options.signal?.throwIfAborted();
        const { done, value } = await reader.read();
        if (done) break;
        await destination.write(value);
        received += value.byteLength;
        options.onProgress?.(received, total);
      }
      options.signal?.throwIfAborted();
      if (!received) throw new Error("The audio file was empty");
      await destination.close();
    } else {
      // Safari/Firefox do not expose a streaming file picker. Keep credentials in fetch,
      // then download a local blob URL rather than navigating to a protected API URL.
      const media = await response.blob();
      options.signal?.throwIfAborted();
      if (!media.size) throw new Error("The audio file was empty");
      options.onProgress?.(media.size, total);
      const url = URL.createObjectURL(media);
      const anchor = document.createElement("a");
      anchor.href = url;
      anchor.download = filename;
      document.body.append(anchor);
      anchor.click();
      anchor.remove();
      // Some browsers consume the URL asynchronously after the click.
      setTimeout(() => URL.revokeObjectURL(url), 60_000);
    }
    return "saved";
  } catch (error) {
    await reader?.cancel(error).catch(() => {});
    await destination?.abort(error).catch(() => {});
    if (options.signal?.aborted || (error instanceof DOMException && error.name === "AbortError"))
      return "cancelled";
    throw error;
  } finally {
    options.signal?.removeEventListener("abort", abort);
    reader?.releaseLock();
  }
}

/** fetchMedia must fetch the authenticated Gateway media route, never the publisher URL. */
export function savePodcastAudioToDevice(
  viewer: string,
  episode: PodcastEpisode,
  fetchMedia: () => Promise<Response>,
  options: PodcastDeviceSaveOptions = {},
): Promise<"saved" | "cancelled"> {
  if (!viewer.startsWith("did:")) return Promise.reject(new Error("Sign in to save podcast audio"));
  return savePodcastAudioResponseToDevice(episode, async () => {
    const local = await getPodcastDownload(viewer, episode.id).catch(() => undefined);
    if (local?.media instanceof Blob && local.media.size) return new Response(local.media);
    return fetchMedia();
  }, options);
}
