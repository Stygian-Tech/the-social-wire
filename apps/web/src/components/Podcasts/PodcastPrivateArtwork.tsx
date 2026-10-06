"use client";

import { useEffect, useState, type ReactNode } from "react";
import Image from "next/image";
import { useAuth } from "@/hooks/useAuth";
import { usePodcastViewer } from "@/hooks/usePodcastViewer";
import { gatewayFetch } from "@/lib/socialWireGatewayClient";
import { cn } from "@/lib/utils";

export function PodcastPrivateArtwork({ src, alt, size, className, onError, placeholder }: {
  src: string; alt: string; size: number; className?: string; onError: () => void; placeholder: ReactNode;
}) {
  const { getOAuthSession } = useAuth();
  const viewer = usePodcastViewer();
  const key = `${viewer ?? "signed-out"}:${src}`;
  const [image, setImage] = useState<{ key: string; url: string } | null>(null);
  useEffect(() => {
    const oauth = getOAuthSession();
    if (!oauth || !viewer) return;
    const controller = new AbortController();
    let objectUrl: string | undefined;
    void gatewayFetch(oauth, src, { signal: controller.signal }).then(async (response) => {
      if (!response.ok) throw new Error("Artwork unavailable");
      const blob = await response.blob();
      if (!blob.type.startsWith("image/") || blob.size > 5 * 1024 * 1024) throw new Error("Artwork unavailable");
      if (controller.signal.aborted) return;
      objectUrl = URL.createObjectURL(blob);
      setImage({ key, url: objectUrl });
    }).catch(() => { if (!controller.signal.aborted) onError(); });
    return () => { controller.abort(); if (objectUrl) URL.revokeObjectURL(objectUrl); };
  }, [src, viewer, key, getOAuthSession, onError]);
  return image?.key === key ? <Image unoptimized src={image.url} alt={alt} width={size} height={size}
    style={{ width: size, height: size }}
    onError={onError} className={cn("shrink-0 rounded-lg object-cover", className)} /> : placeholder;
}
