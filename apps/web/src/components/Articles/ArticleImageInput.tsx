"use client";

import { useRef } from "react";
import { Button } from "@/components/ui/button";

export function ArticleImageInput({ label, multiple, disabled, onFiles }: { label: string; multiple?: boolean; disabled?: boolean; onFiles: (files: File[]) => Promise<void> }) {
  const input = useRef<HTMLInputElement>(null);
  return <><Button type="button" variant="outline" size="sm" disabled={disabled} onClick={() => input.current?.click()}>{label}</Button><input ref={input} type="file" aria-label={label} className="sr-only" accept="image/png,image/jpeg,image/gif,image/webp" multiple={multiple} disabled={disabled} onChange={event => { const files = [...event.target.files ?? []]; event.target.value = ""; void onFiles(files); }} /></>;
}

export async function articleImageDimensions(file: File) {
  if (!["image/png", "image/jpeg", "image/gif", "image/webp"].includes(file.type) || file.size > 1_000_000 || !file.size) throw new Error("Choose a PNG, JPEG, GIF, or WebP image up to 1 MB.");
  const image = await createImageBitmap(file);
  try {
    if (!image.width || !image.height) throw new Error("This image has no usable dimensions.");
    return { width: image.width, height: image.height };
  } finally { image.close(); }
}
