"use client";

import { useEffect, useRef } from "react";

import { useCachedImageUrl } from "@/hooks/useCachedImageUrl";

interface CachedImageProps {
  src?: string | null;
  alt: string;
  width: number;
  height: number;
  className?: string;
  loading?: "eager" | "lazy";
  onError?: () => void;
}

/** Remote image: same-origin IndexedDB blob cache; cross-origin direct `src` (no CORS fetch). */
export function CachedImage({
  src,
  alt,
  width,
  height,
  className = "",
  loading = "lazy",
  onError,
}: CachedImageProps) {
  const { objectUrl, failed } = useCachedImageUrl(src);
  const reportedFailureSrc = useRef<string | null>(null);

  useEffect(() => {
    const normalizedSrc = src?.trim() || null;
    if (!failed) {
      if (reportedFailureSrc.current === normalizedSrc) {
        reportedFailureSrc.current = null;
      }
      return;
    }
    if (reportedFailureSrc.current === normalizedSrc) return;
    reportedFailureSrc.current = normalizedSrc;
    onError?.();
  }, [failed, onError, src]);

  if (!objectUrl || failed) {
    return null;
  }

  return (
    /* eslint-disable-next-line @next/next/no-img-element -- arbitrary publisher / PDS URLs */
    <img
      src={objectUrl}
      alt={alt}
      width={width}
      height={height}
      loading={loading}
      decoding="async"
      referrerPolicy="no-referrer"
      className={className}
      onError={() => onError?.()}
    />
  );
}
