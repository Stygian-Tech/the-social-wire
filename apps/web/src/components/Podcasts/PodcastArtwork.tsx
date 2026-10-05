"use client";

import { useCallback, useState } from "react";
import Image from "next/image";
import { Headphones } from "lucide-react";
import { cn } from "@/lib/utils";
import { PodcastPrivateArtwork } from "./PodcastPrivateArtwork";

export function PodcastArtwork({ src, fallbackSources = [], alt, size = 64, className }: {
  src?: string; fallbackSources?: (string | undefined)[]; alt: string; size?: number; className?: string;
}) {
  const [failed, setFailed] = useState({ source: src, index: 0 });
  const index = failed.source === src ? failed.index : 0;
  const source = [src, ...fallbackSources].filter((value): value is string => !!value)[index];
  const advance = useCallback(() => setFailed({ source: src, index: index + 1 }), [src, index]);
  const placeholder = <span role={alt ? "img" : undefined} aria-label={alt || undefined}
    style={{ width: size, height: size }} className={cn("flex shrink-0 items-center justify-center rounded-lg bg-muted", className)}>
    <Headphones aria-hidden="true" className="size-6" />
  </span>;
  if (source?.startsWith("/v1/podcasts/image?")) return <PodcastPrivateArtwork src={source} alt={alt} size={size} className={className} onError={advance} placeholder={placeholder} />;
  return source ? <Image unoptimized src={source} alt={alt} width={size} height={size}
    onError={advance} className={cn("shrink-0 rounded-lg object-cover", className)} /> : placeholder;
}
