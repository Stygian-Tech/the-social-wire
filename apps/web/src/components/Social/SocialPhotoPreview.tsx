"use client";

/* eslint-disable @next/next/no-img-element -- Local attachment preview. */
import { useEffect, useRef } from "react";
import type { ComposerPhoto } from "@/lib/composerMedia";

export function SocialPhotoPreview({ photo }: { photo: ComposerPhoto }) {
  const image = useRef<HTMLImageElement>(null);
  const link = useRef<HTMLAnchorElement>(null);
  useEffect(() => { if (!photo.blob) return; const url = URL.createObjectURL(photo.blob); if (image.current) image.current.src = url; if (link.current) link.current.href = url; return () => URL.revokeObjectURL(url); }, [photo.blob]);
  if (!photo.blob) return <div className="flex h-32 items-center justify-center rounded-lg bg-muted text-xs">{photo.status === "failed" ? "Photo Unavailable" : "Preparing Preview…"}</div>;
  return <a ref={link} target="_blank" rel="noopener noreferrer" aria-label={`Preview ${photo.name}`}><img ref={image} alt={photo.alt} width={photo.width} height={photo.height} className="h-32 w-full rounded-lg object-contain" /></a>;
}
