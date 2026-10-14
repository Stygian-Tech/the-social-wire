import { afterEach, expect, it, spyOn } from "bun:test";
import { prepareComposerPhoto } from "@/lib/prepareComposerPhoto";
import type { ComposerPhoto } from "@/lib/composerMedia";

const restores: (() => void)[] = [];
afterEach(() => restores.splice(0).reverse().forEach(restore => restore()));
const photo = (original: Blob): ComposerPhoto => ({ id: "stable-photo", name: "photo.jpg", original, alt: "Original description", status: "preparing" });

it("normalizes JPEG orientation, constrains dimensions, and preserves attachment identity and alt text", async () => {
  let closed = false;
  const original = Object.getOwnPropertyDescriptor(globalThis, "createImageBitmap");
  Object.defineProperty(globalThis, "createImageBitmap", { configurable: true, value: async (_blob: Blob, options: ImageBitmapOptions) => { expect(options.imageOrientation).toBe("from-image"); return { width: 8000, height: 4000, close: () => { closed = true; } }; } });
  restores.push(() => { if (original) Object.defineProperty(globalThis, "createImageBitmap", original); else Reflect.deleteProperty(globalThis, "createImageBitmap"); });
  const draw = spyOn(window.HTMLCanvasElement.prototype, "getContext").mockReturnValue({ drawImage: () => {} } as unknown as CanvasRenderingContext2D);
  const encode = spyOn(window.HTMLCanvasElement.prototype, "toBlob").mockImplementation(function(callback, type) { callback(new Blob(["prepared"], { type })); });
  restores.push(() => draw.mockRestore(), () => encode.mockRestore());
  const ready = await prepareComposerPhoto(photo(new Blob([new Uint8Array([255, 216, 255, 0])], { type: "image/jpeg" })));
  expect(ready).toMatchObject({ id: "stable-photo", width: 4000, height: 2000, alt: "Original description", status: "ready" });
  expect(ready.blob?.type).toBe("image/jpeg");
  expect(closed).toBe(true);
});

it("rejects GIFs and animated PNGs before decoding rather than flattening animation", async () => {
  await expect(prepareComposerPhoto(photo(new Blob(["GIF89a"], { type: "image/jpeg" })))).rejects.toThrow("Use The GIF Picker");
  const bytes = new Uint8Array(20);
  bytes.set([137, 80, 78, 71, 13, 10, 26, 10]);
  bytes.set([97, 99, 84, 76], 12);
  await expect(prepareComposerPhoto(photo(new Blob([bytes], { type: "image/png" })))).rejects.toThrow("Animated PNG");
});
