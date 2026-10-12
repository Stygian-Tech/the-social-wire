export type ImagePoint = { x: number; y: number };
export type ImageSize = { width: number; height: number };
export type ImageTransform = ImagePoint & { scale: number };
export const INITIAL_IMAGE_TRANSFORM: ImageTransform = { scale: 1, x: 0, y: 0 };
export const MAX_IMAGE_SCALE = 5;

/** Dimensions of the original image fitted inside the viewer without cropping. */
export function fittedImageSize(
  image: ImageSize,
  viewport: ImageSize,
): ImageSize {
  if (
    image.width <= 0 ||
    image.height <= 0 ||
    viewport.width <= 0 ||
    viewport.height <= 0
  )
    return { width: 0, height: 0 };
  const factor = Math.min(
    viewport.width / image.width,
    viewport.height / image.height,
    1,
  );
  return { width: image.width * factor, height: image.height * factor };
}

export function clampImageTransform(
  value: ImageTransform,
  image: ImageSize,
  viewport: ImageSize,
): ImageTransform {
  const scale = Number.isFinite(value.scale)
    ? Math.min(MAX_IMAGE_SCALE, Math.max(1, value.scale))
    : 1;
  const fitted = fittedImageSize(image, viewport);
  const limitX = Math.max(0, (fitted.width * scale - viewport.width) / 2);
  const limitY = Math.max(0, (fitted.height * scale - viewport.height) / 2);
  return {
    scale,
    x: Math.max(
      -limitX,
      Math.min(limitX, Number.isFinite(value.x) ? value.x : 0),
    ),
    y: Math.max(
      -limitY,
      Math.min(limitY, Number.isFinite(value.y) ? value.y : 0),
    ),
  };
}

/** Anchor is measured from the center of the viewer. */
export function zoomImageAt(
  value: ImageTransform,
  scale: number,
  anchor: ImagePoint,
  image: ImageSize,
  viewport: ImageSize,
): ImageTransform {
  const nextScale = Math.min(MAX_IMAGE_SCALE, Math.max(1, scale));
  const ratio = nextScale / value.scale;
  return clampImageTransform(
    {
      scale: nextScale,
      x: anchor.x - (anchor.x - value.x) * ratio,
      y: anchor.y - (anchor.y - value.y) * ratio,
    },
    image,
    viewport,
  );
}

export function pinchImage(
  value: ImageTransform,
  previous: readonly ImagePoint[],
  next: readonly ImagePoint[],
  image: ImageSize,
  viewport: ImageSize,
): ImageTransform {
  if (previous.length < 2 || next.length < 2) return value;
  const distance = (points: readonly ImagePoint[]) =>
    Math.hypot(points[0].x - points[1].x, points[0].y - points[1].y);
  const center = (points: readonly ImagePoint[]) => ({
    x: (points[0].x + points[1].x) / 2,
    y: (points[0].y + points[1].y) / 2,
  });
  const before = distance(previous);
  if (before < 1) return value;
  const oldCenter = center(previous);
  const newCenter = center(next);
  const zoomed = zoomImageAt(
    value,
    (value.scale * distance(next)) / before,
    oldCenter,
    image,
    viewport,
  );
  return clampImageTransform(
    {
      ...zoomed,
      x: zoomed.x + newCenter.x - oldCenter.x,
      y: zoomed.y + newCenter.y - oldCenter.y,
    },
    image,
    viewport,
  );
}
