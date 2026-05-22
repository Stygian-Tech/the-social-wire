"use client";

import { useEffect, useState } from "react";

import { fetchCachedImageObjectUrl } from "@/lib/imageBlobCache";

type CachedImageState = {
  key: string | null;
  objectUrl: string | undefined;
  failed: boolean;
};

/**
 * Resolves a remote image URL to a blob object URL backed by IndexedDB cache.
 */
export function useCachedImageUrl(src: string | null | undefined): {
  objectUrl: string | undefined;
  failed: boolean;
} {
  const cacheKey = src?.trim() || null;
  const [state, setState] = useState<CachedImageState>({
    key: null,
    objectUrl: undefined,
    failed: false,
  });

  useEffect(() => {
    if (!cacheKey) return;

    let cancelled = false;
    let activeObjectUrl: string | undefined;

    void fetchCachedImageObjectUrl(cacheKey)
      .then((url) => {
        if (cancelled) {
          if (url) URL.revokeObjectURL(url);
          return;
        }
        activeObjectUrl = url;
        setState({
          key: cacheKey,
          objectUrl: url,
          failed: !url,
        });
      })
      .catch(() => {
        if (!cancelled) {
          setState({
            key: cacheKey,
            objectUrl: undefined,
            failed: true,
          });
        }
      });

    return () => {
      cancelled = true;
      if (activeObjectUrl) URL.revokeObjectURL(activeObjectUrl);
    };
  }, [cacheKey]);

  if (!cacheKey || state.key !== cacheKey) {
    return { objectUrl: undefined, failed: false };
  }

  return { objectUrl: state.objectUrl, failed: state.failed };
}
