"use client";

/* eslint-disable @next/next/no-img-element -- The full-size publisher image is displayed without transcoding. */
import {
  useCallback,
  useEffect,
  useRef,
  useState,
  type PointerEvent,
} from "react";
import {
  ChevronLeft,
  ChevronRight,
  Copy,
  Download,
  RotateCcw,
  ZoomIn,
  ZoomOut,
} from "lucide-react";
import type { AppBskyEmbedImages } from "@atproto/api";
import { Button } from "@/components/ui/button";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogTitle,
} from "@/components/ui/dialog";
import { socialHttpsUrl } from "./socialUrls";
import {
  clampImageTransform,
  fittedImageSize,
  INITIAL_IMAGE_TRANSFORM,
  pinchImage,
  zoomImageAt,
  type ImagePoint,
  type ImageSize,
  type ImageTransform,
} from "./socialImageTransform";
import {
  copySocialImageBlob,
  fetchSocialImageBlob,
  saveSocialImageBlob,
} from "./socialImageActions";

export function SocialImageDialog({
  image,
  index,
  total,
  onClose,
  onPrevious,
  onNext,
}: {
  image: AppBskyEmbedImages.ViewImage;
  index: number;
  total: number;
  onClose: () => void;
  onPrevious?: () => void;
  onNext?: () => void;
}) {
  const source = socialHttpsUrl(image.fullsize) ?? socialHttpsUrl(image.thumb)!;
  const viewportRef = useRef<HTMLDivElement>(null);
  const [viewport, setViewport] = useState<HTMLDivElement | null>(null);
  const attachViewport = useCallback((node: HTMLDivElement | null) => {
    viewportRef.current = node;
    setViewport(node);
  }, []);
  const pointers = useRef(new Map<number, ImagePoint>());
  const abortRef = useRef<AbortController | null>(null);
  const transformRef = useRef<ImageTransform>(INITIAL_IMAGE_TRANSFORM);
  const sizeRef = useRef<ImageSize>({
    width: image.aspectRatio?.width ?? 0,
    height: image.aspectRatio?.height ?? 0,
  });
  const viewportSize = useRef<ImageSize>({ width: 0, height: 0 });
  const [transform, setTransform] = useState(INITIAL_IMAGE_TRANSFORM);
  const [fitted, setFitted] = useState<ImageSize>();
  const [blob, setBlob] = useState<Blob>();
  const [busy, setBusy] = useState<"save" | "copy" | null>(null);
  const [message, setMessage] = useState<string>();
  const [error, setError] = useState<string>();

  function update(value: ImageTransform) {
    const clamped = clampImageTransform(
      value,
      sizeRef.current,
      viewportSize.current,
    );
    transformRef.current = clamped;
    setTransform(clamped);
  }
  function measure() {
    const rect = viewportRef.current?.getBoundingClientRect();
    if (!rect) return;
    viewportSize.current = { width: rect.width, height: rect.height };
    setFitted(fittedImageSize(sizeRef.current, viewportSize.current));
    update(transformRef.current);
  }
  function point(clientX: number, clientY: number): ImagePoint {
    const rect = viewportRef.current!.getBoundingClientRect();
    return {
      x: clientX - rect.left - rect.width / 2,
      y: clientY - rect.top - rect.height / 2,
    };
  }
  useEffect(() => {
    const controller = new AbortController();
    abortRef.current = controller;
    const activePointers = pointers.current;
    void fetchSocialImageBlob(source, controller.signal)
      .then((value) => {
        if (!controller.signal.aborted) setBlob(value);
      })
      .catch(() => {
        if (!controller.signal.aborted)
          setError(
            "The original image could not be loaded for Save or Copy. Use Save Image to retry.",
          );
      });
    return () => {
      controller.abort();
      activePointers.clear();
    };
  }, [source]);
  useEffect(() => {
    const element = viewport;
    if (!element) return;
    measure();
    const observer =
      typeof ResizeObserver === "undefined"
        ? undefined
        : new ResizeObserver(measure);
    observer?.observe(element);
    const wheel = (event: WheelEvent) => {
      event.preventDefault();
      update(
        zoomImageAt(
          transformRef.current,
          transformRef.current.scale * Math.exp(-event.deltaY * 0.002),
          point(event.clientX, event.clientY),
          sizeRef.current,
          viewportSize.current,
        ),
      );
    };
    element.addEventListener("wheel", wheel, { passive: false });
    return () => {
      observer?.disconnect();
      element.removeEventListener("wheel", wheel);
    };
    // Geometry and gestures use refs so native listeners never capture an old transform.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [viewport]);

  function pointerDown(event: PointerEvent<HTMLDivElement>) {
    if (event.pointerType === "mouse" && event.button !== 0) return;
    event.preventDefault();
    event.currentTarget.setPointerCapture?.(event.pointerId);
    pointers.current.set(event.pointerId, point(event.clientX, event.clientY));
  }
  function pointerMove(event: PointerEvent<HTMLDivElement>) {
    const before = pointers.current.get(event.pointerId);
    if (!before) return;
    const previous = [...pointers.current.values()];
    const after = point(event.clientX, event.clientY);
    pointers.current.set(event.pointerId, after);
    if (pointers.current.size >= 2)
      update(
        pinchImage(
          transformRef.current,
          previous,
          [...pointers.current.values()],
          sizeRef.current,
          viewportSize.current,
        ),
      );
    else
      update({
        ...transformRef.current,
        x: transformRef.current.x + after.x - before.x,
        y: transformRef.current.y + after.y - before.y,
      });
  }
  function pointerEnd(event: PointerEvent<HTMLDivElement>) {
    pointers.current.delete(event.pointerId);
    if (event.currentTarget.hasPointerCapture?.(event.pointerId))
      event.currentTarget.releasePointerCapture(event.pointerId);
  }
  function zoom(factor: number) {
    update(
      zoomImageAt(
        transformRef.current,
        transformRef.current.scale * factor,
        { x: 0, y: 0 },
        sizeRef.current,
        viewportSize.current,
      ),
    );
  }
  async function mediaAction(action: "save" | "copy") {
    setBusy(action);
    setError(undefined);
    setMessage(undefined);
    const signal = abortRef.current?.signal;
    try {
      const original = blob ?? (await fetchSocialImageBlob(source, signal));
      signal?.throwIfAborted();
      if (action === "save") saveSocialImageBlob(original);
      else await copySocialImageBlob(original, signal);
      if (!signal?.aborted) {
        setBlob(original);
        setMessage(
          action === "save" ? "Image download started." : "Image copied.",
        );
      }
    } catch (cause) {
      if (!signal?.aborted)
        setError(
          cause instanceof Error
            ? cause.message
            : "This image could not be saved or copied.",
        );
    } finally {
      if (!signal?.aborted) setBusy(null);
    }
  }
  return (
    <Dialog
      open
      onOpenChange={(open) => {
        if (!open) onClose();
      }}
    >
      <DialogContent
        className="flex max-h-[calc(100dvh-2rem)] w-[calc(100vw-2rem)] flex-col gap-3 sm:max-w-5xl"
        onClick={(event) => event.stopPropagation()}
      >
        <DialogTitle className="pr-8">
          Image {index + 1} of {total}
        </DialogTitle>
        <DialogDescription className="sr-only">
          Use pinch or scroll to zoom, then drag or use arrow keys to pan. Zoom
          controls and Reset Zoom are also available.
        </DialogDescription>
        <div className="flex flex-wrap items-center gap-2">
          <Button
            variant="outline"
            size="icon-sm"
            aria-label="Zoom Out"
            disabled={transform.scale <= 1}
            onClick={() => zoom(1 / 1.5)}
          >
            <ZoomOut />
          </Button>
          <Button
            variant="outline"
            size="icon-sm"
            aria-label="Zoom In"
            disabled={transform.scale >= 5}
            onClick={() => zoom(1.5)}
          >
            <ZoomIn />
          </Button>
          <Button
            variant="outline"
            size="sm"
            onClick={() => update(INITIAL_IMAGE_TRANSFORM)}
          >
            <RotateCcw data-icon="inline-start" />
            Reset Zoom
          </Button>
          <span className="text-xs text-muted-foreground" aria-live="polite">
            {Math.round(transform.scale * 100)}%
          </span>
          <Button
            variant="outline"
            size="sm"
            disabled={!!busy}
            onClick={() => {
              void mediaAction("save");
            }}
          >
            <Download data-icon="inline-start" />
            {busy === "save" ? "Saving…" : "Save Image"}
          </Button>
          <Button
            variant="outline"
            size="sm"
            disabled={!!busy || !blob}
            onClick={() => {
              void mediaAction("copy");
            }}
          >
            <Copy data-icon="inline-start" />
            {busy === "copy" ? "Copying…" : "Copy Image"}
          </Button>
          {total > 1 ? (
            <div className="ml-auto flex gap-1">
              <Button
                variant="outline"
                size="icon-sm"
                aria-label="Previous Image"
                disabled={!onPrevious}
                onClick={onPrevious}
              >
                <ChevronLeft />
              </Button>
              <Button
                variant="outline"
                size="icon-sm"
                aria-label="Next Image"
                disabled={!onNext}
                onClick={onNext}
              >
                <ChevronRight />
              </Button>
            </div>
          ) : null}
        </div>
        <div
          ref={attachViewport}
          tabIndex={0}
          role="group"
          aria-label="Image Viewer"
          onKeyDown={(event) => {
            const delta = {
              ArrowLeft: { x: 40, y: 0 },
              ArrowRight: { x: -40, y: 0 },
              ArrowUp: { x: 0, y: 40 },
              ArrowDown: { x: 0, y: -40 },
            }[event.key];
            if (delta) {
              event.preventDefault();
              update({
                ...transformRef.current,
                x: transformRef.current.x + delta.x,
                y: transformRef.current.y + delta.y,
              });
            }
          }}
          className="relative flex h-[min(65dvh,44rem)] min-h-48 items-center justify-center overflow-hidden rounded-xl"
          style={{
            touchAction: "none",
            cursor: transform.scale > 1 ? "grab" : "zoom-in",
          }}
          onPointerDown={pointerDown}
          onPointerMove={pointerMove}
          onPointerUp={pointerEnd}
          onPointerCancel={pointerEnd}
          onLostPointerCapture={pointerEnd}
          onDoubleClick={() =>
            transform.scale > 1 ? update(INITIAL_IMAGE_TRANSFORM) : zoom(2)
          }
        >
          <img
            src={source}
            alt={image.alt}
            draggable={false}
            referrerPolicy="no-referrer"
            onLoad={(event) => {
              sizeRef.current = {
                width: event.currentTarget.naturalWidth,
                height: event.currentTarget.naturalHeight,
              };
              measure();
            }}
            onError={() => setError("This image could not be displayed.")}
            className="block max-h-full max-w-full select-none object-contain"
            style={{
              width: fitted?.width || undefined,
              height: fitted?.height || undefined,
              transform: `translate(${transform.x}px, ${transform.y}px) scale(${transform.scale})`,
            }}
          />
        </div>
        {image.alt ? (
          <p className="max-h-20 overflow-y-auto text-sm text-muted-foreground">
            {image.alt}
          </p>
        ) : null}
        {error ? (
          <p role="alert" className="text-sm text-destructive">
            {error}
          </p>
        ) : message ? (
          <p role="status" className="text-sm text-muted-foreground">
            {message}
          </p>
        ) : null}
      </DialogContent>
    </Dialog>
  );
}
