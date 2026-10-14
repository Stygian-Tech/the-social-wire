import type { ComposerPhoto } from "./composerMedia";

const MAX_BYTES = 2_000_000;
const MAX_INPUT = 20_000_000;

/** Decode/re-encode to normalize EXIF orientation and strip location metadata. */
export async function prepareComposerPhoto(photo: ComposerPhoto): Promise<ComposerPhoto> {
  const head = new Uint8Array(await photo.original.slice(0, 16).arrayBuffer());
  const jpeg = head[0] === 255 && head[1] === 216 && head[2] === 255;
  const png = head[0] === 137 && head[1] === 80 && head[2] === 78 && head[3] === 71;
  if (!jpeg && !png) throw new Error("Choose A JPEG Or PNG Photo. Use The GIF Picker For Animation.");
  if (!photo.original.size || photo.original.size > MAX_INPUT) throw new Error("Photo Must Be Smaller Than 20 MB");
  if (png) {
    const bytes = new Uint8Array(await photo.original.arrayBuffer());
    const view = new DataView(bytes.buffer);
    for (let offset = 8; offset + 12 <= bytes.length;) {
      const length = view.getUint32(offset);
      const name = String.fromCharCode(...bytes.slice(offset + 4, offset + 8));
      if (name === "acTL") throw new Error("Animated PNG Photos Are Not Supported. Use The GIF Picker.");
      if (name === "IHDR" && length >= 8 && view.getUint32(offset + 8) * view.getUint32(offset + 12) > 80_000_000) throw new Error("Photo Dimensions Are Too Large");
      offset += length + 12;
    }
  }
  const image = await createImageBitmap(photo.original, { imageOrientation: "from-image" });
  try {
    if (!image.width || !image.height || image.width * image.height > 80_000_000) throw new Error("Photo Dimensions Are Too Large");
    let scale = Math.min(1, 4000 / Math.max(image.width, image.height));
    const canvas = document.createElement("canvas");
    for (let attempt = 0; attempt < 5; attempt++) {
      canvas.width = Math.max(1, Math.round(image.width * scale));
      canvas.height = Math.max(1, Math.round(image.height * scale));
      const context = canvas.getContext("2d");
      if (!context) throw new Error("Photo Preparation Is Unavailable");
      context.drawImage(image, 0, 0, canvas.width, canvas.height);
      const blob = await new Promise<Blob | null>(resolve => canvas.toBlob(resolve, png ? "image/png" : "image/jpeg", 0.88 - attempt * 0.08));
      if (blob && blob.size > 0 && blob.size <= MAX_BYTES) return { ...photo, blob, width: canvas.width, height: canvas.height, status: "ready", error: undefined };
      scale *= 0.75;
    }
    throw new Error("Photo Could Not Be Compressed To The Upload Limit");
  } finally { image.close(); }
}
