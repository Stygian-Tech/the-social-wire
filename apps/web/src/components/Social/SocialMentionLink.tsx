"use client";

import { useState, type ReactNode } from "react";
import Link from "next/link";
import { PreviewCard } from "@base-ui/react/preview-card";
import { socialProfilePageHref } from "@/lib/socialProfileNavigation";
import { SocialMentionProfileCard } from "./SocialMentionProfileCard";

export function SocialMentionLink({ actor, children, className }: { actor: string; children: ReactNode; className?: string }) {
  const [open, setOpen] = useState(false);
  return <PreviewCard.Root open={open} onOpenChange={setOpen}>
    <PreviewCard.Trigger delay={300} closeDelay={300} render={<Link href={socialProfilePageHref(actor)} prefetch={false} />} className={className}>{children}</PreviewCard.Trigger>
    <PreviewCard.Portal>
      <PreviewCard.Positioner side="bottom" align="start" sideOffset={8} className="isolate z-50">
        <PreviewCard.Popup className="w-100 max-w-[calc(100vw-2rem)] rounded-2xl bg-card text-card-foreground shadow-lg" onClick={event => event.stopPropagation()}>
          {open ? <SocialMentionProfileCard actor={actor} /> : null}
        </PreviewCard.Popup>
      </PreviewCard.Positioner>
    </PreviewCard.Portal>
  </PreviewCard.Root>;
}
