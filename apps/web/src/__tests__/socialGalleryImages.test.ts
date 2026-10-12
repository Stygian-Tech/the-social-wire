import { describe, expect, it } from "bun:test";
import { socialGalleryImages } from "@/components/Social/socialGalleryImages";

const image = { $type: "app.bsky.embed.gallery#viewImage", thumbnail: "https://cdn.example/thumb.jpg", fullsize: "https://cdn.example/full.jpg", alt: "Editor screenshot", aspectRatio: { width: 3012, height: 1856 } };
const gallery = (items: unknown[]) => ({ $type: "app.bsky.embed.gallery#view", items });
describe("Bluesky gallery images", () => {
  it("adapts galleries exceeding the legacy four-image limit with alt and ratio intact", () => {
    const images = socialGalleryImages(gallery(Array(6).fill(image)));
    expect(images).toHaveLength(6);
    expect(images?.[0]).toEqual({ thumb: image.thumbnail, fullsize: image.fullsize, alt: image.alt, aspectRatio: image.aspectRatio });
  });
  it("ignores unknown, malformed and unsafe items without dropping valid siblings", () => {
    expect(socialGalleryImages(gallery([null, {}, { ...image, $type: "unknown" }, { ...image, thumbnail: "javascript:alert(1)" }, { ...image, fullsize: "http://cdn.example/a" }, image]))).toHaveLength(1);
    expect(socialGalleryImages(gallery([{ ...image, aspectRatio: { width: -1, height: 0 } }]))?.[0].aspectRatio).toBeUndefined();
    expect(socialGalleryImages({ $type: "app.bsky.embed.gallery#view" })).toEqual([]);
    expect(socialGalleryImages(undefined)).toBeUndefined();
    expect(socialGalleryImages({ $type: "app.bsky.embed.images#view" })).toBeUndefined();
  });
  it("bounds remote gallery size to the schema ceiling", () => {
    expect(socialGalleryImages(gallery(Array(30).fill(image)))).toHaveLength(20);
  });
});
