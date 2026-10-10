"use client";

/* eslint-disable @next/next/no-img-element -- Publisher images retain their original formats. */
import { useState } from "react";
import type { AppBskyEmbedImages } from "@atproto/api";
import { socialHttpsUrl } from "./socialUrls";
import { SocialImageDialog } from "./SocialImageDialog";

export function SocialImageGallery({
  images,
}: {
  images: readonly AppBskyEmbedImages.ViewImage[];
}) {
  const [selected, setSelected] = useState<number | null>(null);
  const safeImages = images.filter((image) => socialHttpsUrl(image.thumb));
  if (!safeImages.length) return null;
  return (
    <>
      <div
        className={
          safeImages.length === 1
            ? "grid grid-cols-1 items-start gap-2"
            : "grid grid-cols-2 items-start gap-2"
        }
      >
        {safeImages.map((image, index) => (
          <button
            key={`${image.thumb}:${index}`}
            type="button"
            aria-label={`Open Image ${index + 1}${image.alt ? `: ${image.alt}` : ""}`}
            className="block min-w-0 self-start overflow-hidden rounded-xl outline-offset-4 focus-visible:outline-2 focus-visible:outline-ring"
            onClick={(event) => {
              event.stopPropagation();
              setSelected(index);
            }}
          >
            <img
              src={socialHttpsUrl(image.thumb)}
              alt={image.alt}
              width={image.aspectRatio?.width}
              height={image.aspectRatio?.height}
              loading="lazy"
              referrerPolicy="no-referrer"
              className="block h-auto w-full"
            />
          </button>
        ))}
      </div>
      {selected !== null ? (
        <SocialImageDialog
          key={`${safeImages[selected].fullsize}:${selected}`}
          image={safeImages[selected]}
          index={selected}
          total={safeImages.length}
          onClose={() => setSelected(null)}
          onPrevious={
            selected > 0 ? () => setSelected(selected - 1) : undefined
          }
          onNext={
            selected < safeImages.length - 1
              ? () => setSelected(selected + 1)
              : undefined
          }
        />
      ) : null}
    </>
  );
}
