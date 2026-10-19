"use client";

/* eslint-disable @next/next/no-img-element -- Cached PDS avatars preserve publisher formats. */

import { useState } from "react";
import { List, Rss, Users } from "lucide-react";
import { useCachedImageUrl } from "@/hooks/useCachedImageUrl";
import { safeSocialFeedAvatarUrl, type SocialFeed } from "@/lib/blueskySocialClient";

export function SocialFeedAvatar({ feed }: { feed: SocialFeed }) {
  const source = feed.kind === "following" ? undefined : safeSocialFeedAvatarUrl(feed.avatar);
  const { objectUrl, failed } = useCachedImageUrl(source);
  const [failedObjectUrl, setFailedObjectUrl] = useState<string>();
  const Icon = feed.kind === "following" ? Users : feed.kind === "list" ? List : Rss;
  return <span aria-hidden="true" className="flex size-7 shrink-0 items-center justify-center overflow-hidden rounded-md">
    {objectUrl && !failed && failedObjectUrl !== objectUrl ? <img
      src={objectUrl}
      alt=""
      className="size-full object-cover"
      loading="lazy"
      referrerPolicy="no-referrer"
      onError={() => setFailedObjectUrl(objectUrl)}
    /> : <Icon className="size-4" />}
  </span>;
}
