"use client";

import { useEffect, useState } from "react";

import { fetchCachedImageObjectUrl } from "@/lib/imageBlobCache";

/**
 * Resolves a remote image URL to a blob object URL backed by IndexedDB cache.
 */
export function useCachedImageUrl(src: string | null | undefined): {
  objectUrl: string | undefined;
  failed: boolean;
} {
  const [objectUrl, setObjectUrl] = useState<string | undefined>();
  const [failed, setFailed] = useState(false);

  useEffect(() => {
    if (!src?.trim()) {
      setObjectUrl(undefined);
      setFailed(false);
      return;
    }

    let cancelled = false;
    let activeObjectUrl: string | undefined;
    setFailed(false);
    setObjectUrl(undefined);

    void fetchCachedImageObjectUrl(src)
      .then((url) => {
        if (cancelled) {
          if (url) URL.revokeObjectURL(url);
          return;
        }
        activeObjectUrl = url;
        setObjectUrl(url);
        if (!url) setFailed(true);
      })
      .catch(() => {
        if (!cancelled) setFailed(true);
      });

    return () => {
      cancelled = true;
      if (activeObjectUrl) URL.revokeObjectURL(activeObjectUrl);
    };
  }, [src]);

  return { objectUrl, failed };
}
