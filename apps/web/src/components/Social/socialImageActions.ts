import { socialHttpsUrl } from "./socialUrls";

export function socialImageFetchUrl(source: string): string {
  const url = socialHttpsUrl(source);
  if (!url) throw new Error("This image URL is unavailable.");
  return new URL(url).hostname === "cdn.bsky.app"
    ? `/api/bluesky-card-thumb?${new URLSearchParams({ url, purpose: "original" })}`
    : url;
}

export async function fetchSocialImageBlob(
  source: string,
  signal?: AbortSignal,
): Promise<Blob> {
  const url = socialImageFetchUrl(source);
  let response: Response;
  try {
    response = await fetch(url, {
      signal,
      credentials: "omit",
      referrerPolicy: "no-referrer",
    });
  } catch (error) {
    signal?.throwIfAborted();
    if (url.startsWith("/")) throw error;
    response = await fetch(
      `/api/bluesky-card-thumb?${new URLSearchParams({ url, purpose: "original" })}`,
      { signal, credentials: "omit" },
    );
  }
  if (!response.ok)
    throw new Error(
      "The original image could not be downloaded. Please try again.",
    );
  const blob = await response.blob();
  signal?.throwIfAborted();
  if (!blob.size || !blob.type.startsWith("image/"))
    throw new Error("The original image is unavailable.");
  return blob;
}

export function socialImageFilename(blob: Blob): string {
  const extensions: Record<string, string> = {
    "image/jpeg": "jpg",
    "image/png": "png",
    "image/gif": "gif",
    "image/webp": "webp",
    "image/avif": "avif",
    "image/svg+xml": "svg",
    "image/heic": "heic",
  };
  return `social-wire-image.${extensions[blob.type] ?? "image"}`;
}

export function saveSocialImageBlob(blob: Blob): void {
  const url = URL.createObjectURL(blob);
  const link = document.createElement("a");
  link.href = url;
  link.download = socialImageFilename(blob);
  document.body.append(link);
  try {
    link.click();
  } finally {
    link.remove();
    setTimeout(() => URL.revokeObjectURL(url), 1000);
  }
}

async function imageBlobAsPng(blob: Blob, signal?: AbortSignal): Promise<Blob> {
  const url = URL.createObjectURL(blob);
  const image = new Image();
  let onAbort: (() => void) | undefined;
  try {
    signal?.throwIfAborted();
    image.src = url;
    const decoded = image.decode();
    if (signal) {
      await Promise.race([
        decoded,
        new Promise<never>((_resolve, reject) => {
          onAbort = () => {
            image.src = "";
            reject(signal.reason);
          };
          signal.addEventListener("abort", onAbort, { once: true });
        }),
      ]);
    } else await decoded;
    signal?.throwIfAborted();
    const canvas = document.createElement("canvas");
    canvas.width = image.naturalWidth;
    canvas.height = image.naturalHeight;
    const context = canvas.getContext("2d");
    if (!context)
      throw new Error("This browser cannot prepare images for the clipboard.");
    context.drawImage(image, 0, 0);
    return await new Promise<Blob>((resolve, reject) =>
      canvas.toBlob(
        (value) =>
          value
            ? resolve(value)
            : reject(new Error("This image cannot be copied.")),
        "image/png",
      ),
    );
  } finally {
    if (onAbort) signal?.removeEventListener("abort", onAbort);
    URL.revokeObjectURL(url);
  }
}

/** Only clipboard formats may be converted; display and downloads retain original bytes. */
export async function copySocialImageBlob(
  blob: Blob,
  signal?: AbortSignal,
): Promise<void> {
  if (typeof ClipboardItem === "undefined" || !navigator.clipboard?.write)
    throw new Error(
      "Copy Image is unavailable in this browser. Use Save Image instead.",
    );
  signal?.throwIfAborted();
  const supported =
    blob.type === "image/png" ||
    (typeof ClipboardItem.supports === "function" &&
      ClipboardItem.supports(blob.type));
  const type = supported ? blob.type : "image/png";
  const data = supported
    ? blob
    : imageBlobAsPng(blob, signal).then((image) => {
        signal?.throwIfAborted();
        return image;
      });
  if (data instanceof Promise) void data.catch(() => {});
  // Call write before awaiting conversion to retain the click's user activation.
  await navigator.clipboard.write([new ClipboardItem({ [type]: data })]);
  signal?.throwIfAborted();
}
