"use client";

import { forwardRef, useState, type AnchorHTMLAttributes } from "react";
import Link from "next/link";
import { PreviewCard } from "@base-ui/react/preview-card";
import { socialProfilePageHref } from "@/lib/socialProfileNavigation";
import { SocialProfilePreviewCard } from "./SocialProfilePreviewCard";

type ProfileLinkProps = AnchorHTMLAttributes<HTMLAnchorElement> & { actor: string; returnTo?: string };

export const SocialProfileLink = forwardRef<HTMLAnchorElement, ProfileLinkProps>(function SocialProfileLink({ actor, returnTo, href, children, ...props }, ref) {
  const [open, setOpen] = useState(false);
  return <PreviewCard.Root open={open} onOpenChange={setOpen}>
    <PreviewCard.Trigger {...props} ref={ref} delay={300} closeDelay={300} render={<Link href={href ?? socialProfilePageHref(actor, returnTo)} prefetch={false} />}>{children}</PreviewCard.Trigger>
    <PreviewCard.Portal>
      <PreviewCard.Positioner side="bottom" align="start" sideOffset={8} className="isolate z-50">
        <PreviewCard.Popup className="w-100 max-w-[calc(100vw-2rem)] rounded-2xl bg-card text-card-foreground shadow-lg" onClick={event => event.stopPropagation()}>
          {open ? <SocialProfilePreviewCard actor={actor} returnTo={returnTo} /> : null}
        </PreviewCard.Popup>
      </PreviewCard.Positioner>
    </PreviewCard.Portal>
  </PreviewCard.Root>;
});
