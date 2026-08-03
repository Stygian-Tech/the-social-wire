"use client";

import { useEffect, useMemo, useState } from "react";

import {
  fetchCachedImageObjectUrl,
  resolveDirectImageUrl,
} from "@/lib/imageBlobCache";

type CachedImageState = {
  key: string | null;
  objectUrl: string | undefined;
  failed: boolean;
};

/**
 * Resolves a remote image URL for display.
 * Bluesky CDN URLs use the same-origin image proxy + IndexedDB cache. Other
 * cross-origin URLs use direct `<img src>` when browser CORS prevents caching.
 */
export function useCachedImageUrl(src: string | null | undefined): {
  objectUrl: string | undefined;
  failed: boolean;
} {
  const cacheKey = src?.trim() || null;
  const directUrl = useMemo(
    () => (cacheKey ? resolveDirectImageUrl(cacheKey) : undefined),
    [cacheKey]
  );
  const [state, setState] = useState<CachedImageState>({
    key: null,
    objectUrl: undefined,
    failed: false,
  });

  useEffect(() => {
    if (!cacheKey || directUrl) return;

    let cancelled = false;
    let activeObjectUrl: string | undefined;

    void fetchCachedImageObjectUrl(cacheKey)
      .then((url) => {
        if (cancelled) {
          if (url?.startsWith("blob:")) URL.revokeObjectURL(url);
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
      if (activeObjectUrl?.startsWith("blob:")) URL.revokeObjectURL(activeObjectUrl);
    };
  }, [cacheKey, directUrl]);

  if (directUrl) {
    return { objectUrl: directUrl, failed: false };
  }

  if (!cacheKey || state.key !== cacheKey) {
    return { objectUrl: undefined, failed: false };
  }

  return { objectUrl: state.objectUrl, failed: state.failed };
}
