"use client";

/* eslint-disable @next/next/no-img-element -- Cached labeler avatars preserve publisher formats. */

import { useState } from "react";
import { Tag } from "lucide-react";
import { useCachedImageUrl } from "@/hooks/useCachedImageUrl";
import { cn } from "@/lib/utils";
import { socialHttpsUrl } from "./socialUrls";

export function SocialLabelerAvatar({ avatar, className }: { avatar?: string; className?: string }) {
  const source = socialHttpsUrl(avatar);
  const { objectUrl, failed } = useCachedImageUrl(source);
  const [failedSource, setFailedSource] = useState<string>();
  return <span aria-hidden="true" className={cn("flex size-3 shrink-0 items-center justify-center overflow-hidden rounded-full", className)}>
    {objectUrl && !failed && failedSource !== source ? <img src={objectUrl} alt="" loading="lazy" referrerPolicy="no-referrer" className="size-full object-cover" onError={() => setFailedSource(source)} /> : <Tag className="size-3" />}
  </span>;
}
