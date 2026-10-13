import type { AppBskyEmbedExternal } from "@atproto/api";

export function SocialYouTubeEmbed({ external, href, src }: { external: AppBskyEmbedExternal.ViewExternal; href: string; src: string }) {
  return <div className="overflow-hidden rounded-xl border bg-muted/30">
    <iframe
      src={src}
      title={external.title || "YouTube Video"}
      loading="lazy"
      referrerPolicy="strict-origin-when-cross-origin"
      allow="accelerometer; autoplay; clipboard-write; encrypted-media; gyroscope; picture-in-picture; web-share"
      allowFullScreen
      className="aspect-video w-full border-0"
    />
    <a href={href} target="_blank" rel="noopener noreferrer" className="flex flex-col gap-1 p-3 hover:bg-muted/60">
      {external.title ? <p className="text-sm font-medium">{external.title}</p> : null}
      <p className="text-xs text-muted-foreground">Open On YouTube</p>
    </a>
  </div>;
}
