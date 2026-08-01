"use client";

import { useState } from "react";

import { useCachedImageUrl } from "@/hooks/useCachedImageUrl";

interface AvatarProps {
  src?: string | null;
  alt: string;
  size?: number;
  className?: string;
}

export function Avatar({ src, alt, size = 32, className = "" }: AvatarProps) {
  const { objectUrl, failed: cacheFailed } = useCachedImageUrl(src);
  const [failedObjectUrl, setFailedObjectUrl] = useState<string | null>(null);
  const showImage =
    Boolean(objectUrl) && !cacheFailed && failedObjectUrl !== objectUrl;

  if (showImage) {
    return (
      /* eslint-disable-next-line @next/next/no-img-element -- arbitrary PDS / publisher URLs */
      <img
        src={objectUrl}
        alt={alt}
        width={size}
        height={size}
        className={`rounded-full object-cover ${className}`}
        referrerPolicy="no-referrer"
        onError={() => setFailedObjectUrl(objectUrl ?? null)}
      />
    );
  }

  const initials = alt
    .split(" ")
    .slice(0, 2)
    .map((w) => w[0]?.toUpperCase() ?? "")
    .join("");

  return (
    <span
      aria-label={alt}
      style={{ width: size, height: size }}
      className={`inline-flex items-center justify-center rounded-full bg-muted text-muted-foreground text-xs font-semibold select-none ${className}`}
    >
      {initials || "?"}
    </span>
  );
}
