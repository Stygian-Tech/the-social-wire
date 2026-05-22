"use client";

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

/** Remote image with IndexedDB-backed blob cache and `no-referrer`. */
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
