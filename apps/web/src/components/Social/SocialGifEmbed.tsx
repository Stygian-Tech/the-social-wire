"use client";

import { useState } from "react";
import type { AppBskyEmbedExternal, AppBskyEmbedImages } from "@atproto/api";
import { Button } from "@/components/ui/button";
import { Dialog, DialogContent, DialogDescription, DialogTitle } from "@/components/ui/dialog";
import { socialHttpsUrl } from "./socialUrls";
import { socialGifVideoSources } from "./socialGifVideoSources";
import { SocialGifPlayer } from "./SocialGifPlayer";

export function SocialGifEmbed({ external, image }: { external: AppBskyEmbedExternal.ViewExternal; image: AppBskyEmbedImages.ViewImage }) {
  const [open, setOpen] = useState(false);
  const thumb = socialHttpsUrl(external.thumb);
  const poster = thumb && !/\.gif$/i.test(new URL(thumb).pathname) ? thumb : undefined;
  const props = { source: image.fullsize, poster, ...socialGifVideoSources(image.fullsize), alt: image.alt, width: image.aspectRatio?.width, height: image.aspectRatio?.height };
  return <div className="flex min-w-0 flex-col gap-2">
    <SocialGifPlayer {...props} />
    {image.alt ? <p className="text-sm text-muted-foreground">{image.alt}</p> : null}
    <Button type="button" variant="ghost" size="sm" onClick={event => { event.stopPropagation(); setOpen(true); }}>Open GIF Viewer</Button>
    {open ? <Dialog open onOpenChange={setOpen}><DialogContent className="max-h-[90dvh] overflow-y-auto sm:max-w-4xl" onClick={event => event.stopPropagation()}><DialogTitle>GIF Viewer</DialogTitle><DialogDescription>{image.alt || external.title}</DialogDescription><SocialGifPlayer {...props} /></DialogContent></Dialog> : null}
  </div>;
}
