import { describe, expect, it } from "bun:test";
import {
  clampImageTransform,
  fittedImageSize,
  INITIAL_IMAGE_TRANSFORM,
  pinchImage,
  zoomImageAt,
} from "@/components/Social/socialImageTransform";

const image = { width: 1600, height: 1200 };
const viewport = { width: 800, height: 600 };
describe("Social Image Gestures", () => {
  it("fits portrait/landscape originals without cropping or enlarging small images", () => {
    expect(fittedImageSize(image, viewport)).toEqual(viewport);
    expect(fittedImageSize({ width: 600, height: 1200 }, viewport)).toEqual({
      width: 300,
      height: 600,
    });
    expect(fittedImageSize({ width: 80, height: 60 }, viewport)).toEqual({
      width: 80,
      height: 60,
    });
    expect(fittedImageSize(image, { width: 0, height: 0 })).toEqual({
      width: 0,
      height: 0,
    });
  });
  it("clamps pan to actual image edges and resets translation at fit", () => {
    expect(
      clampImageTransform({ scale: 2, x: 900, y: -900 }, image, viewport),
    ).toEqual({ scale: 2, x: 400, y: -300 });
    expect(
      clampImageTransform({ scale: 1, x: 400, y: 300 }, image, viewport),
    ).toEqual(INITIAL_IMAGE_TRANSFORM);
    expect(
      clampImageTransform({ scale: 20, x: Infinity, y: NaN }, image, viewport),
    ).toEqual({ scale: 5, x: 0, y: 0 });
    expect(
      clampImageTransform(
        { scale: 2, x: 300, y: 0 },
        { width: 300, height: 1200 },
        viewport,
      ).x,
    ).toBe(0);
  });
  it("keeps the zoom anchor stable and clamps repeated zoom out", () => {
    expect(
      zoomImageAt(
        INITIAL_IMAGE_TRANSFORM,
        2,
        { x: 100, y: 50 },
        image,
        viewport,
      ),
    ).toEqual({ scale: 2, x: -100, y: -50 });
    expect(
      zoomImageAt(
        { scale: 2, x: -100, y: -50 },
        1,
        { x: 100, y: 50 },
        image,
        viewport,
      ),
    ).toEqual(INITIAL_IMAGE_TRANSFORM);
    expect(
      zoomImageAt(INITIAL_IMAGE_TRANSFORM, 0, { x: 0, y: 0 }, image, viewport),
    ).toEqual(INITIAL_IMAGE_TRANSFORM);
  });
  it("applies pinch distance and midpoint movement together without a first-touch jump", () => {
    expect(
      pinchImage(
        INITIAL_IMAGE_TRANSFORM,
        [
          { x: -50, y: 0 },
          { x: 50, y: 0 },
        ],
        [
          { x: -90, y: 20 },
          { x: 110, y: 20 },
        ],
        image,
        viewport,
      ),
    ).toEqual({ scale: 2, x: 10, y: 20 });
    expect(
      pinchImage(
        INITIAL_IMAGE_TRANSFORM,
        [
          { x: 0, y: 0 },
          { x: 0, y: 0 },
        ],
        [
          { x: -90, y: 0 },
          { x: 90, y: 0 },
        ],
        image,
        viewport,
      ),
    ).toEqual(INITIAL_IMAGE_TRANSFORM);
  });
});
